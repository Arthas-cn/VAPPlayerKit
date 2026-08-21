import Foundation

final class AVPlayerOutputFrameSource: FrameSource {
    func prepare() async throws -> FrameSourceMetadata {
        throw PlaybackError.unsupportedCodec("AVPlayerItemVideoOutput backend is a Phase 0 comparison path.")
    }

    func startProducing(to buffer: FrameRingBuffer, token: SessionToken) {}

    func pause() {}

    func cancel() {}
}
