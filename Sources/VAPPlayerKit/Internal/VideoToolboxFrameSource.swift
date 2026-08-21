import Foundation

/// 默认生产后端：VideoToolbox 硬解 + 受限 MP4 sample reader。
///
/// 对照 `vap-master` 的 `QGMP4FrameHWDecoder`。Phase 0 尚未接线，调用 prepare 会明确失败。
final class VideoToolboxFrameSource: FrameSource {
    func prepare() async throws -> FrameSourceMetadata {
        throw PlaybackError.unsupportedCodec("VideoToolbox backend is not wired in Phase 0.")
    }

    func startProducing(to buffer: FrameRingBuffer, token: SessionToken) {}

    func pause() {}

    func cancel() {}
}
