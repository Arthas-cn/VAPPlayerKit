import Foundation
import CoreVideo
import CoreMedia

/// 带所有权和时间戳的解码帧。pixel buffer 的 retain 由本结构在跨队列传递时保持明确。
///
/// 对照 `vap-master` 的 `QGMP4AnimatedImageFrame`，但不暴露给宿主，也不允许在回调里改内部状态。
struct DecodedFrame: Sendable {
    /// 产出该帧的 session。不匹配则不得入队或上屏。
    let token: SessionToken
    /// VideoToolbox / AV 输出的 CVPixelBuffer。
    private let pixelStorage: FramePixelStorage
    /// 对只读帧缓冲的同步引用；生产者交付后不会再次写入这块内存。
    var pixelBuffer: CVPixelBuffer { pixelStorage.read() }
    /// 真实 PTS，驱动 MediaClock 消费。
    let presentationTime: CMTime
    /// 该 sample 的展示时长，禁止用平均 FPS 覆盖。
    let duration: CMTime
    /// presentation order 中的零基帧序号，用于查询 vapc frame attachment。
    let index: Int
}

/// CoreVideo 尚未声明 Sendable 的帧缓冲引用；所有访问受锁保护，持有期间禁止写像素。
/// 解码输出交付后只供 renderer 读取，最后 GPU 完成才释放，避免像素池提前复用。
private final class FramePixelStorage: @unchecked Sendable {
    /// 已完成解码的像素缓冲引用，不调用任何写锁或修改像素的 API。
    private let buffer: CVPixelBuffer
    /// 同步跨 decoder/render queue 的引用读取。
    private let lock = NSLock()

    /// 接管已经解码完毕的缓冲；调用方之后只能只读使用。
    init(_ buffer: CVPixelBuffer) { self.buffer = buffer }

    /// 返回仍由本 storage 持有的只读系统缓冲，不能向其中写像素。
    func read() -> CVPixelBuffer { lock.withLock { buffer } }
}

/// 为媒体帧建立只读像素所有权与时间戳，不暴露解码可变状态。
extension DecodedFrame {
    /// 创建具有明确只读所有权的媒体帧；保留像素直至所有消费者释放此值。
    init(token: SessionToken, pixelBuffer: CVPixelBuffer, presentationTime: CMTime, duration: CMTime, index: Int) {
        self.token = token
        self.pixelStorage = FramePixelStorage(pixelBuffer)
        self.presentationTime = presentationTime
        self.duration = duration
        self.index = index
    }
}
