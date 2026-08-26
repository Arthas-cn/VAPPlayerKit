import Foundation
import AVFoundation
import CoreVideo

/// `AVAssetReaderTrackOutput` 解码后端。AVFoundation 负责 MP4 sample table 和硬解选择，
/// session 仍自行管理 PTS、背压、循环和渲染。
final class AVAssetReaderFrameSource: FrameSource {
    private let url: URL
    /// 解码生产线程。与主线程 / render queue 隔离。
    private let queue = DispatchQueue(label: "com.vapplayerkit.frame-source", qos: .userInitiated)
    /// 保护 pause / cancel / reader 生命周期。
    private let state = NSCondition()
    private var asset: AVURLAsset?
    private var videoTrack: AVAssetTrack?
    private var reader: AVAssetReader?
    /// 标识当前 producer。取消并重启时，旧 producer 即使晚回调也不能碰新一轮状态。
    private var producerID: UInt64 = 0
    private var readerProducerID: UInt64?
    /// 当前正在写入的 ring buffer；cancel 时用来唤醒等待中的 enqueue。
    private var currentBuffer: FrameRingBuffer?
    private var paused = false
    private var cancelled = false

    init(url: URL) {
        self.url = url
    }

    /// 加载视频轨并记录编码尺寸 / codec，此时还不创建 AVAssetReader。
    func prepare() async throws -> FrameSourceMetadata {
        try await prepare(using: nil)
    }

    /// 优先复用 inspector 已加载的 AVAsset / video track，避免 warm prepare 重复查询 AVFoundation 元数据。
    func prepare(using context: FrameSourceContext?) async throws -> FrameSourceMetadata {
        if let context {
            state.withLock {
                self.asset = context.asset
                self.videoTrack = context.videoTrack
            }
            return context.metadata
        }

        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let tracks: [AVAssetTrack]
        do {
            tracks = try await asset.loadTracks(withMediaType: .video)
        } catch {
            throw PlaybackError.invalidMP4(reason: "Unable to load the video track for decoding.")
        }
        guard let track = tracks.first else {
            throw PlaybackError.invalidMP4(reason: "Missing video track.")
        }
        let descriptions = try await track.load(.formatDescriptions)
        guard let description = descriptions.first else {
            throw PlaybackError.invalidMP4(reason: "Missing decoder format description.")
        }
        let subtype = CMFormatDescriptionGetMediaSubType(description)
        let codec: String
        switch subtype {
        case kCMVideoCodecType_H264: codec = "h264"
        case kCMVideoCodecType_HEVC: codec = "hevc"
        default: throw PlaybackError.unsupportedCodec(String(subtype))
        }
        let dimensions = CMVideoFormatDescriptionGetDimensions(description)
        let size = CGSize(width: Int(dimensions.width), height: Int(dimensions.height))
        guard size.width > 0, size.height > 0 else {
            throw PlaybackError.invalidMP4(reason: "Video track has invalid encoded dimensions.")
        }
        let metadata = FrameSourceMetadata(encodedVideoSize: size, codec: codec)
        state.withLock {
            self.asset = asset
            self.videoTrack = track
        }
        return metadata
    }

