import Foundation
import QuartzCore
import CoreMedia

/// 单次播放 session 的内部状态机。对外只通过 delegate 暴露 start / finish / fail。
enum SessionState: Equatable {
    /// 刚创建，尚未 prepare。
    case idle
    /// 正在 inspection / 解码准备 / 动态内容 / GPU pipeline。
    case preparing
    /// prepare 完成，可以 `play()`。
    case ready
    /// 正在出帧。
    case playing
    /// 宿主 `pause()`，冻结时钟并保留进度。
    case paused
    /// 离屏、零尺寸或进后台导致的挂起，回到前台可 resume。
    case suspended
    /// 已正常或被停止结束。
    case finished
    /// 正在拆除资源，即将进入 finished。
    case stopping
    /// 不可恢复错误，已回调 onFailure。
    case failed
}

/// 通过锁保证每轮只记录一次 GPU 首次提交指标，不作为可见首帧证据。
final class FirstSubmissionGate: @unchecked Sendable {
    /// 保护 claimed，指标可以来自 renderQueue。
    let lock = NSLock()
    /// 当前轮是否已记录首次提交，下一轮启动时复位。
    var claimed = false

    /// 在新一轮开始时复位一次性标记，与读取使用相同锁。
    func reset() {
        lock.lock()
        claimed = false
        lock.unlock()
    }

    /// 首次调用返回 true，之后返回 false，防止多次 GPU 提交重复记首帧。
    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !claimed else { return false }
        claimed = true
        return true
    }
}

/// 一次 play 对应一个全新 session。所有低层对象、异步回调和终态都由 token 隔离。
@MainActor
final class PlaybackSession {
    /// 本 session 的唯一标识。过期回调必须丢弃。
    let token: SessionToken
    /// 本次播放的本地文件 URL。
    let url: URL
    /// 本次不可变配置快照；宿主之后修改自己的值不会影响此 session。
    let options: PlaybackOptions

    /// 正在执行的完整准备任务；取消及销毁后仍需等待真实退出。
    var preparationTask: Task<AssetMetadata, Error>?
    /// 单次终态的排空任务；完成前持续持有 session 与底层文件引用。
    var teardownTask: Task<Void, Never>?
    /// 当前状态机。只有合法迁移才会改写。
    var state: SessionState = .idle
    /// prepare 成功后的不可变 metadata。
    var metadata: AssetMetadata?
    /// 宿主 PlayerView 的 Metal 呈现层，renderer 只弱引用它。
    let metalLayer: CAMetalLayer
    /// MP4 / vapc 解析器。缓存命中时不会真正执行 inspection。
    let inspector: AssetInspector
    /// 解码后端，向 ring buffer 产出带 PTS 的帧。
    let frameSource: FrameSource
    /// 固定容量帧缓冲，满时对 decoder 形成背压。重建 decoder 时替换 buffer，避免旧 reader 写入新一轮。
    var ringBuffer: FrameRingBuffer
    /// 本 session 私有媒体时钟，pause 冻结、resume 重算 offset。
    let clock: MediaClock
    /// NV12 packed 帧合成到 CAMetalLayer。
    let renderer: MetalRenderer
    /// 动态图片 / 文字解析。不进解码线程。
    let dynamicResolver: DynamicResolver
    /// 按 AudioMode 管理内嵌音轨，不反向驱动视频状态机。
    let audioCoordinator: AudioCoordinator
    /// VSYNC 采样器，每次 tick 询问当前 media time。
    let pacer: FramePacer
    /// inspection 结果，含 vapc 布局。播放中只读。
    var inspection: InspectionResult?
    /// 已物化的动态槽位纹理内容。
    var dynamicSnapshot = DynamicSnapshot.empty
    /// SDWebImage 动图槽位驱动器。无动图时为空操作。
    let animatedPlayback = AnimatedDynamicPlayback()
    /// 文字跑马灯 UV 驱动器。无溢出文字时为空操作。时钟与视频 loop 无关。
    let marqueePlayback = MarqueeDynamicPlayback()
    /// 当前循环的 decoder 是否已产出完毕。
    var sourceEnded = false
    /// 已完成的循环次数，用于对照 `loopCount`。
    var completedLoops = 0
    /// 终态是否已回调。保证 finish / fail 互斥且最多一次。
    var terminalDelivered = false
    /// 是否已派发首帧回调。
    var firstFrameDelivered = false
    /// 是否已派发 start 回调。
    var startDelivered = false
    /// 媒体时钟是否已启动。首帧入缓冲且音频就绪后才为 true。
    var timelineStarted = false
    /// 循环 rewind 期间音频未就绪时阻止时钟启动。
    var audioReady = true
    /// 上一帧 GPU 提交尚未完成，tick 不得再提交，避免堆积 command buffer。
    var renderPending = false
    /// drawable 暂不可用时暂存的待渲染帧。
    var pendingFrame: DecodedFrame?
    /// 本循环最后一帧的结束时间，用于判断循环是否播完。
    var lastFrameEndTime: TimeInterval?
    /// 当前 decoder 生产周期。后台取消旧 reader 后，旧完成回调必须失效。
    var sourceGeneration: UInt64 = 0
    /// 前后台切换可能令 AVAssetReader 失效，前台恢复时需要从冻结位置重建。
    var decoderNeedsRestart = false
    /// 当前音频定位身份；暂停保留当前结果，挂起/续轮使更早的定位失效。
    var audioSeekGeneration: UInt64 = 0
    /// 当前 GPU 提交周期。后台失效的 command buffer completion 不能污染恢复后的状态。
    var renderGeneration: UInt64 = 0
    /// prepare 开始时间，用于埋点。
    var prepareStartedAt: CFTimeInterval = 0
    /// play 开始时间，用于首帧耗时埋点。
    var playStartedAt: CFTimeInterval = 0
    /// Thread-safe one-shot gate for metrics emitted at command submission.
    let firstSubmissionGate = FirstSubmissionGate()

