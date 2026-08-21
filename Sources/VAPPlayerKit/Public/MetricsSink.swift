import Foundation

/// 可选的性能与稳定性埋点事件。默认不向日志输出业务 URL 或图片数据。
public enum MetricsEvent: Sendable {
    /// prepare 从开始到 metadata ready 的耗时。
    case prepareDuration(TimeInterval)
    /// 从 play 到第一帧上屏的耗时。
    case firstFrameDuration(TimeInterval)
    /// 成功产出一帧 decoded frame。
    case decodedFrame
    /// 成功提交一次 GPU 渲染。
    case renderedFrame
    /// 因落后于媒体时钟而丢弃一帧。
    case droppedFrame
    /// VT session 重建一次。超过上限应 fail，而不是继续重建。
    case decoderRebuild
    /// 单个动态 tag 的解析耗时。
    case dynamicResolveDuration(TimeInterval)
    /// 动态内容超时一次。
    case dynamicTimeout
    /// Metal drawable 获取失败。
    case metalDrawableFailure
    /// ring buffer 峰值占用。
    case ringBufferPeak(Int)
    /// session 终态。
    case sessionFinished(FinishReason)
}

/// 宿主可注入的指标接收器。组件内部不强依赖具体 APM。
public protocol MetricsSink: AnyObject {
    /// 记录一个事件。调用线程不保证是主线程。
    func record(_ event: MetricsEvent)
}
