import Foundation
import AVFoundation
import CoreVideo

/// `AVAssetReaderTrackOutput` 解码后端。AVFoundation 负责 MP4 sample table 和硬解选择，
/// session 仍自行管理 PTS、背压、循环和渲染。
final class AVAssetReaderFrameSource: FrameSource {
    private let url: URL
    private let queue = DispatchQueue(label: "com.vapplayerkit.frame-source", qos: .userInitiated)
    private let state = NSCondition()
    private var asset: AVURLAsset?
    private var videoTrack: AVAssetTrack?
    private var reader: AVAssetReader?
    private var currentBuffer: FrameRingBuffer?
    private var paused = false
    private var cancelled = false

    init(url: URL) {
        self.url = url
    }

    func prepare() async throws -> FrameSourceMetadata {
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
        state.withLock {
            self.asset = asset
            self.videoTrack = track
        }
        return FrameSourceMetadata(encodedVideoSize: size, codec: codec)
    }

    func startProducing(
        to buffer: FrameRingBuffer,
        token: SessionToken,
        didProduce: @escaping (Int) -> Void,
        completion: @escaping (Result<Void, PlaybackError>) -> Void
    ) {
        state.withLock {
            cancelled = false
            paused = false
            currentBuffer = buffer
        }
        queue.async { [weak self] in
            guard let self else { return }
            do {
                let (reader, output) = try self.makeReader()
                self.state.withLock { self.reader = reader }
                guard reader.startReading() else {
                    throw PlaybackError.decoderCreationFailed(osStatus: -1)
                }
                var index = 0
                while true {
                    guard self.waitUntilRunnable() else { return }
                    guard let sample = output.copyNextSampleBuffer() else { break }
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
                        index: index
                    )
                    guard buffer.enqueueWaiting(frame) else {
                        if !buffer.isCancelled {
                            completion(.failure(.decoderFailed(osStatus: -1)))
                        }
                        return
                    }
                    index += 1
                    didProduce(buffer.count)
                }
                let status = reader.status
                self.state.withLock {
                    self.reader = nil
                    self.currentBuffer = nil
                }
                switch status {
                case .completed:
                    completion(.success(()))
                case .cancelled:
                    break
                default:
                    completion(.failure(.decoderFailed(osStatus: -1)))
                }
            } catch let error as PlaybackError {
                completion(.failure(error))
            } catch {
                completion(.failure(.decoderCreationFailed(osStatus: -1)))
            }
        }
    }

    func pause() {
        state.withLock { paused = true }
    }

    func resume() {
        state.withLock {
            paused = false
            state.broadcast()
        }
    }

    func cancel() {
        let buffer = state.withLock { () -> FrameRingBuffer? in
            cancelled = true
            paused = false
            let buffer = currentBuffer
            currentBuffer = nil
            state.broadcast()
            return buffer
        }
        buffer?.cancelWaiting()

        // AVAssetReaderOutput.copyNextSampleBuffer() is running on `queue`.
        // Calling cancelReading() concurrently can tear down AVFoundation's
        // remote reader while that call is still using it (a reproducible
        // EXC_BAD_ACCESS on physical devices). Serialize cancellation and
        // release with the producer instead.
        queue.async { [self] in
            state.withLock {
                reader?.cancelReading()
                reader = nil
            }
        }
    }

    private func makeReader() throws -> (AVAssetReader, AVAssetReaderTrackOutput) {
        guard let asset = state.withLock({ self.asset }), let track = state.withLock({ self.videoTrack }) else {
            throw PlaybackError.decoderCreationFailed(osStatus: -1)
        }
        let reader = try AVAssetReader(asset: asset)
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

    private func waitUntilRunnable() -> Bool {
        state.lock()
        defer { state.unlock() }
        while paused, !cancelled {
            state.wait()
        }
        return !cancelled
    }
}
