import Foundation
import UIKit
import VAPPlayerKit

final class PlaybackDiagnostics: MetricsSink {
    struct Snapshot: Sendable {
        let summary: String
        let log: String
    }

    private let lock = NSLock()
    private let startedAt = ProcessInfo.processInfo.systemUptime
    private var entries: [String] = []
    private var decodedFrames = 0
    private var renderedFrames = 0
    private var droppedFrames = 0
    private var drawableFailures = 0
    private var peakBuffer = 0
    private var eventSerial = 0

    var onUpdate: ((Snapshot) -> Void)?

    var renderedFrameCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return renderedFrames
    }

    func record(_ event: MetricsEvent) {
        var importantMessage: String?
        lock.lock()
        switch event {
        case .prepareDuration(let value):
            importantMessage = String(format: "prepare %.3fs", value)
        case .prepareStageDuration(_, _):
            break
        case .firstFrameDuration(let value):
            importantMessage = String(format: "first frame %.3fs", value)
        case .decodedFrame:
            decodedFrames += 1
        case .renderedFrame:
            renderedFrames += 1
        case .droppedFrame:
            droppedFrames += 1
        case .decoderRebuild:
            importantMessage = "decoder rebuilt"
        case .dynamicResolveDuration(let value):
            importantMessage = String(format: "dynamic %.3fs", value)
        case .dynamicTimeout:
            importantMessage = "dynamic timeout"
        case .metalDrawableFailure:
            drawableFailures += 1
        case .ringBufferPeak(let count):
            peakBuffer = max(peakBuffer, count)
        case .sessionFinished(let reason):
            importantMessage = "session finished: \(String(describing: reason))"
        }
        eventSerial += 1
        if let importantMessage { appendLocked("METRIC", importantMessage) }
        let shouldPublish = importantMessage != nil || eventSerial.isMultiple(of: 12)
        let snapshot = shouldPublish ? makeSnapshotLocked() : nil
        lock.unlock()
        if let snapshot { publish(snapshot) }
    }

    func append(_ category: String, _ message: String) {
        lock.lock()
        appendLocked(category, message)
        let snapshot = makeSnapshotLocked()
        lock.unlock()
        publish(snapshot)
    }

    func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return makeSnapshotLocked()
    }

    func persist(fixture: VAPFixture) -> URL? {
        let report = reportText(fixture: fixture)
        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        let url = directory?.appendingPathComponent("VAPPlayerKit-\(fixture.identifier.prefix(10))-report.txt")
        guard let url else { return nil }
        do {
            try report.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            append("REPORT", "write failed: \(error.localizedDescription)")
            return nil
        }
    }

    func reportText(fixture: VAPFixture) -> String {
        let current = snapshot()
        let device = UIDevice.current
        return """
        VAPPlayerKit Device Test Report
        ===============================
        Date: \(ISO8601DateFormatter().string(from: Date()))
        Device: \(device.name) / \(device.model)
        System: \(device.systemName) \(device.systemVersion)
        Fixture: \(fixture.fileName)
        Size: \(fixture.formattedSize)

        \(current.summary)

        Timeline
        --------
        \(current.log)
        """
    }

    private func appendLocked(_ category: String, _ message: String) {
        let elapsed = ProcessInfo.processInfo.systemUptime - startedAt
        entries.append(String(format: "[%7.3f] %-7@ %@", elapsed, category as NSString, message))
        if entries.count > 300 { entries.removeFirst(entries.count - 300) }
    }

    private func makeSnapshotLocked() -> Snapshot {
        Snapshot(
            summary: "Decoded \(decodedFrames)  Rendered \(renderedFrames)  Dropped \(droppedFrames)\nDrawable miss \(drawableFailures)  Buffer peak \(peakBuffer)",
            log: entries.suffix(120).joined(separator: "\n")
        )
    }

    private func publish(_ snapshot: Snapshot) {
        Task { @MainActor [weak self] in self?.onUpdate?(snapshot) }
    }
}
