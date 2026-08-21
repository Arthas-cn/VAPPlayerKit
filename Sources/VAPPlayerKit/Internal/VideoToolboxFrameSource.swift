import Foundation

final class VideoToolboxFrameSource: FrameSource {
    func prepare() async throws -> FrameSourceMetadata {
        throw PlaybackError.unsupportedCodec("VideoToolbox backend is not wired in Phase 0.")
    }

    func startProducing(to buffer: FrameRingBuffer, token: SessionToken) {}

    func pause() {}

    func cancel() {}
}
