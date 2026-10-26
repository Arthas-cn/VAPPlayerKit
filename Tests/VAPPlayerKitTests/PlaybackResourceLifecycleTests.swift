import QuartzCore
import Testing
import UIKit
@testable import VAPPlayerKit

/// 验证显式排空后的资源释放，以及取消 provider 时逻辑取消与实际退出的区别。
@MainActor
@Suite(.timeLimit(.minutes(2)))
struct PlaybackResourceLifecycleTests {
    /// 全部 27 个合法 fixture 必须在真实窗口提交渲染并完成 GPU 首帧，然后逐项排空资源。
    @Test func everyPlayableFixturePresentsACompletedGPUFrameInHostedWindow() async throws {
        let urls = VAPFixture.playableURLs
        try #require(urls.count == 27, "宿主测试必须打包全部 27 个合法素材，不能以缩减样本通过。")
        let scene = try #require(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                .first { $0.activationState == .foregroundActive },
            "GPU 呈现回归需要已连接且前台活动的 UIWindowScene。"
        )
        try #require(UIApplication.shared.applicationState == .active)
        let previousKeyWindow = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        let root = UIViewController()
        window.frame = scene.effectiveGeometry.coordinateSpace.bounds
        window.rootViewController = root
        window.makeKeyAndVisible()
        root.view.layoutIfNeeded()
        defer {
            // 每项播放器已经 await 排空，这里仅解除测试窗口并归还原宿主的键盘焦点。
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKey()
        }

        var presentedNames = Set<String>()
        for url in urls {
            // 时间限制取消后不再分配下一个真实播放器。
            try Task.checkCancellation()
            try await verifyHostedPresentation(of: url, in: root.view)
            presentedNames.insert(url.lastPathComponent)
        }
        #expect(presentedNames == Set(urls.map(\.lastPathComponent)))
        #expect(presentedNames.count == 27)
    }

    /// 为一个真实素材创建独立宿主；成功或失败都等待 clearAndWait 后才拆除视图。
    private func verifyHostedPresentation(of url: URL, in container: UIView) async throws {
        let player = PlayerView(frame: CGRect(x: 24, y: 24, width: 240, height: 240))
        // clear 将公开 Metal 层置为隐藏，后续 false 只能来自 GPU 完成后的 onFirstFrame。
        await player.clearAndWait()
        let probe = HostedPresentationProbe(fileName: url.lastPathComponent)
        player.delegate = probe
        player.metricsSink = probe
        container.addSubview(player)
        container.layoutIfNeeded()
        player.layoutIfNeeded()
        let visibility = player.metalLayer.observe(\.isHidden, options: [.new]) { [weak probe] _, change in
            // renderedFrame 是提交边界；宿主只在 command buffer 完成后解除此层隐藏。
            guard change.newValue == false else { return }
            Task { @MainActor [weak probe] in probe?.recordCompletedPresentation() }
        }
        var options = PlaybackOptions()
        // 同一集合包含 VAP、无配置拼接素材与普通视频，必须保留明确的自动识别分支。
        options.assetMode = .automatic
        options.audioMode = .disabled
        options.loopCount = 0
        options.clearsAfterFinish = false

        do {
            try #require(player.window != nil && !player.bounds.isEmpty)
            try #require(player.metalLayer.drawableSize.width > 0 && player.metalLayer.drawableSize.height > 0)
            try #require(player.metalLayer.isHidden)
            _ = try await player.prepare(url: url, options: options)
            player.play(url: url, options: options)
            try await probe.waitForCompletedPresentation()
            #expect(probe.submittedFrameCount > 0, "\(url.lastPathComponent) 没有提交真实 drawable 渲染。")
            #expect(probe.completedPresentation, "\(url.lastPathComponent) 没有等到 GPU 完成后的首帧。")
            #expect(!player.metalLayer.isHidden)
        } catch {
            // 准备、GPU 或取消错误都保留原始 Error，清理不能提前归还正在使用的资源。
            await retireHostedPlayer(player, observation: visibility)
            throw error
        }
        await retireHostedPlayer(player, observation: visibility)
    }

    /// 先等待解码和 GPU 完全排空，再移除观察与视图，禁止下一素材与旧资源重叠。
    private func retireHostedPlayer(_ player: PlayerView, observation: NSKeyValueObservation) async {
        await player.clearAndWait()
        observation.invalidate()
        player.delegate = nil
        player.metricsSink = nil
        player.removeFromSuperview()
    }

    /// 真正开始解码的 session 排空后，session、解码来源与 Metal renderer 均应释放。
    @Test func drainedSessionReleasesOwnedResources() async throws {
        let url = VAPFixture.defaultPlayableURL
        let layer = CAMetalLayer()
        layer.frame = CGRect(x: 0, y: 0, width: 64, height: 64)
        layer.drawableSize = CGSize(width: 64, height: 64)
        var options = PlaybackOptions()
        // 此处只验证 decoder 和 GPU 资源所有权，音轨就绪另有专项测试。
        options.audioMode = .disabled
        var frameSource: AVAssetReaderFrameSource? = AVAssetReaderFrameSource(url: url)
        var renderer: MetalRenderer? = MetalRenderer()
        var session: PlaybackSession? = PlaybackSession(
            url: url,
            options: options,
            metalLayer: layer,
            dynamicProvider: nil,
            frameSource: frameSource,
            renderer: try #require(renderer)
        )
        weak let weakSession = session
        weak let weakFrameSource = frameSource
        weak let weakRenderer = renderer
        let started = LifecycleStartProbe()
        session?.onStart = { started.complete() }
        session?.onFailure = { error in started.complete(error: error) }

        do {
            _ = try await session?.prepare()
            session?.play()
            await started.signal.wait()
            // 解码失败也唤醒等待者，避免把实际失败变成无期限等待 didStart。
            if let error = started.error { throw error }
        } catch {
            // 即使准备或启动失败，也先排空资源再把原始错误交给测试框架。
            await session?.clearAndWait()
            throw error
        }

        await session?.clearAndWait()
        session = nil
        frameSource = nil
        renderer = nil
        #expect(weakSession == nil)
        #expect(weakFrameSource == nil)
        #expect(weakRenderer == nil)
    }

    /// 没有播放工作的宿主排空后，生命周期通知订阅不得继续强持有宿主。
    @Test func drainedPlayerIsNotRetainedByLifecycleObservers() async {
        var player: PlayerView? = PlayerView()
        weak let weakPlayer = player
        await player?.clearAndWait()
        player = nil
        #expect(weakPlayer == nil)
    }

    /// provider 收到取消但尚未返回时 clearAndWait 必须继续等待，返回后宿主应能释放。
    @Test func clearWaitsForProviderExitBeforeReleasingPlayer() async {
        let provider = ControlledLifecycleProvider()
        let clearFinished = LifecycleTestSignal()
        var player: PlayerView? = PlayerView(frame: CGRect(x: 0, y: 0, width: 64, height: 64))
        player?.dynamicContentProvider = provider
        player?.play(url: VAPFixture.url("8.mp4"))
        await provider.entered.wait()
        weak let weakPlayer = player

        // 故意让 provider 在取消后保持在途，验证排空不会只发送取消就提前返回。
        let clearing = Task { @MainActor [weak player] in
            await player?.clearAndWait()
            clearFinished.signal()
        }
        await provider.cancellationReceived.wait()
        #expect(!provider.exited.isSignalled)
        #expect(!clearFinished.isSignalled)

        provider.release.signal()
        await clearing.value
        #expect(provider.exited.isSignalled)
        #expect(clearFinished.isSignalled)
        player = nil
        #expect(weakPlayer == nil)
    }
}

