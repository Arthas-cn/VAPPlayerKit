import Foundation
import AVFoundation
import CoreGraphics
import CoreMedia

/// 解码后端内部协议。公开 API 不得依赖具体实现。
///
/// 对照 `vap-master` 的 `QGMP4FrameHWDecoder`，但通过协议隔离 VideoToolbox / AVPlayer / AVAssetReader。
protocol FrameSource: AnyObject {
    /// 打开资源、创建解码会话，返回编码尺寸和 codec。
    func prepare() async throws -> FrameSourceMetadata
    /// 复用 inspection 已加载的 AVAsset / video track；不支持复用的测试实现走默认实现。
    func prepare(using context: FrameSourceContext?) async throws -> FrameSourceMetadata
    /// 向 ring buffer 持续产出带 PTS 的帧。buffer 满时必须背压，不能无界堆积。
    func startProducing(
        to buffer: FrameRingBuffer,
        token: SessionToken,
        startTime: CMTime,
        frameIndexOffset: Int,
        didProduce: @escaping (Int) -> Void,
        completion: @escaping (Result<Void, PlaybackError>) -> Void
    )
    /// 暂停 sample 提交，不销毁 VT session。
    func pause()
    /// pause 后恢复 sample 提交。
    func resume()
    /// 取消生产并在 decoder queue 上释放资源。过期 token 的回调必须丢弃。
    func cancel()
}

extension FrameSource {
    func prepare(using context: FrameSourceContext?) async throws -> FrameSourceMetadata {
        try await prepare()
    }
}

/// inspection 阶段已经加载的媒体上下文。它只缓存 AVFoundation 元数据，不缓存 reader、
/// sample buffer 或硬解 session，因此可以安全地在后续播放 session 间复用。
struct FrameSourceContext: @unchecked Sendable {
    let asset: AVURLAsset
    let videoTrack: AVAssetTrack
    let metadata: FrameSourceMetadata
}

/// FrameSource 准备阶段产出的只读信息，最终会与 inspector metadata 交叉校验。
struct FrameSourceMetadata {
    /// packed 视频编码宽高。
    let encodedVideoSize: CGSize
    /// `h264` 或 `hevc`。
    let codec: String
}
