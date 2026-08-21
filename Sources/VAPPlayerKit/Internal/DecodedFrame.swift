import CoreVideo
import CoreMedia

/// 带所有权和时间戳的解码帧。pixel buffer 的 retain 由本结构在跨队列传递时保持明确。
///
/// 对照 `vap-master` 的 `QGMP4AnimatedImageFrame`，但不暴露给宿主，也不允许在回调里改内部状态。
struct DecodedFrame {
    /// 产出该帧的 session。不匹配则不得入队或上屏。
    let token: SessionToken
    /// VideoToolbox / AV 输出的 CVPixelBuffer。
    let pixelBuffer: CVPixelBuffer
    /// 真实 PTS，驱动 MediaClock 消费。
    let presentationTime: CMTime
    /// 该 sample 的展示时长，禁止用平均 FPS 覆盖。
    let duration: CMTime
    /// presentation order 中的零基帧序号，用于查询 vapc frame attachment。
    let index: Int
}
