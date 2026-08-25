import Foundation
import QuartzCore
import CoreMedia

enum SessionState: Equatable {
    case idle
    case preparing
    case ready
    case playing
    case paused
    case suspended
    case finished
    case stopping
    case failed
}

/// 一次 play 对应一个全新 session。所有低层对象、异步回调和终态都由 token 隔离。
@MainActor
final class PlaybackSession {
    let token: SessionToken
    let url: URL
    let options: PlaybackOptions

    private(set) var state: SessionState = .idle
    private(set) var metadata: AssetMetadata?
    private let metalLayer: CAMetalLayer
    private let inspector: AssetInspector
    private let frameSource: FrameSource
    private let ringBuffer: FrameRingBuffer
    private let clock: MediaClock
    private let renderer: MetalRenderer
    private let dynamicResolver: DynamicResolver
    private let audioCoordinator: AudioCoordinator
    private let pacer: FramePacer
    private var inspection: InspectionResult?
    private var dynamicSnapshot = DynamicSnapshot.empty
    private let animatedPlayback = AnimatedDynamicPlayback()
    private var sourceEnded = false
    private var completedLoops = 0
    private var terminalDelivered = false
    private var firstFrameDelivered = false
    private var startDelivered = false
    private var timelineStarted = false
    private var audioReady = true
    private var renderPending = false
    private var pendingFrame: DecodedFrame?
    private var lastFrameEndTime: TimeInterval?
    private var prepareStartedAt: CFTimeInterval = 0
    private var playStartedAt: CFTimeInterval = 0

    weak var metricsSink: MetricsSink?
    var onStart: (() -> Void)?
    var onFirstFrame: (() -> Void)?
    var onMetadata: ((AssetMetadata) -> Void)?
    var onFinish: ((FinishReason) -> Void)?
    var onFailure: ((Error) -> Void)?

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

    func prepare() async throws -> AssetMetadata {
        try await prepare(using: nil)
    }