    /// 可选埋点。decoder 回调可能在后台线程记录。
    weak var metricsSink: MetricsSink?
    /// 进入 playing 且时钟启动后回调一次。
    var onStart: (() -> Void)?
    /// 第一帧成功上屏后回调一次。
    var onFirstFrame: (() -> Void)?
    /// metadata 解析完成后回调，供宿主布局。
    var onMetadata: ((AssetMetadata) -> Void)?
    /// 正常终态。与 onFailure 互斥。
    var onFinish: ((FinishReason) -> Void)?
    /// 不可恢复错误。与 onFinish 互斥。
    var onFailure: ((Error) -> Void)?

    /// 组装一次播放所需的全部子系统。测试可注入 mock 的 FrameSource / Inspector。
    init(
        url: URL,
        options: PlaybackOptions,
        metalLayer: CAMetalLayer,
        dynamicProvider: DynamicContentProvider?,
        frameSource: FrameSource? = nil,
        inspector: AssetInspector = AssetInspector(),
        ringBuffer: FrameRingBuffer = FrameRingBuffer(),
        clock: MediaClock = MediaClock(),
        renderer: MetalRenderer = MetalRenderer(),
        dynamicResolver: DynamicResolver? = nil,
        audioCoordinator: AudioCoordinator? = nil,
        pacer: FramePacer = FramePacer()
    ) {
        self.token = .make()
        self.url = url
        self.options = options
        self.metalLayer = metalLayer
        self.inspector = inspector
        self.frameSource = frameSource ?? AVAssetReaderFrameSource(url: url)
        self.ringBuffer = ringBuffer
        self.clock = clock
        self.renderer = renderer
        self.dynamicResolver = dynamicResolver ?? DynamicResolver()
        self.audioCoordinator = audioCoordinator ?? AudioCoordinator()
        self.pacer = pacer
        self.dynamicResolver.provider = dynamicProvider
        self.audioCoordinator.onFailure = { [weak self] error in
            self?.fail(error)
        }
    }

    /// 从 ready 进入 playing：重置循环状态、启动动图槽位和解码生产。
    func play() {
        guard state == .ready else { return }
        decoderNeedsRestart = false
        state = .playing
        completedLoops = 0
        firstFrameDelivered = false
        firstSubmissionGate.reset()
        startDelivered = false
        timelineStarted = false
        audioReady = true
        renderPending = false
        pendingFrame = nil
        lastFrameEndTime = nil
        playStartedAt = CACurrentMediaTime()
        clock.reset()
        animatedPlayback.start()
        marqueePlayback.resetClock()
        startSource()
    }