/// 合并真实提交指标、GPU 完成后的层显示及失败回调；不把 prepare 或 started 当作呈现。
@MainActor
private final class HostedPresentationProbe: MetricsSink, PlayerDelegate {
    /// 当前素材名称，只用于在缺少首帧时报告具体资源。
    private let fileName: String
    /// 完成、失败或取消均打开一次，防止时间限制取消后挂住测试。
    private let settled = LifecycleTestSignal()
    /// 真正提交 command buffer 的累计帧数，由 MetricsSink 事件确认。
    private(set) var submittedFrameCount = 0
    /// PlayerView 在 GPU 首帧完成后解除 Metal 层隐藏，观察到后置为 true。
    private(set) var completedPresentation = false
    /// 首个失败的原始错误，nil 表示尚未失败或已成功。
    private var failure: Error?

    /// 为当前独立播放器创建一次性呈现证据收集器。
    init(fileName: String) {
        self.fileName = fileName
    }

    /// 指标可能从渲染线程发出，仅把真实提交事件切回 MainActor 统计。
    nonisolated func record(_ event: MetricsEvent) {
        // 解码、prepare 和 firstFrameDuration 都不能替代 GPU 完成；只接纳真实提交计数。
        guard case .renderedFrame = event else { return }
        Task { @MainActor [weak self] in self?.recordSubmittedFrame() }
    }

    /// 累计已提交帧，随后检查 GPU 完成证据是否也已到达。
    private func recordSubmittedFrame() {
        // 终态后的在途指标不再修改当前结果。
        guard !settled.isSignalled else { return }
        submittedFrameCount += 1
        completeIfPresented()
    }

    /// KVO 观察到首帧公开层显示，说明 Session 已收到 command buffer 成功完成。
    func recordCompletedPresentation() {
        // 迟到的可见性事件不能覆盖较早发生的播放失败。
        guard !settled.isSignalled else { return }
        completedPresentation = true
        completeIfPresented()
    }

    /// 只有提交证据与 GPU 完成证据同时存在才允许测试继续清理。
    private func completeIfPresented() {
        // 两条回调来自不同队列，接纳顺序可以相反，但缺少任何一条都不成功。
        guard submittedFrameCount > 0, completedPresentation else { return }
        settled.signal()
    }