    /// 在 decoder queue 上循环 copyNextSampleBuffer，满缓冲时阻塞等待。
    func startProducing(
        to buffer: FrameRingBuffer,
        token: SessionToken,
        startTime: CMTime,
        frameIndexOffset: Int,
        didProduce: @escaping (Int) -> Void,
        completion: @escaping (Result<Void, PlaybackError>) -> Void
    ) {
        let currentProducerID = state.withLock { () -> UInt64 in
            producerID &+= 1
            cancelled = false
            paused = false
            currentBuffer = buffer
            return producerID
        }
        queue.async { [weak self] in
            guard let self else { return }
            do {
                guard self.isCurrentProducer(currentProducerID) else {
                    completion(.failure(.cancelled))
                    return
                }
                let (reader, output) = try self.makeReader(startTime: startTime)
                self.state.withLock {
                    guard self.producerID == currentProducerID else { return }
                    self.reader = reader
                    self.readerProducerID = currentProducerID
                }
                guard reader.startReading() else {
                    throw PlaybackError.decoderCreationFailed(osStatus: self.errorCode(reader.error))
                }
                var index = 0
                while true {
                    guard self.waitUntilRunnable(for: currentProducerID) else {
                        completion(.failure(.cancelled))
                        return
                    }
                    guard let sample = output.copyNextSampleBuffer() else { break }
                    guard self.isCurrentProducer(currentProducerID) else {
                        completion(.failure(.cancelled))
                        return
                    }
                    guard CMSampleBufferIsValid(sample), let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else {
                        throw PlaybackError.decoderFailed(osStatus: -1)
                    }
                    let presentationTime = CMSampleBufferGetPresentationTimeStamp(sample)
                    guard presentationTime.isValid, presentationTime.isNumeric, presentationTime.seconds.isFinite else {
                        throw PlaybackError.decoderFailed(osStatus: -1)
                    }
                    var duration = CMSampleBufferGetDuration(sample)
                    if !duration.isValid || !duration.isNumeric || !duration.seconds.isFinite || duration.seconds <= 0 {
                        duration = CMTime(value: 1, timescale: 30)
                    }
                    let frame = DecodedFrame(
                        token: token,
                        pixelBuffer: pixelBuffer,
                        presentationTime: presentationTime,
                        duration: duration,
                        index: frameIndexOffset + index
                    )
                    guard buffer.enqueueWaiting(frame) else {
                        if !buffer.isCancelled, self.isCurrentProducer(currentProducerID) {
                            completion(.failure(.decoderFailed(osStatus: -1)))
                        } else {
                            completion(.failure(.cancelled))
                        }
                        return
                    }
                    index += 1
                    didProduce(buffer.count)
                }
                let status = reader.status
                self.state.withLock {
                    if self.readerProducerID == currentProducerID {
                        self.reader = nil
                        self.readerProducerID = nil
                    }
                    if self.producerID == currentProducerID {
                        self.currentBuffer = nil
                    }
                }
                guard self.isCurrentProducer(currentProducerID) else {
                    completion(.failure(.cancelled))
                    return
                }
                switch status {
                case .completed:
                    completion(.success(()))
                case .cancelled:
                    completion(.failure(.cancelled))
                default:
                    completion(.failure(.decoderFailed(osStatus: self.errorCode(reader.error))))
                }
            } catch let error as PlaybackError {
                if self.isCurrentProducer(currentProducerID) {
                    completion(.failure(error))
                } else {
                    completion(.failure(.cancelled))
                }
            } catch {
                if self.isCurrentProducer(currentProducerID) {
                    completion(.failure(.decoderCreationFailed(osStatus: -1)))
                } else {
                    completion(.failure(.cancelled))
                }
            }
        }
    }

    /// 暂停 sample 提交，不销毁 reader。
    func pause() {
        state.withLock { paused = true }
    }

    /// 唤醒 decoder queue 继续生产。
    func resume() {
        state.withLock {
            paused = false
            state.broadcast()
        }
    }

    /// 取消生产。必须在 decoder queue 上调用 `cancelReading`，避免与 copyNext 并发导致崩溃。
    func cancel() {
        let cancelledProducer = state.withLock { () -> (UInt64, FrameRingBuffer?) in
            let cancelledProducerID = producerID
            producerID &+= 1
            cancelled = true
            paused = false
            let buffer = currentBuffer
            currentBuffer = nil
            state.broadcast()
            return (cancelledProducerID, buffer)
        }
        cancelledProducer.1?.cancelWaiting()

        // copyNextSampleBuffer 正在 decoder queue 上执行。
        // 并发调用 cancelReading 会拆掉 AVFoundation 远端 reader，真机上可复现 EXC_BAD_ACCESS。
        // 因此取消和释放必须与 producer 串行。
        queue.async { [self] in
            state.withLock {
                guard readerProducerID == cancelledProducer.0 else { return }
                reader?.cancelReading()
                reader = nil
                readerProducerID = nil
            }
        }
    }

    /// 创建 NV12、Metal 兼容的 track output。`alwaysCopiesSampleData = false` 减少拷贝。
    private func makeReader(startTime: CMTime) throws -> (AVAssetReader, AVAssetReaderTrackOutput) {
        guard let asset = state.withLock({ self.asset }), let track = state.withLock({ self.videoTrack }) else {
            throw PlaybackError.decoderCreationFailed(osStatus: -1)
        }
        let reader = try AVAssetReader(asset: asset)
        let safeStartTime: CMTime
        if startTime.isValid, startTime.isNumeric, startTime.seconds.isFinite, startTime.seconds > 0 {
            safeStartTime = CMTime(seconds: startTime.seconds, preferredTimescale: 600)
        } else {
            safeStartTime = .zero
        }
        reader.timeRange = CMTimeRange(start: safeStartTime, duration: .positiveInfinity)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                kCVPixelBufferMetalCompatibilityKey as String: true
            ]
        )
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw PlaybackError.decoderCreationFailed(osStatus: -1)
        }
        reader.add(output)
        return (reader, output)
    }

    /// pause 时阻塞 decoder queue；cancel 后返回 false 结束生产循环。
    private func waitUntilRunnable(for producerID: UInt64) -> Bool {
        state.lock()
        defer { state.unlock() }
        while paused, !cancelled, self.producerID == producerID {
            state.wait()
        }
        return !cancelled && self.producerID == producerID
    }

    private func isCurrentProducer(_ producerID: UInt64) -> Bool {
        state.withLock { !cancelled && self.producerID == producerID }
    }

    private func errorCode(_ error: Error?) -> Int32 {
        guard let error else { return -1 }
        return Int32(clamping: (error as NSError).code)
    }
}
