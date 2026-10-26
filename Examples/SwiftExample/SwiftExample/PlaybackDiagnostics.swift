import Foundation
import Synchronization
import UIKit
import VAPPlayerKit

/// 跨解码/渲染线程接收指标；所有可变计数、日志与 UI 回调均受同一把锁保护。
nonisolated final class PlaybackDiagnostics: MetricsSink {
    /// 向主线程交付的不可变诊断快照，不暴露内部缓冲数组。
    struct Snapshot: Sendable {
        /// 当前累计帧数、错误数与缓冲峰值。
        let summary: String
        /// 最近最多 120 条诊断文本。
        let log: String
    }

    /// 锁内拥有的全部可变数据，禁止在闭包之外直接读写。
    private struct State: Sendable {
        /// 最多 300 条历史记录，防止长时间播放无限积累。
        var entries: [String] = []
        /// 累计成功解码的帧数。
        var decodedFrames = 0
        /// 累计提交渲染的帧数，不代表肉眼首帧。
        var renderedFrames = 0
        /// 因时间落后而丢弃的帧数。
        var droppedFrames = 0
        /// drawable 获取失败次数。
        var drawableFailures = 0
        /// 观察到的帧缓冲占用峰值。
        var peakBuffer = 0
        /// 普通指标序号，用于合并高频 UI 更新。
        var eventSerial = 0
        /// 可选 UI 接收者；在锁中读取快照，在锁外切到 MainActor 执行。
        var onUpdate: (@MainActor @Sendable (Snapshot) -> Void)?
    }

    /// 唯一的可变状态容器，Mutex 自身提供 Sendable 与同步保护。
    private let state = Mutex(State())
    /// 日志的单调时间起点，不受系统时间调整影响。
    private let startedAt = ProcessInfo.processInfo.systemUptime

    /// 设置或移除 UI 回调；setter/getter 与指标写入使用同一把锁。
    var onUpdate: (@MainActor @Sendable (Snapshot) -> Void)? {
        get { state.withLock { $0.onUpdate } }
        set { state.withLock { $0.onUpdate = newValue } }
    }

    /// 返回线程安全的渲染计数，供真机冒烟等待实际帧证据。
    var renderedFrameCount: Int { state.withLock { $0.renderedFrames } }

    /// 记录后台指标；关键事件立即交付，普通帧每 12 次合并一次 UI 更新。
    func record(_ event: MetricsEvent) {
        let update = state.withLock { value -> (Snapshot, (@MainActor @Sendable (Snapshot) -> Void)?)? in
            var message: String?
            switch event {
            // 准备总耗时用于用户诊断，阶段细节留给专门基准页。
            case .prepareDuration(let duration): message = String(format: "prepare %.3fs", duration)
            // 普通界面不显示每个内部阶段，以免淹没播放控制事件。
            case .prepareStageDuration: break
            // 首帧指标用于区分 metadata 成功与实际 GPU 提交。
            case .firstFrameDuration(let duration): message = String(format: "first frame %.3fs", duration)
            // 帧类指标只累计，在下面统一节流发布。
            case .decodedFrame: value.decodedFrames += 1
            // 成功渲染与解码分开，便于发现仅解析成功的误判。
            case .renderedFrame: value.renderedFrames += 1
            // 丢帧是运行指标，不当作整个会话失败。
            case .droppedFrame: value.droppedFrames += 1
            // 重建可能引入间隙，需要单独记录时间点。
            case .decoderRebuild: message = "decoder rebuilt"
            // 动态内容准备耗时参与开播排查。
            case .dynamicResolveDuration(let duration): message = String(format: "dynamic %.3fs", duration)
            // 超时记录保留，最终失败仍由播放器 delegate 处理。
            case .dynamicTimeout: message = "dynamic timeout"
            // 表面失败与普通丢帧分别统计。
            case .metalDrawableFailure: value.drawableFailures += 1
            // 只保留峰值，不能用最新较小值覆盖。
            case .ringBufferPeak(let count): value.peakBuffer = max(value.peakBuffer, count)
            // 终态应立即可见，不等待下一批帧刷新。
            case .sessionFinished(let reason): message = "session finished: \(reason)"
            }
            value.eventSerial += 1
            // 只有低频关键事件写逐条时间线，帧事件仅更新计数。
            if let message { append("METRIC", message, to: &value) }
            // 高频帧不逐条切到主线程，关键事件则始终发布。
            guard message != nil || value.eventSerial.isMultiple(of: 12) else { return nil }
            return (makeSnapshot(value), value.onUpdate)
        }
        // 未达到发布门槛时保持静默，避免后台帧逐个触发 UI 工作。
        if let (snapshot, callback) = update { publish(snapshot, to: callback) }
    }

    /// 写入操作或错误日志，并发布同一锁中生成的 UI 快照。
    func append(_ category: String, _ message: String) {
        let (snapshot, callback) = state.withLock { value in
            append(category, message, to: &value)
            return (makeSnapshot(value), value.onUpdate)
        }
        publish(snapshot, to: callback)
    }

    /// 在锁内生成不可变摘要，调用方无需持锁遍历日志。
    func snapshot() -> Snapshot { state.withLock { makeSnapshot($0) } }

    /// 将报告写入 Demo 缓存；失败返回 nil，并记录原因而不影响播放。
    @MainActor func persist(fixture: VAPFixture) -> URL? {
        let report = reportText(fixture: fixture)
        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        let url = directory?.appendingPathComponent("VAPPlayerKit-\(fixture.identifier.prefix(10))-report.txt")
        // 系统未提供缓存目录时不尝试写入任意替代路径。
        guard let url else { return nil }
        do {
            try report.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            // 报告是附加诊断，写入失败不能改写播放器终态。
            append("REPORT", "write failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// 在 MainActor 读取 UIDevice，后台指标快照则通过锁安全获取。
    @MainActor func reportText(fixture: VAPFixture) -> String {
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

    /// 仅在 state 锁内调用，将日志数量限制为 300 条。
    private func append(_ category: String, _ message: String, to value: inout State) {
        let elapsed = ProcessInfo.processInfo.systemUptime - startedAt
        value.entries.append(String(format: "[%7.3f] %-7@ %@", elapsed, category as NSString, message))
        // 长时间压力测试也不能让诊断本身成为无限增长的内存来源。
        if value.entries.count > 300 { value.entries.removeFirst(value.entries.count - 300) }
    }

    /// 从已经加锁的值构造 UI 摘要，不再次尝试锁住同一 Mutex。
    private func makeSnapshot(_ value: State) -> Snapshot {
        Snapshot(
            summary: "Decoded \(value.decodedFrames)  Rendered \(value.renderedFrames)  Dropped \(value.droppedFrames)\nDrawable miss \(value.drawableFailures)  Buffer peak \(value.peakBuffer)",
            log: value.entries.suffix(120).joined(separator: "\n")
        )
    }

    /// 只携带纯值及 MainActor 回调切线程，绝不在锁内调用业务 UI 代码。
    private func publish(_ snapshot: Snapshot, to callback: (@MainActor @Sendable (Snapshot) -> Void)?) {
        // 接收者已移除时不创建无效的主线程任务。
        guard let callback else { return }
        Task { @MainActor in callback(snapshot) }
    }
}