    /// 等待呈现或真实失败；测试超时取消同样唤醒门闩，不采用 sleep 轮询。
    func waitForCompletedPresentation() async throws {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            await settled.wait()
            // delegate 的原始错误优先返回，不包装成通用渲染失败。
            if let failure { throw failure }
            try Task.checkCancellation()
        } onCancel: {
            // 取消处理器不保证运行在主线程，显式调度后再改变等待状态。
            Task { @MainActor [weak self] in self?.completeWithFailure(CancellationError()) }
        }
    }

    /// 记录首个错误并立即恢复等待者，不让素材失败演变成测试超时。
    private func completeWithFailure(_ error: Error) {
        // 清理产生的 stopped 和迟到回调不得覆盖已确认的首帧结果。
        guard !settled.isSignalled else { return }
        failure = error
        settled.signal()
    }

    /// 开始回调仅代表媒体时钟运行，不能在此打开呈现门闩。
    func playerDidStart(_ player: PlayerView) {}

    /// 元数据正确不代表已取得 drawable，因此保持等待实际 GPU 完成。
    func player(_ player: PlayerView, didUpdate metadata: AssetMetadata) {}

    /// 首帧前出现终态即为失败；成功后的测试主动清理不会改写结果。
    func playerDidFinish(_ player: PlayerView, reason: FinishReason) {
        completeWithFailure(HostedPresentationError.finishedBeforeFirstFrame(fileName: fileName, reason: reason))
    }

    /// 用真实准备、解码或 Metal 错误唤醒等待者。
    func player(_ player: PlayerView, didFail error: Error) {
        completeWithFailure(error)
    }
}

/// 素材没有报 SDK 错误却在首帧前结束时，提供可定位的集成测试失败。
private enum HostedPresentationError: Error, CustomStringConvertible {
    /// 指定素材在提交和完成首帧之前收到终态。
    case finishedBeforeFirstFrame(fileName: String, reason: FinishReason)

    /// 保留文件名和终态原因，便于在 27 个样本中找到失败项。
    var description: String {
        switch self {
        // 此错误只表达首帧缺失，真正的 SDK Error 由 probe 原样抛出。
        case let .finishedBeforeFirstFrame(fileName, reason):
            "\(fileName) finished before a completed GPU frame: \(reason)"
        }
    }
}

/// 主线程测试中的一次性门闩；先 signal 后 wait 也不会丢通知，不靠 sleep 猜测调度。
@MainActor
private final class LifecycleTestSignal {
    /// 是否已打开；打开后保持为 true，便于断言某一步尚未完成。
    private(set) var isSignalled = false
    /// 尚未打开时注册的等待者；signal 时一次性全部恢复。
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// 等待显式 signal；任务取消不会替代被测资源真正退出的事实。
    func wait() async {
        // 已发生的通知必须被后来的等待者立即观察到，避免时序造成漏唤醒。
        if isSignalled { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    /// 幂等地打开门闩并恢复全部等待者。
    func signal() {
        // 重复的播放器回调不能多次恢复 continuation。
        guard !isSignalled else { return }
        isSignalled = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

/// 将开始或失败回调归并为一次可等待结果，避免启动失败时测试永久等开始事件。
@MainActor
private final class LifecycleStartProbe {
    /// 首个启动结果的到达信号。
    let signal = LifecycleTestSignal()
    /// 启动失败的实际错误；nil 表示成功开始或尚未得到结果。
    private(set) var error: Error?

    /// 记录首个开始结果；后来的终态不会覆盖已经观察到的开始事实。
    func complete(error: Error? = nil) {
        // 一次启动只接纳首个结果，避免后续停止错误改写断言依据。
        guard !signal.isSignalled else { return }
        self.error = error
        signal.signal()
    }
}

/// 在收到取消后仍等测试放行的 provider，用于证明清理等待的是实际退出。
@MainActor
private final class ControlledLifecycleProvider: DynamicContentProvider {
    /// provider 已进入 resolve，此后清理才能触发有意义的取消。
    let entered = LifecycleTestSignal()
    /// 取消处理器已执行，但不代表 resolve 已经返回。
    let cancellationReceived = LifecycleTestSignal()
    /// 由测试显式打开的退出门，不受任务取消自动影响。
    let release = LifecycleTestSignal()
    /// resolve 即将以取消错误返回，用于与提前返回的 clear 区分。
    let exited = LifecycleTestSignal()

    /// 等测试放行后检查取消；清理过程中抛 CancellationError，不再生成纹理。
    func resolve(tag: String, source: SourceMetadata) async throws -> DynamicContent? {
        entered.signal()
        await withTaskCancellationHandler {
            await release.wait()
        } onCancel: { [cancellationReceived] in
            // 取消处理器可能在任意执行器运行，回主线程记录后再让测试检查清理状态。
            Task { @MainActor in cancellationReceived.signal() }
        }
        exited.signal()
        try Task.checkCancellation()
        return nil
    }
}
