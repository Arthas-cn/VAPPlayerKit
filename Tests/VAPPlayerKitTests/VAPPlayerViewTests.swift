import Foundation
import Observation
import SwiftUI
import Testing
import UIKit
@testable import VAPPlayerKit

/// SwiftUI 入口的身份、展示门、暂停与排空回归；包含真实 UIHostingController 挂载及可控状态机测试。
@Suite(.timeLimit(.minutes(1)))
@MainActor
struct VAPPlayerViewTests {
    /// UIKit 导航承载默认 SwiftUI 环境时，真实窗口仍应启动本地透明素材，系统恢复须新控制版本。
    @Test
    func hostingControllerUsesItsRealWindowSceneAndPreservesExplicitResume() async throws {
        let scene = try #require(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                .first { $0.activationState == .foregroundActive }
        )
        let previousKeyWindow = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        let navigation = UINavigationController(rootViewController: UIViewController())
        let inputs = VAPHostedPlaybackInputs()
        let probe = VAPHostedEventProbe()
        let options = PlaybackOptions(
            assetMode: .packedAlpha(PackedAlphaLayout(
                arrangement: .sideBySide,
                colorRect: VideoPixelRect(x: 752, y: 0, width: 752, height: 448),
                alphaRect: VideoPixelRect(x: 0, y: 0, width: 752, height: 448)
            )),
            loopCount: 0,
            audioMode: .disabled
        )
        let request = VAPPlaybackRequest(id: UUID(), url: VAPFixture.url("alpha_left_moive.mp4"), options: options)
        let hosting = UIHostingController(rootView: VAPHostedRegressionView(request: request, inputs: inputs, probe: probe))
        window.frame = scene.effectiveGeometry.coordinateSpace.bounds
        window.rootViewController = navigation
        window.makeKeyAndVisible()
        navigation.pushViewController(hosting, animated: false)
        navigation.view.layoutIfNeeded()
        hosting.view.layoutIfNeeded()
        var attachedController: VAPPlayerController?
        defer {
            // 播放控制器已在成功和失败路径排空，再拆窗口并还原宿主键窗口。
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKey()
        }
        do {
            let host = try #require(findSwiftUIHost(in: hosting.view))
            let controller = try #require(host.controller)
            attachedController = controller
            try #require(host.window === window && host.observedScene === scene)
            try #require(host.bounds.width > 0 && host.bounds.height > 0)
            try await probe.wait(for: .started)
            #expect(host.isSceneActive)
            #expect(probe.events.contains(.ready))
            // 同时记录默认环境值与实际窗口证据，帮助区分环境缺失和零尺寸回归。
            print("VAP_HOSTING_BRIDGE phase=\(String(describing: probe.environmentPhase)) scene=\(scene.activationState.rawValue) bounds=\(host.bounds)")

            NotificationCenter.default.post(name: UIScene.willDeactivateNotification, object: scene)
            try await probe.wait(for: .paused(.system))
            NotificationCenter.default.post(name: UIScene.didActivateNotification, object: scene)
            await controller.waitForPendingWork()
            #expect(!probe.events.contains(.resumed))

            // 仅显式的新控制版本解锁系统暂停；真实 SwiftUI 更新会传递到同一个 Coordinator。
            inputs.controlRevision += 1
            try await probe.wait(for: .resumed)
            #expect(probe.events.filter { $0 == .started }.count == 1)
            inputs.intent = .paused
            inputs.controlRevision += 1
            try await probe.wait(for: .paused(.user))
            NotificationCenter.default.post(name: UIScene.willDeactivateNotification, object: scene)
            NotificationCenter.default.post(name: UIScene.didActivateNotification, object: scene)
            await controller.waitForPendingWork()
            #expect(probe.events.filter { $0 == .resumed }.count == 1)
        } catch {
            // 即使真实播放失败，也必须排空内核后才移除 HostingController 与窗口。
            attachedController?.dismantle()
            await attachedController?.waitForPendingWork()
            throw error
        }
        attachedController?.dismantle()
        await attachedController?.waitForPendingWork()
    }

    /// 从真实 HostingController 的视图树寻找桥接宿主，不替换 transport 或手动制造入窗状态。
    private func findSwiftUIHost(in view: UIView) -> VAPSwiftUIHost? {
        // 找到真实类型后停止递归，避免对子视图做无关查询。
        if let host = view as? VAPSwiftUIHost { return host }
        for child in view.subviews {
            // 桥接容器可能位于 SwiftUI 的中间 UIKit 包装层之下。
            if let host = findSwiftUIHost(in: child) { return host }
        }
        return nil
    }

    /// 无尺寸不开始准备；有尺寸后首次 prepare/play 各一次，同 ID 重绘保持稳定。
    @Test
    func waitsForPresentationAndDoesNotRestartOnRedraw() async throws {
        let harness = VAPSwiftUITestHarness(presentationAvailable: false)
        let request = harness.request()
        harness.submit(request)
        await harness.controller.waitForPendingWork()
        #expect(harness.factory.transports.isEmpty)
        #expect(harness.events(for: request) == [.waitingForPresentation])

        harness.controller.setPresentationAvailable(true)
        await harness.controller.waitForPendingWork()
        let transport = try #require(harness.factory.transports.first)
        for _ in 0..<10 { harness.submit(request) }
        await harness.controller.waitForPendingWork()
        #expect(harness.factory.transports.count == 1)
        #expect(transport.preparedRequests.count == 1)
        #expect(transport.playCount == 1)
        #expect(transport.resumeCount == 0)
        #expect(harness.events(for: request) == [.waitingForPresentation, .preparing, .ready, .started])
        await harness.close()
    }

    /// 初始暂停允许准备但不播放；首次播放走 play，之后恢复只调用 resume。
    @Test
    func initialPauseUsesPlayOnlyAfterExplicitStart() async throws {
        let harness = VAPSwiftUITestHarness()
        let request = harness.request()
        harness.submit(request, intent: .paused, muted: true)
        await harness.controller.waitForPendingWork()
        let transport = try #require(harness.factory.transports.first)
        #expect(transport.isMuted)
        #expect(transport.playCount == 0)

        harness.submit(request, revision: 1)
        harness.submit(request, intent: .paused, revision: 2)
        harness.submit(request, revision: 3)
        await harness.controller.waitForPendingWork()
        #expect(transport.playCount == 1)
        #expect(transport.resumeCount == 1)
        #expect(!transport.isMuted)
        #expect(harness.events(for: request).filter { $0 == .started }.count == 1)
        #expect(harness.events(for: request).contains(.resumed))
        await harness.close()
    }

    /// 首次 play 已发出但 started 延后时暂停并恢复，只恢复原会话且首次事件顺序正确。
    @Test
    func resumesPendingFirstStartWithoutIssuingAnotherPlay() async throws {
        let harness = VAPSwiftUITestHarness()
        harness.factory.configureNext = { $0.startsImmediately = false }
        let request = harness.request()
        harness.submit(request)
        await harness.controller.waitForPendingWork()
        let transport = try #require(harness.factory.transports.first)
        harness.submit(request, intent: .paused, revision: 1)
        harness.submit(request, revision: 2)
        await harness.controller.waitForPendingWork()
        #expect(transport.playCount == 1)
        #expect(transport.resumeCount == 1)
        #expect(!harness.events(for: request).contains(.resumed))
        #expect(!harness.events(for: request).contains(.started))

        transport.send(.started)
        await harness.controller.waitForPendingWork()
        #expect(harness.events(for: request).filter { $0 == .started }.count == 1)
        await harness.close()
    }

    /// 宿主有尺寸但未入窗仍不得准备，真实入窗之后才创建请求独占内核。
    @Test
    func hostRequiresBothAWindowAndPositiveBounds() async throws {
        let harness = VAPSwiftUITestHarness(presentationAvailable: false)
        let host = VAPSwiftUIHost()
        harness.controller.attach(to: host)
        host.frame = CGRect(x: 0, y: 0, width: 100, height: 100)
        host.refreshAvailability()
        harness.submit(harness.request())
        await harness.controller.waitForPendingWork()
        #expect(harness.factory.transports.isEmpty)

        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 200, height: 200)
        window.addSubview(host)
        host.refreshAvailability()
        await harness.controller.waitForPendingWork()
        #expect(harness.factory.transports.count == 1)
        await harness.close()
        host.removeFromSuperview()
    }

    /// 场景与音频中断恢复不能自动续播；新的控制版本才能解除系统暂停。
    @Test
    func systemPauseRequiresAnExplicitResumeCommand() async throws {
        let harness = VAPSwiftUITestHarness()
        let request = harness.request()
        harness.submit(request)
        await harness.controller.waitForPendingWork()
        let transport = try #require(harness.factory.transports.first)

        harness.submit(request, active: false)
        harness.submit(request, active: true)
        #expect(transport.resumeCount == 0)
        harness.submit(request, revision: 1)
        #expect(transport.resumeCount == 1)

        harness.controller.setAudioInterrupted(true)
        harness.submit(request, revision: 2)
        harness.controller.setAudioInterrupted(false)
        harness.submit(request, revision: 2)
        #expect(transport.resumeCount == 1)
        harness.submit(request, revision: 3)
        #expect(transport.resumeCount == 2)
        await harness.close()
    }

    /// 零尺寸恢复仅解除展示门，不能取消已经记录的用户暂停。
    @Test
    func restoringPresentationPreservesUserPause() async throws {
        let harness = VAPSwiftUITestHarness()
        let request = harness.request()
        harness.submit(request)
        await harness.controller.waitForPendingWork()
        let transport = try #require(harness.factory.transports.first)

        harness.controller.setPresentationAvailable(false)
        harness.controller.setPresentationAvailable(true)
        #expect(transport.resumeCount == 1)
        harness.submit(request, intent: .paused, revision: 1)
        harness.controller.setPresentationAvailable(false)
        harness.controller.setPresentationAvailable(true)
        #expect(transport.resumeCount == 1)
        #expect(transport.playCount == 1)
        await harness.close()
    }

    /// 同 ID 修改不可变配置只发一次 failed；旧 ID 之后恢复或再次修改都不复活。
    @Test
    func changingOptionsWithTheSameIDFailsOnlyOnce() async throws {
        let harness = VAPSwiftUITestHarness()
        let request = harness.request()
        harness.submit(request)
        await harness.controller.waitForPendingWork()
        let transport = try #require(harness.factory.transports.first)
        var options = request.options
        options.loopCount = 2
        let changed = harness.request(id: request.id, options: options)

        harness.submit(changed)
        harness.submit(request, revision: 1)
        harness.submit(changed, revision: 2)
        await harness.controller.waitForPendingWork()
        #expect(harness.events(for: request).filter { $0 == .failed(.requestChanged) }.count == 1)
        #expect(transport.cleanupCount == 1)
        #expect(transport.playCount == 1)
        #expect(harness.factory.transports.count == 1)
        await harness.close()
    }

    /// A 准备时切换 B：即使 A 忽略取消，也须等 A 清理结束后才创建 B，迟到事件无效。
    @Test
    func replacementWaitsForPhysicalCleanupAndDropsOldResults() async throws {
        let harness = VAPSwiftUITestHarness()
        let preparationGate = VAPTestGate()
        let cleanupGate = VAPTestGate()
        harness.factory.configureNext = {
            $0.preparationGate = preparationGate
            $0.cleanupGate = cleanupGate
        }
        let first = harness.request()
        let second = harness.request()
        harness.submit(first)
        let oldTransport = try #require(harness.factory.transports.first)
        await oldTransport.preparationEntered.wait()

        harness.submit(second)
        await oldTransport.cleanupEntered.wait()
        oldTransport.send(.started)
        oldTransport.send(.finished(.completed))
        #expect(harness.factory.transports.count == 1)
        preparationGate.open()
        cleanupGate.open()
        await harness.controller.waitForPendingWork()

        let newTransport = try #require(harness.factory.transports.last)
        #expect(harness.factory.transports.count == 2)
        #expect(oldTransport.playCount == 0)
        #expect(newTransport.playCount == 1)
        #expect(!harness.events(for: first).contains(.ready))
        #expect(!harness.events(for: first).contains(.started))
        #expect(harness.events(for: first).filter { $0 == .finished(.cancelled) }.count == 1)
        await harness.close()
    }

    /// 真实 prepare 同时 delegate 报错并抛出时，错误事件和排空都只执行一次。
    @Test
    func delegateAndThrownFailureShareOneTerminalEvent() async throws {
        let harness = VAPSwiftUITestHarness()
        harness.factory.configureNext = {
            $0.preparationError = .invalidURL
            $0.emitsErrorBeforeThrow = true
        }
        let request = harness.request()
        harness.submit(request)
        await harness.controller.waitForPendingWork()
        let transport = try #require(harness.factory.transports.first)
        #expect(harness.events(for: request).filter { $0 == .failed(.playback(.invalidURL)) }.count == 1)
        #expect(transport.cleanupCount == 1)
        #expect(transport.playCount == 0)
        await harness.close()
    }

    /// 新请求固定 provider 与实际挂起配置，同 ID 重绘不替换 provider 或重做准备。
    @Test
    func snapshotsProviderAndDisablesSDKAutomaticResume() async throws {
        let harness = VAPSwiftUITestHarness()
        let firstProvider = VAPTestDynamicProvider()
        let laterProvider = VAPTestDynamicProvider()
        var options = PlaybackOptions()
        options.automaticallyResumesAfterSuspension = true
        let request = harness.request(options: options)
        harness.submit(request, provider: firstProvider)
        await harness.controller.waitForPendingWork()
        harness.submit(request, provider: laterProvider)
        let transport = try #require(harness.factory.transports.first)
        let prepared = try #require(transport.preparedRequests.first)
        #expect(transport.receivedProvider === firstProvider)
        #expect(!prepared.options.automaticallyResumesAfterSuspension)
        #expect(prepared.options.backgroundPolicy == .suspend)
        #expect(request.options.automaticallyResumesAfterSuspension)
        #expect(transport.preparedRequests.count == 1)
        await harness.close()
    }

    /// 末帧保留只影响自然完成后的显示，不允许旧 ID 重播；显式停止随后释放末帧。
    @Test
    func retainedLastFrameStillHasATerminalIdentity() async throws {
        let harness = VAPSwiftUITestHarness()
        var options = PlaybackOptions()
        options.clearsAfterFinish = false
        let request = harness.request(options: options)
        harness.submit(request)
        await harness.controller.waitForPendingWork()
        let transport = try #require(harness.factory.transports.first)
        transport.send(.finished(.completed))
        harness.submit(request, revision: 1)
        await harness.controller.waitForPendingWork()
        #expect(transport.cleanupCount == 0)
        #expect(transport.playCount == 1)

        harness.submit(request, intent: .stopped, revision: 2)
        await harness.controller.waitForPendingWork()
        #expect(transport.cleanupCount == 1)
        #expect(harness.events(for: request).filter { $0 == .finished(.completed) }.count == 1)
        #expect(!harness.events(for: request).contains(.finished(.stopped)))
        await harness.close()
    }

    /// 初始隐藏请求不创建内核；恢复可见或先清空再重交旧 ID 也不会重播。
    @Test
    func hiddenRequestsDoNotStartOrReuseTheirIdentity() async {
        let harness = VAPSwiftUITestHarness()
        let request = harness.request()
        harness.submit(request, visible: false)
        harness.submit(nil)
        harness.submit(request, revision: 1)
        await harness.controller.waitForPendingWork()
        #expect(harness.factory.transports.isEmpty)
        #expect(harness.events(for: request) == [.finished(.stopped)])
        await harness.close()
    }

    /// dismantle 后即使准备和 delegate 迟到也不开播，清理屏障仍由明确所有者持有。
    @Test
    func dismantleWaitsForUncooperativePreparation() async throws {
        let harness = VAPSwiftUITestHarness()
        let preparationGate = VAPTestGate()
        let cleanupGate = VAPTestGate()
        harness.factory.configureNext = {
            $0.preparationGate = preparationGate
            $0.cleanupGate = cleanupGate
        }
        let request = harness.request()
        harness.submit(request)
        let transport = try #require(harness.factory.transports.first)
        await transport.preparationEntered.wait()
        harness.controller.dismantle()
        await transport.cleanupEntered.wait()
        harness.submit(harness.request())
        transport.send(.started)
        preparationGate.open()
        cleanupGate.open()
        await harness.controller.waitForPendingWork()
        #expect(transport.playCount == 0)
        #expect(transport.cleanupCount == 1)
        #expect(harness.factory.transports.count == 1)
        #expect(!harness.events(for: request).contains(.ready))
        #expect(!harness.events(for: request).contains(.started))
        #expect(harness.events(for: request).filter { $0 == .finished(.cancelled) }.count == 1)
    }

    /// Coordinator 真正释放后，registry 仍持有尚未完成的内核清理，直到屏障打开。
    @Test
    func retirementOutlivesTheSwiftUIController() async throws {
        let factory = VAPTestTransportFactory()
        let cleanupGate = VAPTestGate()
        let stoppedDelivered = VAPTestGate()
        factory.configureNext = { $0.cleanupGate = cleanupGate }
        var controller: VAPPlayerController? = VAPPlayerController { provider, onEvent in
            factory.make(provider: provider, onEvent: onEvent)
        }
        let request = VAPPlaybackRequest(id: UUID(), url: URL(fileURLWithPath: "/test/fixture.vap"))
        controller?.setPresentationAvailable(true)
        controller?.update(
            resource: request, intent: .playing, controlRevision: 0,
            isVisible: true, isMuted: false, isSceneActive: true,
            dynamicContentProvider: nil,
            onEvent: {
                // 以事件交付完成作为明确同步点，不靠 Task.yield 猜控制器何时释放。
                if $0.kind == .finished(.cancelled) { stoppedDelivered.open() }
            }
        )
        await controller?.waitForPendingWork()
        let transport = try #require(factory.transports.first)
        weak let weakController = controller
        controller?.dismantle()
        controller = nil
        await stoppedDelivered.wait()
        await transport.cleanupEntered.wait()
        #expect(weakController == nil)
        #expect(transport.cleanupCount == 1)

        cleanupGate.open()
        await transport.cleanupCompleted.wait()
        #expect(transport.cleanupCount == 1)
    }
}

