import Foundation

/// Phase 0 对照后端：`AVAssetReaderTrackOutput`。实现更简单，但要自管时钟和循环。
final class AVAssetReaderFrameSource: FrameSource {
    func prepare() async throws -> FrameSourceMetadata {
        throw PlaybackError.unsupportedCodec("AVAssetReaderTrackOutput backend is a Phase 0 comparison path.")
    }

    func startProducing(to buffer: FrameRingBuffer, token: SessionToken) {}

    func pause() {}

    func cancel() {}
}
