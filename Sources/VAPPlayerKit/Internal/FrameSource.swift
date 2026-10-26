import Foundation
import AVFoundation
import CoreGraphics
import CoreMedia

/// 解码后端内部协议。公开 API 不得依赖具体实现。
///
/// 对照 `vap-master` 的 `QGMP4FrameHWDecoder`，但通过协议隔离 VideoToolbox / AVPlayer / AVAssetReader。
protocol FrameSource: AnyObject, Sendable {
    /// 打开资源、创建解码会话，返回编码尺寸和 codec。
    func prepare() async throws -> FrameSourceMetadata
    /// 接受 inspection 的纯值轨道提示；系统媒体对象始终由后端自己拥有。
    func prepare(using context: FrameSourceContext?) async throws -> FrameSourceMetadata
    /// 向 ring buffer 持续产出带 PTS 的帧。buffer 满时必须背压，不能无界堆积。
    func startProducing(
        to buffer: FrameRingBuffer,
        token: SessionToken,
        startTime: CMTime,
        frameIndexOffset: Int,
        didProduce: @escaping @Sendable (Int) -> Void,
        completion: @escaping @Sendable (Result<Void, PlaybackError>) -> Void
    )
    /// 暂停 sample 提交，不销毁 VT session。
    func pause()
    /// pause 后恢复 sample 提交。
    func resume()
    /// 取消生产并在 decoder queue 上释放资源。过期 token 的回调必须丢弃。
    func cancel()
    /// 等待本后端所有解码/取消工作真实结束，默认测试后端只需同步取消。
    func cancelAndWait() async
}

/// 不需要异步队列的后端可以沿用默认的上下文准备与取消实现。
extension FrameSource {
    /// 简单测试后端同步取消即已排空，生产队列后端必须覆盖。
    func cancelAndWait() async { cancel() }
    /// 默认后端忽略只读提示并重新准备；生产实现仍必须核对真实轨道。
    func prepare(using context: FrameSourceContext?) async throws -> FrameSourceMetadata {
        try await prepare()
    }
}

/// inspection 得到的纯值轨道提示；不把非 Sendable 的 AVAssetTrack 缓存在跨 actor 元数据中。
struct FrameSourceContext: Sendable {
    /// 同一检查过的本地文件；decoder 自己拥有并加载系统媒体对象。
    let url: URL
    /// 检查时的编码尺寸与 codec，实际 decoder 仍会交叉验证。
    let metadata: FrameSourceMetadata
}

/// FrameSource 准备阶段产出的只读信息，最终会与 inspector metadata 交叉校验。
struct FrameSourceMetadata: Sendable {
    /// packed 视频编码宽高。
    let encodedVideoSize: CGSize
    /// `h264` 或 `hevc`。
    let codec: String
}
