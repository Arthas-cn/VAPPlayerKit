import Foundation

final class AVAssetReaderFrameSource: FrameSource {
    func prepare() async throws -> FrameSourceMetadata {
        throw PlaybackError.unsupportedCodec("AVAssetReaderTrackOutput backend is a Phase 0 comparison path.")
    }

    func startProducing(to buffer: FrameRingBuffer, token: SessionToken) {}

    func pause() {}

    func cancel() {}
}
