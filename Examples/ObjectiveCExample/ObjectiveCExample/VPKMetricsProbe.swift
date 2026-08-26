import Foundation
import UIKit
import VAPPlayerKit

/// Objective-C benchmark adapter for the package-level metrics sink.
///
/// The adapter deliberately records the elapsed time at the moment the event
/// reaches the sink. That gives the benchmark one comparable API-call-to-event
/// clock for both implementations; the implementation-specific duration fields
/// remain available for diagnosis but are not used as the headline comparison.
@objc(VPKMetricsProbe)
public final class VPKMetricsProbe: NSObject, MetricsSink {
    private let lock = NSLock()
    private var operationStart: TimeInterval?
    private var operationToFirstFrame: TimeInterval?
    private var operationToPrepare: TimeInterval?
    private var prepare: TimeInterval?
    private var firstFrame: TimeInterval?
    private var decoded = 0
    private var rendered = 0
    private var dropped = 0
    private var drawableFailures = 0
    private var decoderRebuilds = 0
    private var dynamicTimeouts = 0
    private var sessionFinished = 0
    private var prepareStages: [String: Double] = [:]

    @MainActor
    @objc public func attach(to playerView: PlayerView) {
        playerView.metricsSink = self
    }

    @objc public func reset() {
        lock.lock()
        operationStart = nil
        operationToFirstFrame = nil
        operationToPrepare = nil
        prepare = nil
        firstFrame = nil
        decoded = 0
        rendered = 0
        dropped = 0
        drawableFailures = 0
        decoderRebuilds = 0
        dynamicTimeouts = 0
        sessionFinished = 0
        prepareStages = [:]
        lock.unlock()
    }

    @objc public func beginOperation() {
        lock.lock()
        operationStart = ProcessInfo.processInfo.systemUptime
        operationToFirstFrame = nil
        lock.unlock()
    }

    @objc public var prepareMilliseconds: Double { milliseconds(prepare) }
    @objc public var operationToPrepareMilliseconds: Double { milliseconds(operationToPrepare) }
    @objc public var firstFrameMilliseconds: Double { milliseconds(firstFrame) }
    @objc public var operationToFirstFrameMilliseconds: Double { milliseconds(operationToFirstFrame) }
    @objc public var decodedFrameCount: Int { value { decoded } }
    @objc public var renderedFrameCount: Int { value { rendered } }
    @objc public var droppedFrameCount: Int { value { dropped } }
    @objc public var drawableFailureCount: Int { value { drawableFailures } }
    @objc public var decoderRebuildCount: Int { value { decoderRebuilds } }
    @objc public var dynamicTimeoutCount: Int { value { dynamicTimeouts } }
    @objc public var sessionFinishedCount: Int { value { sessionFinished } }
    @objc public var prepareStageMilliseconds: [String: Double] {
        lock.lock()
        let result = prepareStages
        lock.unlock()
        return result
    }

    public func record(_ event: MetricsEvent) {
        lock.lock()
        defer { lock.unlock() }
        switch event {
        case .prepareDuration(let duration):
            prepare = duration
            if let operationStart {
                operationToPrepare = ProcessInfo.processInfo.systemUptime - operationStart
            }
        case .prepareStageDuration(let name, let duration):
            prepareStages[name] = duration * 1000
        case .firstFrameDuration(let duration):
            firstFrame = duration
            if let operationStart {
                operationToFirstFrame = ProcessInfo.processInfo.systemUptime - operationStart
            }
        case .decodedFrame:
            decoded += 1
        case .renderedFrame:
            rendered += 1
        case .droppedFrame:
            dropped += 1
        case .decoderRebuild:
            decoderRebuilds += 1
        case .dynamicTimeout:
            dynamicTimeouts += 1
        case .metalDrawableFailure:
            drawableFailures += 1
        case .ringBufferPeak(_), .dynamicResolveDuration(_):
            break
        case .sessionFinished:
            sessionFinished += 1
        }
    }

    private func milliseconds(_ value: TimeInterval?) -> Double {
        lock.lock()
        let result = (value ?? 0) * 1000
        lock.unlock()
        return result
    }

    private func value<T>(_ read: () -> T) -> T {
        lock.lock()
        let result = read()
        lock.unlock()
        return result
    }
}

/// Supplies deterministic local image/text replacements for the multi-asset
/// benchmark. This keeps 1.mp4 on the same dynamic-content path as the old
/// demo without introducing network or image-decoder variance.
@objc(VPKBenchmarkDynamicProvider)
public final class VPKBenchmarkDynamicProvider: NSObject, ObjCDynamicContentProvider {
    private lazy var image: UIImage = {
        if let bundled = UIImage(named: "qq.png", in: Bundle.main, compatibleWith: nil) {
            return bundled
        }
        return UIGraphicsImageRenderer(size: CGSize(width: 256, height: 256)).image { renderer in
            let bounds = CGRect(x: 0, y: 0, width: 256, height: 256)
            UIColor(red: 0.15, green: 0.42, blue: 0.95, alpha: 1).setFill()
            renderer.fill(bounds)
            UIColor.white.setFill()
            renderer.cgContext.fillEllipse(in: CGRect(x: 48, y: 48, width: 160, height: 160))
            UIColor(red: 0.98, green: 0.34, blue: 0.20, alpha: 1).setFill()
            renderer.cgContext.fillEllipse(in: CGRect(x: 104, y: 104, width: 104, height: 104))
        }
    }()

    @objc public func resolveTag(
        _ tag: String,
        source: SourceMetadata,
        completion: @escaping (UIImage?, String?, NSError?) -> Void
    ) {
        switch source.kind {
        case .image:
            completion(image, nil, nil)
        case .text:
            let replacement: String
            switch tag {
            case "[textAnchor]": replacement = "我是主播名"
            case "[textUser]": replacement = "我是用户名😂😂"
            default: replacement = "BenchmarkUser"
            }
            completion(nil, replacement, nil)
        @unknown default:
            completion(nil, nil, nil)
        }
    }
}