    /// Reuses the immutable vapc layout carried by metadata returned from a
    /// previous inspection. Decoder track preparation still runs so stale or
    /// mismatched media cannot reach the renderer.
    func prepare(using suppliedMetadata: AssetMetadata?) async throws -> AssetMetadata {
        guard state == .idle else {
            if let metadata, state == .ready { return metadata }
            throw PlaybackError.cancelled
        }
        state = .preparing
        prepareStartedAt = CACurrentMediaTime()
        do {
            let inspection: InspectionResult
            if let suppliedMetadata {
                inspection = try reusableInspection(from: suppliedMetadata)
            } else {
                inspection = try await inspector.inspectDetails(url: url)
            }
            try ensureActive()
            let sourceMetadata = try await frameSource.prepare()
            try ensureActive()
            if let suppliedMetadata {
                try validateReusableFileSignature(suppliedMetadata)
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
                    imagePlayback: options.dynamicImagePlaybackMode
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
            try ensureActive()
            try await audioCoordinator.prepare(
                url: url,
                mode: options.audioMode,
                containsAudio: inspection.metadata.containsAudio
            )
            try ensureActive()
            if let suppliedMetadata {
                try validateReusableFileSignature(suppliedMetadata)
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

    private func reusableInspection(from metadata: AssetMetadata) throws -> InspectionResult {
        guard metadata.sourceURL == url.standardizedFileURL,
              let document = metadata.playbackDocument else {
            throw PlaybackError.invalidVapc(
                reason: "AssetMetadata is not reusable or belongs to a different local URL."
            )
        }
        try validateReusableFileSignature(metadata)
        return InspectionResult(metadata: metadata, vapc: document)
    }

    private func validateReusableFileSignature(_ metadata: AssetMetadata) throws {
        guard metadata.sourceURL == url.standardizedFileURL else {
            throw PlaybackError.invalidVapc(
                reason: "AssetMetadata is not reusable or belongs to a different local URL."
            )
        }
        let values = try url.resourceValues(forKeys: [
            .fileSizeKey,
            .isRegularFileKey,
            .contentModificationDateKey,
            .fileResourceIdentifierKey
        ])
        guard values.isRegularFile == true,
              let expectedSize = metadata.sourceFileSize,
              let actualSize = values.fileSize,
              let expectedDate = metadata.sourceModificationDate,
              let actualDate = values.contentModificationDate,
              let expectedIdentifier = metadata.sourceFileIdentifier,
              let actualIdentifier = values.fileResourceIdentifier as? Data else {
            throw PlaybackError.invalidMP4(reason: "AssetMetadata file signature is unavailable.")
        }
        if expectedIdentifier != actualIdentifier {
            throw PlaybackError.invalidMP4(reason: "AssetMetadata is stale because the file identity changed.")
        }
        if expectedSize != Int64(actualSize) {
            throw PlaybackError.invalidMP4(reason: "AssetMetadata is stale because the file size changed.")
        }
        if expectedDate != actualDate {
            throw PlaybackError.invalidMP4(reason: "AssetMetadata is stale because the file changed.")
        }
    }

    func play() {
        guard state == .ready else { return }
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
        startSource()
    }

    func updateRenderSnapshot(_ snapshot: RenderSnapshot) {
        renderer.update(snapshot: snapshot)
    }

    func pause() {
        guard state == .playing else { return }
        state = .paused
        pacer.stop()
        frameSource.pause()
        if timelineStarted { clock.pause() }
        audioCoordinator.pause()
        animatedPlayback.pause()
    }

    func resume() {
        guard state == .paused || state == .suspended else { return }
        state = .playing
        frameSource.resume()
        if timelineStarted {
            clock.resume()
            audioCoordinator.resume()
            startPacer()
        } else {
            startTimelineIfReady()
        }
        animatedPlayback.start()
    }

    func suspend() {
        guard state == .playing else { return }
        state = .suspended
        pacer.stop()
        frameSource.pause()
        if timelineStarted { clock.pause() }
        audioCoordinator.pause()
        animatedPlayback.pause()
    }

    func stop(reason: FinishReason = .stopped) {
        guard !terminalDelivered, state != .idle else { return }
        state = .stopping
        tearDown()
        state = .finished
        deliverFinish(reason)
    }

    private func startSource() {
        ringBuffer.reset()
        sourceEnded = false
        pendingFrame = nil
        lastFrameEndTime = nil
        let sink = metricsSink
        let peak = RingBufferPeakRecorder(sink: sink)
        frameSource.startProducing(to: ringBuffer, token: token, didProduce: { [weak self, token] count in
            sink?.record(.decodedFrame)
            peak.recordIfNeeded(count)
            Task { @MainActor in
                guard let self, self.token == token, !self.terminalDelivered else { return }
                self.startTimelineIfReady()
            }
        }) { [weak self, token] result in
            Task { @MainActor in
                guard let self, self.token == token, !self.terminalDelivered else { return }
                switch result {
                case .success:
                    self.sourceEnded = true
                    if !self.timelineStarted, self.ringBuffer.count == 0 {
                        self.fail(PlaybackError.decoderFailed(osStatus: -1))
                    } else {
                        self.startTimelineIfReady()
                    }
                case .failure(let error):
                    self.fail(error)
                }
            }
        }
    }

    private func startPacer() {
        pacer.start { [weak self] in
            self?.tick()
        }
    }

    private func startTimelineIfReady() {
        guard state == .playing, !timelineStarted, audioReady, ringBuffer.count > 0 else { return }
        timelineStarted = true
        clock.resume()
        audioCoordinator.start()
        startPacer()
        if !startDelivered {
            startDelivered = true
            onStart?()
        }
    }

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
            renderer.render(frame, vapc: inspection.vapc) { [weak self, token] result in
                Task { @MainActor in
                    guard let self, self.token == token, !self.terminalDelivered else { return }
                    self.renderPending = false
                    switch result {
                    case .success(true):
                        self.pendingFrame = nil
                        self.metricsSink?.record(.renderedFrame)
                        if !self.firstFrameDelivered {
                            self.firstFrameDelivered = true
                            self.metricsSink?.record(.firstFrameDuration(CACurrentMediaTime() - self.playStartedAt))
                            self.onFirstFrame?()
                        }
                    case .success(false):
                        self.pendingFrame = frame
                        self.metricsSink?.record(.metalDrawableFailure)
                    case .failure(let error):
                        if error.code != .cancelled { self.fail(error) }
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

    private func fail(_ error: Error) {
        guard !terminalDelivered else { return }
        state = .failed
        tearDown()
        terminalDelivered = true
        onFailure?(error)
    }

    private func tearDown() {
        pacer.stop()
        ringBuffer.cancelWaiting()
        frameSource.cancel()
        dynamicResolver.cancel()
        animatedPlayback.stop()
        audioCoordinator.stop()
        ringBuffer.removeAll()
        pendingFrame = nil
        renderPending = false
        renderer.dispose()
    }

    private func deliverFinish(_ reason: FinishReason) {
        guard !terminalDelivered else { return }
        terminalDelivered = true
        metricsSink?.record(.sessionFinished(reason))
        onFinish?(reason)
    }

    private func ensureActive() throws {
        guard state == .preparing, !terminalDelivered else { throw PlaybackError.cancelled }
    }

    private func approximatelyEqual(_ lhs: CGSize, _ rhs: CGSize) -> Bool {
        abs(lhs.width - rhs.width) < 1 && abs(lhs.height - rhs.height) < 1
    }

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

/// Decoder callbacks run off-main; keep high-water reporting synchronized without hopping actors per frame.
private final class RingBufferPeakRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private weak var sink: MetricsSink?
    private var peak = 0

    init(sink: MetricsSink?) {
        self.sink = sink
    }

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