    /// 把 PlayerView 当前 drawable 尺寸和 contentMode 同步给 renderer。
    func updateRenderSnapshot(_ snapshot: RenderSnapshot) {
        renderer.update(snapshot: snapshot)
    }

    /// 立即同步本次静音期望值，准备中的音轨也会在创建时使用它。
    func setMuted(_ isMuted: Bool) { audioCoordinator.isMuted = isMuted }

    /// 暂停出帧、时钟和音频，保留进度；用户暂停可覆盖系统挂起。
    func pause() {
        guard state == .playing || state == .suspended else { return }
        state = .paused
        pacer.stop()
        frameSource.pause()
        if timelineStarted { clock.pause() }
        audioCoordinator.pause()
        animatedPlayback.pause()
        marqueePlayback.pause()
    }

    /// 从 pause / suspend 恢复。若时钟尚未启动，等到首帧入缓冲后再开播。
    func resume() {
        guard state == .paused || state == .suspended else { return }
        state = .playing
        if decoderNeedsRestart {
            decoderNeedsRestart = false
            metricsSink?.record(.decoderRebuild)
            timelineStarted = false
            audioReady = false
            sourceEnded = false
            renderPending = false
            pendingFrame = nil
            lastFrameEndTime = nil
            let mediaSeconds = max(0, clock.currentMediaTime())
            let startTime = CMTime(seconds: mediaSeconds, preferredTimescale: 600)
            startSource(startTime: startTime, frameIndexOffset: frameIndex(for: mediaSeconds))
            audioSeekGeneration &+= 1
            let seekGeneration = audioSeekGeneration
            audioCoordinator.seek(to: mediaSeconds) { [weak self, token] result in
                guard let self, self.token == token, !self.terminalDelivered,
                      self.audioSeekGeneration == seekGeneration else { return }
                // 定位失败不能跨过音画同步屏障，旧代回调已由上面的 token 门过滤。
                switch result {
                // 只有当前定位真实完成后才允许时钟继续。
                case .success:
                    self.audioReady = true
                    self.startTimelineIfReady()
                // 当前轮定位失败需要停画面和声音，不能降级无声成功。
                case .failure(let error):
                    self.fail(error)
                }
            }
        } else if timelineStarted {
            frameSource.resume()
            clock.resume()
            audioCoordinator.resume()
            startPacer()
        } else {
            frameSource.resume()
            startTimelineIfReady()
        }
        animatedPlayback.start()
        if timelineStarted {
            marqueePlayback.start()
        }
    }

    /// 离屏、零尺寸或进后台时挂起。与 pause 相同冻结时钟，但状态记为 suspended。
    func suspend() {
        guard state == .playing else { return }
        state = .suspended
        pacer.stop()
        decoderNeedsRestart = true
        sourceGeneration &+= 1
        audioSeekGeneration &+= 1
        frameSource.cancel()
        // Do not reset the old buffer here: serialized reader cancellation may still
        // be finishing. Replace it so the resumed reader cannot share that buffer.
        ringBuffer = FrameRingBuffer()
        if timelineStarted { clock.pause() }
        audioCoordinator.pause()
        animatedPlayback.pause()
        marqueePlayback.pause()
        renderGeneration &+= 1
        renderPending = false
        pendingFrame = nil
    }

    /// 拆除资源并给出终态。idle 或已终态时为空操作。
    func stop(reason: FinishReason = .stopped) {
        guard !terminalDelivered, state != .idle else { return }
        state = .stopping
        deliverFinish(reason)
    }

