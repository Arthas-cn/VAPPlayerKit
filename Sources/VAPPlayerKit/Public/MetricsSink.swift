import Foundation

public enum MetricsEvent: Sendable {
    case prepareDuration(TimeInterval)
    case firstFrameDuration(TimeInterval)
    case decodedFrame
    case renderedFrame
    case droppedFrame
    case decoderRebuild
    case dynamicResolveDuration(TimeInterval)
    case dynamicTimeout
    case metalDrawableFailure
    case ringBufferPeak(Int)
    case sessionFinished(FinishReason)
}

public protocol MetricsSink: AnyObject {
    func record(_ event: MetricsEvent)
}
