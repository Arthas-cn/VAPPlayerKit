import QuartzCore
import Testing
@testable import VAPPlayerKit

/// 验证显式排空后的资源释放，以及取消 provider 时逻辑取消与实际退出的区别。
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct PlaybackResourceLifecycleTests {
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