/// 真实 SwiftUI 挂载测试的外部控制值，通过 Observation 触发正常 representable 更新。
@MainActor
@Observable
private final class VAPHostedPlaybackInputs {
    /// 当前业务意图，不随场景激活通知变化。
    var intent: VAPPlaybackIntent = .playing
    /// 用户显式命令序号，系统通知不能替调用方递增。
    var controlRevision: UInt64 = 0
}

/// 与 UIKit Demo 相同的 HostingController 内容，不人工注入 scenePhase 环境。
@MainActor
private struct VAPHostedRegressionView: View {
    /// 真实本地素材请求，整个测试使用同一个身份。
    let request: VAPPlaybackRequest
    /// 状态机通过正常 SwiftUI 观察机制收到的输入。
    let inputs: VAPHostedPlaybackInputs
    /// 接收真实控制事件与环境诊断的测试探针。
    let probe: VAPHostedEventProbe
    /// 仅记录 UIKit 承载下的默认环境，播放判定由实际窗口负责。
    @Environment(\.scenePhase) private var scenePhase

    /// 创建真实滚动容器与固定高度预览，复现 Demo 的桥接路径。
    var body: some View {
        ScrollView {
            // 宽度来自真实 HostingController 布局，测试不能手动给桥接 host 伪造 bounds。
            VAPPlayerView(
                resource: request,
                intent: inputs.intent,
                controlRevision: inputs.controlRevision,
                isMuted: true,
                onEvent: probe.receive
            )
            .frame(height: 260)
        }
        .onAppear { probe.environmentPhase = scenePhase }
    }
}

