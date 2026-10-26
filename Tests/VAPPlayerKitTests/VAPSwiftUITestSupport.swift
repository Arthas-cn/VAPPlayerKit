import Foundation
import UIKit
@testable import VAPPlayerKit

/// 测试专用的显式屏障；由用例主动打开，不用时间延迟控制并发顺序。
@MainActor
final class VAPTestGate {
    /// 一旦打开便保持打开，后来的等待者立即通过。
    private var isOpen = false
    /// 尚未通过的等待者，open 后各自恢复一次。
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// 等待屏障打开，故意不自动响应取消以覆盖不合作底层任务。
    func wait() async {
        // 已打开的屏障不能再登记永远无人恢复的 continuation。
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    /// 幂等打开屏障，先清空保存集合再恢复 continuation。
    func open() {
        // 重复打开不能二次恢复已使用的 continuation。
        guard !isOpen else { return }
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

/// 不创建 Metal 或读取文件的可控内核，记录真实调用及迟到 delegate。
@MainActor
final class VAPTestTransport: VAPPlayerTransport {
    /// 普通 UIView 仅满足桥接接口，不包含渲染资源。
    let view = UIView()
    /// 当前静音值，用于验证准备前已经传入。
    var isMuted = false
    /// prepare 已经进入，供切换/销毁用例确定竞态位置。
    let preparationEntered = VAPTestGate()
    /// clear 已经进入，供验证旧资源仍占用清理所有权。
    let cleanupEntered = VAPTestGate()
    /// clear 已实际返回所需工作完成，供等待失去控制器后的清理。
    let cleanupCompleted = VAPTestGate()
    /// 可选准备屏障；nil 表示准备立即成功。
    var preparationGate: VAPTestGate?
    /// 可选清理屏障；nil 表示清理立即完成。
    var cleanupGate: VAPTestGate?
    /// prepare 应抛出的错误；nil 表示成功。
    var preparationError: PlaybackError?
    /// 同一个错误先走 delegate 再抛出，以验证终态合并。
    var emitsErrorBeforeThrow = false
    /// 是否在 play 时同步确认 started。
    var startsImmediately = true
    /// 按调用顺序保存准备的完整配置。
    private(set) var preparedRequests: [VAPPlaybackRequest] = []
    /// 首次 play 次数，不能被 resume 或普通重绘增加。
    private(set) var playCount = 0
    /// pause 次数，仅用于核实已经发生暂停而非精确布局回调次数。
    private(set) var pauseCount = 0
    /// resume 次数，用于验证显式恢复与尺寸恢复。
    private(set) var resumeCount = 0
    /// clearAndWait 实际调用次数，重复终态不应重复清理。
    private(set) var cleanupCount = 0
    /// 工厂接到的 provider 为弱引用，测试不会掩盖生产所有权。
    weak var receivedProvider: (any DynamicContentProvider)?
    /// 即使清理后也保留该测试回调，用于主动模拟不合作的迟到 delegate。
    private let onEvent: @MainActor (VAPTransportEvent) -> Void

    /// 创建记录型内核，所有工作由测试显式驱动。
    init(provider: (any DynamicContentProvider)?, onEvent: @escaping @MainActor (VAPTransportEvent) -> Void) {
        receivedProvider = provider
        self.onEvent = onEvent
    }

    /// 记录请求并等待可选屏障；不检测 Task 取消，以验证控制器自己过滤迟到结果。
    func prepare(_ request: VAPPlaybackRequest) async throws {
        preparedRequests.append(request)
        preparationEntered.open()
        await preparationGate?.wait()
        if let preparationError {
            // 与真实 PlayerView 一样，允许 delegate 和 throws 同时报错。
            if emitsErrorBeforeThrow { onEvent(.failed(preparationError)) }
            throw preparationError
        }
    }

    /// 记录首次启动，可同步模拟 SDK started 回调重入。
    func play(_ request: VAPPlaybackRequest) {
        playCount += 1
        if startsImmediately { onEvent(.started) }
    }

    /// 记录立即暂停，不自动发送终态。
    func pause() { pauseCount += 1 }

    /// 记录恢复，不伪造第二个首次播放事件。
    func resume() { resumeCount += 1 }

    /// 等待显式清理屏障，直到实际退出才标记完成。
    func clearAndWait() async {
        cleanupCount += 1
        cleanupEntered.open()
        await cleanupGate?.wait()
        cleanupCompleted.open()
    }

    /// 主动发送包括迟到事件在内的内核消息。
    func send(_ event: VAPTransportEvent) { onEvent(event) }
}

/// 每个测试独占的工厂，不使用全局可变 fake 或真实播放器。
@MainActor
final class VAPTestTransportFactory {
    /// 已创建内核，便于断言创建数量与各代次行为。
    private(set) var transports: [VAPTestTransport] = []
    /// 仅作用于下一次创建的定制，避免配置污染新请求。
    var configureNext: ((VAPTestTransport) -> Void)?

    /// 创建并记录一代内核，将配置消费一次。
    func make(
        provider: (any DynamicContentProvider)?,
        onEvent: @escaping @MainActor (VAPTransportEvent) -> Void
    ) -> any VAPPlayerTransport {
        let transport = VAPTestTransport(provider: provider, onEvent: onEvent)
        configureNext?(transport)
        configureNext = nil
        transports.append(transport)
        return transport
    }
}

/// 测试自身拥有的事件记录器，避免控制器回调强持有测试宿主。
@MainActor
final class VAPTestEventRecorder {
    /// 按实际交付顺序保存所有请求事件。
    var events: [VAPPlaybackEvent] = []
}

/// 封装重复输入的测试宿主；每例均创建自己的控制器和工厂。
@MainActor
final class VAPSwiftUITestHarness {
    /// 当前测试独占工厂。
    let factory: VAPTestTransportFactory
    /// 当前测试独占控制器。
    let controller: VAPPlayerController
    /// 当前测试独占事件记录。
    let recorder = VAPTestEventRecorder()

    /// 创建宿主，默认具备有效展示条件但尚未提交任何资源。
    init(presentationAvailable: Bool = true) {
        let factory = VAPTestTransportFactory()
        self.factory = factory
        controller = VAPPlayerController { provider, onEvent in
            factory.make(provider: provider, onEvent: onEvent)
        }
        controller.setPresentationAvailable(presentationAvailable)
    }

    /// 创建不需要实际存在的本地 fixture 描述，fake 不执行文件 I/O。
    func request(id: UUID = UUID(), options: PlaybackOptions = .init()) -> VAPPlaybackRequest {
        VAPPlaybackRequest(id: id, url: URL(fileURLWithPath: "/test/fixture.vap"), options: options)
    }

    /// 提交一次 SwiftUI 输入，所有默认值与正式公开入口一致。
    func submit(
        _ request: VAPPlaybackRequest?,
        intent: VAPPlaybackIntent = .playing,
        revision: UInt64 = 0,
        visible: Bool = true,
        muted: Bool = false,
        active: Bool = true,
        provider: (any DynamicContentProvider)? = nil
    ) {
        controller.update(
            resource: request, intent: intent, controlRevision: revision,
            isVisible: visible, isMuted: muted, isSceneActive: active,
            dynamicContentProvider: provider,
            onEvent: { [recorder] in recorder.events.append($0) }
        )
    }

    /// 读取指定请求的事件种类，不把不同代次合并统计。
    func events(for request: VAPPlaybackRequest) -> [VAPPlaybackEvent.Kind] {
        recorder.events.filter { $0.requestID == request.id }.map(\.kind)
    }

    /// 结束测试拥有的请求并明确等待全部清理，不把任务留到下一例。
    func close() async {
        controller.dismantle()
        await controller.waitForPendingWork()
    }
}

/// 用于验证请求固定 provider 身份的空实现，不加载动态内容。
@MainActor
final class VAPTestDynamicProvider: DynamicContentProvider {
    /// 返回 nil 保持素材默认内容，不执行任何异步工作。
    func resolve(tag: String, source: SourceMetadata) async throws -> DynamicContent? { nil }
}
