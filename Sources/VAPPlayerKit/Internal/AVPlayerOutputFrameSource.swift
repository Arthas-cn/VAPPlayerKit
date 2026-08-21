import Foundation

/// Phase 0 对照后端：`AVPlayerItemVideoOutput`。用于验证时钟和音频同步，不是默认生产路径。
final class AVPlayerOutputFrameSource: FrameSource {
    func prepare() async throws -> FrameSourceMetadata {
        throw PlaybackError.unsupportedCodec("AVPlayerItemVideoOutput backend is a Phase 0 comparison path.")
    }

    func startProducing(to buffer: FrameRingBuffer, token: SessionToken) {}

    func pause() {}

    func cancel() {}
}