/// 用真实播放器事件唤醒挂载测试；失败或测试取消同样恢复等待，不靠固定延时。
@MainActor
private final class VAPHostedEventProbe {
    /// 顺序保留真实业务事件，断言恢复次数和首次启动唯一性。
    private(set) var events: [VAPPlaybackEvent.Kind] = []
    /// SwiftUI 首次出现时报告的默认环境值；nil 表示尚未出现。
    var environmentPhase: ScenePhase?
    /// 当前条件等待的目标事件，nil 表示没有正在等待。
    private var expected: VAPPlaybackEvent.Kind?
    /// 单个串行等待者；事件或取消后必须取出并清空。
    private var continuation: CheckedContinuation<Void, any Error>?
    /// 真实失败的值错误，后续等待也必须立即失败。
    private var failure: VAPPlaybackFailure?

    /// 保存事件并恢复匹配等待；真实失败直接抛给测试，不伪装成窗口等待超时。
    func receive(_ event: VAPPlaybackEvent) {
        events.append(event.kind)
        // 任何阶段的真实失败都保留，并唤醒尚在等其他事件的调用方。
        if case let .failed(error) = event.kind {
            failure = error
            finish(.failure(error))
        } else if expected == event.kind {
            // 只匹配当前等待条件；其他低频事件仍保留用于最终断言。
            finish(.success(()))
        }
    }

    /// 等待指定事件；已经发生则立即返回，SDK 失败或任务取消原样抛出。
    func wait(for kind: VAPPlaybackEvent.Kind) async throws {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            // 较早失败不能被后来查询已发生事件掩盖。
            if let failure { throw failure }
            // 真实回调可能先于测试进入等待，不能丢掉此前的结果。
            if events.contains(kind) { return }
            try await withCheckedThrowingContinuation { waiting in
                expected = kind
                continuation = waiting
            }
        } onCancel: {
            // 超时取消可能来自任意执行器，回主线程结束等待以便执行窗口清理。
            Task { @MainActor [weak self] in self?.finish(.failure(CancellationError())) }
        }
    }

    /// 原子清除当前等待再恢复 continuation，防止回调重入重复完成。
    private func finish(_ result: Result<Void, any Error>) {
        let waiting = continuation
        continuation = nil
        expected = nil
        waiting?.resume(with: result)
    }
}
