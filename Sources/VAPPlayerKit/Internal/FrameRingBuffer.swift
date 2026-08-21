import Foundation

/// 固定容量的解码帧缓冲。满时拒绝入队，形成对 FrameSource 的背压。
///
/// 对照 `vap-master` 的 `QGAnimatedImageBufferManager`，但主路径不用「可变数组再 sort」。
final class FrameRingBuffer {
    private let capacity: Int
    private var frames: [DecodedFrame] = []

    /// 默认 6 帧。高端设备可到 8，但必须受内存上限约束。
    init(capacity: Int = 6) {
        self.capacity = max(1, capacity)
    }

    /// 当前缓冲帧数。
    var count: Int { frames.count }

    /// 达到容量后 producer 应停止提交 sample。
    var isFull: Bool { frames.count >= capacity }

    /// 按 PTS 单调入队。满则返回 false。
    @discardableResult
    func enqueue(_ frame: DecodedFrame) -> Bool {
        guard !isFull else { return false }
        frames.append(frame)
        return true
    }

    /// 取出最旧一帧。空则返回 nil，调用方不得阻塞主线程等待。
    func dequeue() -> DecodedFrame? {
        guard !frames.isEmpty else { return nil }
        return frames.removeFirst()
    }

    /// stop 时清空。保留容量避免反复分配。
    func removeAll() {
        frames.removeAll(keepingCapacity: true)
    }
}