    /// 一轮结束：未达 `loopCount` 则 rewind 音频并重新解码；否则正常完成。
    func completeLoop() {
        completedLoops += 1
        if options.loopCount == 0 || completedLoops < options.loopCount {
            timelineStarted = false
            audioReady = false
            clock.reset()
            pacer.stop()
            audioSeekGeneration &+= 1
            let seekGeneration = audioSeekGeneration
            audioCoordinator.rewind { [weak self, token] result in
                guard let self, self.token == token, !self.terminalDelivered,
                      self.audioSeekGeneration == seekGeneration else { return }
                // 定位失败不能跨过音画同步屏障，旧代回调已由上面的 token 门过滤。
                switch result {
                // 只有当前定位真实完成后才允许时钟继续。
                case .success:
                    self.audioReady = true
                    self.startTimelineIfReady()
                // 当前轮定位失败需要停画面和声音，不能降级无声成功。
                case .failure(let error):
                    self.fail(error)
                }
            }
            startSource()
        } else {
            deliverFinish(.completed)
        }
    }

    /// 不可恢复错误。与 finish 互斥，且每个 session 最多一次。
    func fail(_ error: Error) {
        guard !terminalDelivered else { return }
        // 先关闭终态门再停止音频：stop 可同步完成定位回调，不能重入改写当前终态。
        state = .failed
        terminalDelivered = true
        tearDown()
        onFailure?(error)
    }

    /// 停止 pacer / 解码 / 动态内容 / 音频 / GPU，不派发终态。
    func tearDown() {
        // 同步关闭所有新提交入口；异步任务由下面唯一的 teardown 持有到真正排空。
        preparationTask?.cancel()
        pacer.stop()
        ringBuffer.cancelWaiting()
        frameSource.cancel()
        dynamicResolver.cancel()
        animatedPlayback.stop()
        marqueePlayback.stop()
        audioCoordinator.stop()
        ringBuffer.removeAll()
        pendingFrame = nil
        renderPending = false
        renderer.dispose()
        guard teardownTask == nil else { return }
        let preparing = preparationTask
        teardownTask = Task { @MainActor in
            // 准备可能还在等待 metadata/provider；必须先收口，才能做最终 GPU 释放。
            if let preparing { _ = await preparing.result }
            await self.dynamicResolver.cancelAndWait()
            await self.frameSource.cancelAndWait()
            await self.audioCoordinator.stopAndWait()
            await self.renderer.disposeAndWait()
            self.dynamicSnapshot = .empty
            self.inspection = nil
            self.dynamicResolver.provider = nil
        }
    }

    /// 停止当前 session，并等待准备、provider、音轨、decoder 和 GPU 真实结束。
    func clearAndWait() async {
        // idle 也可能已经分配了子系统；显式排空无需伪造一个播放完成事件。
        if !terminalDelivered, state != .idle { stop(reason: .cancelled) }
        if teardownTask == nil { tearDown() }
        await teardownTask?.value
    }

    /// 派发正常终态。已 fail 过则忽略。
    func deliverFinish(_ reason: FinishReason) {
        guard !terminalDelivered else { return }
        // 子系统 stop 会同步回调 cancelled，必须在进入清理前关闭所有结果提交资格。
        terminalDelivered = true
        state = .finished
        tearDown()
        metricsSink?.record(.sessionFinished(reason))
        onFinish?(reason)
    }

    /// prepare 过程中若被取消或已终态，立即抛 `cancelled`。
    func ensureActive() throws {
        guard state == .preparing, !terminalDelivered, !Task.isCancelled else { throw PlaybackError.cancelled }
    }

    /// 编码尺寸允许 1 像素误差，避免整数取整导致 inspector 与 decoder 误判不一致。
    func approximatelyEqual(_ lhs: CGSize, _ rhs: CGSize) -> Bool {
        abs(lhs.width - rhs.width) < 1 && abs(lhs.height - rhs.height) < 1
    }

    /// 判断本循环是否已经展示完最后一帧：解码结束、缓冲空、没有待渲染帧、媒体时间越过末帧。
    static func shouldCompleteLoop(
        sourceEnded: Bool,
        bufferedFrameCount: Int,
        hasPendingFrame: Bool,
        renderPending: Bool,
        lastFrameEndTime: TimeInterval?,
        mediaTime: TimeInterval
    ) -> Bool {
        guard let lastFrameEndTime else { return false }
        return sourceEnded
            && bufferedFrameCount == 0
            && !hasPendingFrame
            && !renderPending
            && mediaTime >= lastFrameEndTime
    }
}
