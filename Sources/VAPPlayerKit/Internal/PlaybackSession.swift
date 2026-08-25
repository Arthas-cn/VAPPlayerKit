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

/// 一次 play 对应一个全新 session。所有低层对象、异步回调和终态都由 token 隔离。
@MainActor
final class PlaybackSession {
    /// 本 session 的唯一标识。过期回调必须丢弃。
    let token: SessionToken
    /// 本次播放的本地文件 URL。
    let url: URL
    /// session 持有的 options 深拷贝，宿主事后修改原对象不影响本 session。
    let options: PlaybackOptions

    /// 当前状态机。只有合法迁移才会改写。
    private(set) var state: SessionState = .idle
    /// prepare 成功后的不可变 metadata。
    private(set) var metadata: AssetMetadata?
    /// 宿主 PlayerView 的 Metal 呈现层，renderer 只弱引用它。
    private let metalLayer: CAMetalLayer
    /// MP4 / vapc 解析器。缓存命中时不会真正执行 inspection。
    private let inspector: AssetInspector
    /// 解码后端，向 ring buffer 产出带 PTS 的帧。
    private let frameSource: FrameSource
    /// 固定容量帧缓冲，满时对 decoder 形成背压。重建 decoder 时替换 buffer，避免旧 reader 写入新一轮。
    private var ringBuffer: FrameRingBuffer
    /// 本 session 私有媒体时钟，pause 冻结、resume 重算 offset。
    private let clock: MediaClock
    /// NV12 packed 帧合成到 CAMetalLayer。
    private let renderer: MetalRenderer
    /// 动态图片 / 文字解析。不进解码线程。
    private let dynamicResolver: DynamicResolver
    /// 按 AudioMode 管理内嵌音轨，不反向驱动视频状态机。
    private let audioCoordinator: AudioCoordinator
    /// VSYNC 采样器，每次 tick 询问当前 media time。
    private let pacer: FramePacer
    /// inspection 结果，含 vapc 布局。播放中只读。
    private var inspection: InspectionResult?
    /// 已物化的动态槽位纹理内容。
    private var dynamicSnapshot = DynamicSnapshot.empty
    /// SDWebImage 动图槽位驱动器。无动图时为空操作。
    private let animatedPlayback = AnimatedDynamicPlayback()
    /// 文字跑马灯 UV 驱动器。无溢出文字时为空操作。时钟与视频 loop 无关。
    private let marqueePlayback = MarqueeDynamicPlayback()
    /// 当前循环的 decoder 是否已产出完毕。
    private var sourceEnded = false
    /// 已完成的循环次数，用于对照 `loopCount`。
    private var completedLoops = 0
    /// 终态是否已回调。保证 finish / fail 互斥且最多一次。
    private var terminalDelivered = false
    /// 是否已派发首帧回调。
    private var firstFrameDelivered = false
    /// 是否已派发 start 回调。
    private var startDelivered = false
    /// 媒体时钟是否已启动。首帧入缓冲且音频就绪后才为 true。
    private var timelineStarted = false
    /// 循环 rewind 期间音频未就绪时阻止时钟启动。
    private var audioReady = true
    /// 上一帧 GPU 提交尚未完成，tick 不得再提交，避免堆积 command buffer。
    private var renderPending = false
    /// drawable 暂不可用时暂存的待渲染帧。
    private var pendingFrame: DecodedFrame?
    /// 本循环最后一帧的结束时间，用于判断循环是否播完。
    private var lastFrameEndTime: TimeInterval?
    /// 当前 decoder 生产周期。后台取消旧 reader 后，旧完成回调必须失效。
    private var sourceGeneration: UInt64 = 0
    /// 前后台切换可能令 AVAssetReader 失效，前台恢复时需要从冻结位置重建。
    private var decoderNeedsRestart = false
    /// 当前 GPU 提交周期。后台失效的 command buffer completion 不能污染恢复后的状态。
    private var renderGeneration: UInt64 = 0
    /// prepare 开始时间，用于埋点。
    private var prepareStartedAt: CFTimeInterval = 0
    /// play 开始时间，用于首帧耗时埋点。
    private var playStartedAt: CFTimeInterval = 0

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
        objcDynamicProvider: ObjCDynamicContentProvider?,
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
        self.dynamicResolver.objcProvider = objcDynamicProvider
    }

    /// 走全局缓存的 prepare 入口。
    func prepare() async throws -> AssetMetadata {
        try await prepare(using: nil)
    }

    /// 准备解码、动态内容和渲染管线，但不自动开播。
    ///
    /// `suppliedMetadata` 非空时，复用该对象携带的不可变 vapc 布局，跳过 MP4/vapc
    /// 再解析，并把它写入全局 `AssetMetadataCache`。为空时走全局缓存：命中则复用，
    /// miss 则 inspection，同一 URL 的并发 miss 会合并为一次解析。
    ///
    /// 解码轨准备仍会执行。复用路径会在 decoder prepare 前后各校验一次文件签名，
    /// 避免过期或被替换的媒体进入渲染器。
    func prepare(using suppliedMetadata: AssetMetadata?) async throws -> AssetMetadata {
        guard state == .idle else {
            if let metadata, state == .ready { return metadata }
            throw PlaybackError.cancelled
        }
        state = .preparing
        prepareStartedAt = CACurrentMediaTime()
        do {
            let inspection: InspectionResult
            let reusedMetadata: AssetMetadata?
            if let suppliedMetadata {
                inspection = try AssetMetadataCache.reusableInspection(from: suppliedMetadata, for: url)
                AssetMetadataCache.shared.insert(suppliedMetadata, for: url)
                reusedMetadata = suppliedMetadata
            } else {
                let resolution = try await AssetMetadataCache.shared.resolve(url: url, inspector: inspector)
                inspection = resolution.inspection
                reusedMetadata = resolution.reusedMetadata
            }
            try ensureActive()
            let sourceMetadata = try await frameSource.prepare()
            try ensureActive()
            // 解码轨打开后立刻再验一次签名，挡住 inspection 到 decoder prepare 之间的文件替换。
            if let reusedMetadata {
                try AssetMetadataCache.validateReusableFileSignature(reusedMetadata, for: url)
            }
            guard approximatelyEqual(sourceMetadata.encodedVideoSize, inspection.metadata.encodedVideoSize),
                  sourceMetadata.codec == inspection.metadata.codec else {
                throw PlaybackError.invalidMP4(reason: "Inspector and decoder track descriptions disagree.")
            }
            try await renderer.prepare(layer: metalLayer)
            try ensureActive()
            let dynamicStartedAt = CACurrentMediaTime()
            do {
                dynamicSnapshot = try await dynamicResolver.resolve(
                    sources: inspection.vapc.sources,
                    imagePlayback: options.dynamicImagePlaybackMode,
                    textOverflow: options.dynamicTextOverflowMode
                )
                metricsSink?.record(.dynamicResolveDuration(CACurrentMediaTime() - dynamicStartedAt))
            } catch {
                if (error as? PlaybackError)?.code == .dynamicContentTimeout {
                    metricsSink?.record(.dynamicTimeout)
                }
                throw error
            }
            try ensureActive()
            try await renderer.prepareDynamic(dynamicSnapshot)
            try ensureActive()
            animatedPlayback.prepare(snapshot: dynamicSnapshot, renderer: renderer)
            marqueePlayback.prepare(
                snapshot: dynamicSnapshot,
                renderer: renderer,
                speed: options.marqueeSpeed,
                startDelay: options.marqueeStartDelay
            )
            try ensureActive()
            try await audioCoordinator.prepare(
                url: url,
                mode: options.audioMode,
                containsAudio: inspection.metadata.containsAudio
            )
            try ensureActive()
            // 动态内容和音频准备完成后再验一次，覆盖整个 prepare 窗口内的文件改写。
            if let reusedMetadata {
                try AssetMetadataCache.validateReusableFileSignature(reusedMetadata, for: url)
            }
            self.inspection = inspection
            metadata = inspection.metadata
            state = .ready
            metricsSink?.record(.prepareDuration(CACurrentMediaTime() - prepareStartedAt))
            onMetadata?(inspection.metadata)
            return inspection.metadata
        } catch {
            fail(error)
            throw error
        }
    }

    /// 从 ready 进入 playing：重置循环状态、启动动图槽位和解码生产。
    func play() {
        guard state == .ready else { return }
        decoderNeedsRestart = false
        state = .playing
        completedLoops = 0
        firstFrameDelivered = false
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

    /// 暂停出帧、时钟和音频，保留进度。仅 playing 可 pause。
    func pause() {
        guard state == .playing else { return }
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
        let wasSuspended = state == .suspended
        state = .playing
        if wasSuspended && decoderNeedsRestart {
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
            audioCoordinator.seek(to: mediaSeconds) { [weak self, token] in
                guard let self, self.token == token, !self.terminalDelivered, self.state == .playing else { return }
                self.audioReady = true
                self.startTimelineIfReady()
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
        tearDown()
        state = .finished
        deliverFinish(reason)
    }

    /// 启动或重启解码生产。每个循环都会新建一次 reader，旧回调靠 generation 丢弃。
    private func startSource(startTime: CMTime = .zero, frameIndexOffset: Int = 0) {
        sourceGeneration &+= 1
        let currentSourceGeneration = sourceGeneration
        ringBuffer.reset()
        sourceEnded = false
        pendingFrame = nil
        lastFrameEndTime = nil
        let sink = metricsSink
        let peak = RingBufferPeakRecorder(sink: sink)
        let buffer = ringBuffer
        frameSource.startProducing(
            to: buffer,
            token: token,
            startTime: startTime,
            frameIndexOffset: frameIndexOffset,
            didProduce: { [weak self, token] count in
                sink?.record(.decodedFrame)
                peak.recordIfNeeded(count)
                Task { @MainActor in
                    guard
                        let self,
                        self.token == token,
                        self.sourceGeneration == currentSourceGeneration,
                        !self.terminalDelivered
                    else { return }
                    self.startTimelineIfReady()
                }
            },
            completion: { [weak self, token] result in
                Task { @MainActor in
                    guard
                        let self,
                        self.token == token,
                        self.sourceGeneration == currentSourceGeneration,
                        !self.terminalDelivered
                    else { return }
                    switch result {
                    case .success:
                        self.sourceEnded = true
                        if !self.timelineStarted, self.ringBuffer.count == 0 {
                            self.fail(PlaybackError.decoderFailed(osStatus: -1))
                        } else {
                            self.startTimelineIfReady()
                        }
                    case .failure(let error):
                        if self.state == .suspended || self.decoderNeedsRestart {
                            self.decoderNeedsRestart = true
                        } else if error.code != .cancelled {
                            self.fail(error)
                        }
                    }
                }
            }
        )
    }

    /// 以 vapc fps 把恢复位置映射到动态 attachment 的原始 frame index。
    private func frameIndex(for mediaSeconds: TimeInterval) -> Int {
        guard let inspection else { return 0 }
        let fps = Double(max(1, inspection.vapc.framesPerSecond))
        let index = Int((mediaSeconds * fps).rounded(.down))
        return min(max(0, index), max(0, inspection.vapc.frameCount - 1))
    }

    /// 在主 run loop 上订阅 VSYNC，每次只询问当前 media time。
    private func startPacer() {
        pacer.start { [weak self] in
            self?.tick()
        }
    }

    /// 缓冲里已有帧、音频就绪且仍在 playing 时启动媒体时钟并回调 start。
    private func startTimelineIfReady() {
        guard state == .playing, !timelineStarted, audioReady, ringBuffer.count > 0 else { return }
        timelineStarted = true
        clock.resume()
        audioCoordinator.start()
        marqueePlayback.start()
        startPacer()
        if !startDelivered {
            startDelivered = true
            onStart?()
        }
    }

    /// VSYNC 回调：取出到期帧、提交 GPU，并在本循环播完时进入 completeLoop。
    /// 上一帧 GPU 未完成时跳过本次 tick，避免堆积 command buffer。
    private func tick() {
        guard state == .playing, timelineStarted, let inspection else { return }
        let mediaSeconds = clock.currentMediaTime()
        let mediaTime = CMTime(seconds: mediaSeconds, preferredTimescale: 600)
        guard !renderPending else { return }
        let due = ringBuffer.dequeueDue(at: mediaTime)
        var dropped = due.dropped
        var frame = pendingFrame
        if let newerFrame = due.frame {
            if frame != nil { dropped += 1 }
            frame = newerFrame
            pendingFrame = nil
        }
        if dropped > 0 {
            for _ in 0..<dropped { metricsSink?.record(.droppedFrame) }
        }
        if let frame {
            guard frame.token == token else { return }
            let frameEnd = CMTimeAdd(frame.presentationTime, frame.duration).seconds
            if frameEnd.isFinite {
                lastFrameEndTime = max(lastFrameEndTime ?? frameEnd, frameEnd)
            }
            renderPending = true
            let currentRenderGeneration = renderGeneration
            marqueePlayback.apply()
            renderer.render(frame, vapc: inspection.vapc) { [weak self, token] result in
                Task { @MainActor in
                    guard
                        let self,
                        self.token == token,
                        self.renderGeneration == currentRenderGeneration,
                        !self.terminalDelivered
                    else { return }
                    self.renderPending = false
                    switch result {
                    case .success(true):
                        self.pendingFrame = nil
                        self.metricsSink?.record(.renderedFrame)
                        self.marqueePlayback.notePresented(frame: frame, vapc: inspection.vapc)
                        if !self.firstFrameDelivered {
                            self.firstFrameDelivered = true
                            self.metricsSink?.record(.firstFrameDuration(CACurrentMediaTime() - self.playStartedAt))
                            self.onFirstFrame?()
                        }
                    case .success(false):
                        self.pendingFrame = frame
                        self.metricsSink?.record(.metalDrawableFailure)
                    case .failure(let error):
                        if self.state != .suspended, error.code != .cancelled { self.fail(error) }
                    }
                }
            }
        }
        if Self.shouldCompleteLoop(
            sourceEnded: sourceEnded,
            bufferedFrameCount: ringBuffer.count,
            hasPendingFrame: pendingFrame != nil,
            renderPending: renderPending,
            lastFrameEndTime: lastFrameEndTime,
            mediaTime: mediaSeconds
        ) {
            completeLoop()
        }
    }

    /// 一轮结束：未达 `loopCount` 则 rewind 音频并重新解码；否则正常完成。
    private func completeLoop() {
        completedLoops += 1
        if options.loopCount == 0 || completedLoops < options.loopCount {
            timelineStarted = false
            audioReady = false
            clock.reset()
            pacer.stop()
            audioCoordinator.rewind { [weak self, token] in
                guard let self, self.token == token, !self.terminalDelivered else { return }
                self.audioReady = true
                self.startTimelineIfReady()
            }
            startSource()
        } else {
            state = .finished
            tearDown()
            deliverFinish(.completed)
        }
    }

    /// 不可恢复错误。与 finish 互斥，且每个 session 最多一次。
    private func fail(_ error: Error) {
        guard !terminalDelivered else { return }
        state = .failed
        tearDown()
        terminalDelivered = true
        onFailure?(error)
    }

    /// 停止 pacer / 解码 / 动态内容 / 音频 / GPU，不派发终态。
    private func tearDown() {
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
    }

    /// 派发正常终态。已 fail 过则忽略。
    private func deliverFinish(_ reason: FinishReason) {
        guard !terminalDelivered else { return }
        terminalDelivered = true
        metricsSink?.record(.sessionFinished(reason))
        onFinish?(reason)
    }

    /// prepare 过程中若被取消或已终态，立即抛 `cancelled`。
    private func ensureActive() throws {
        guard state == .preparing, !terminalDelivered else { throw PlaybackError.cancelled }
    }

    /// 编码尺寸允许 1 像素误差，避免整数取整导致 inspector 与 decoder 误判不一致。
    private func approximatelyEqual(_ lhs: CGSize, _ rhs: CGSize) -> Bool {
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

/// 解码回调在非主线程；在 decoder queue 上记录 ring buffer 峰值，避免每帧 hop 到 actor。
private final class RingBufferPeakRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private weak var sink: MetricsSink?
    /// 本次生产周期见过的最大缓冲占用。
    private var peak = 0

    init(sink: MetricsSink?) {
        self.sink = sink
    }

    /// 仅在峰值升高时上报，避免每帧都打点。
    func recordIfNeeded(_ count: Int) {
        lock.lock()
        guard count > peak else {
            lock.unlock()
            return
        }
        peak = count
        let sink = sink
        lock.unlock()
        sink?.record(.ringBufferPeak(count))
    }
}
