import Foundation
import CoreMedia

/// 固定容量的解码帧缓冲。满时拒绝入队，形成对 FrameSource 的背压。
///
/// 对照 `vap-master` 的 `QGAnimatedImageBufferManager`，但主路径不用「可变数组再 sort」。
final class FrameRingBuffer {
    /// 槽位数。默认 6，不得为 0。
    private let capacity: Int
    /// 环形数组。出队后立刻置 nil，避免 pixel buffer 滞留。
    private var storage: [DecodedFrame?]
    private var head = 0
    private var tail = 0
    private var storedCount = 0
    /// 保护存储，并在满/空时让 decoder 等待。
    private let condition = NSCondition()
    private var cancelled = false

    /// 默认 6 帧。高端设备可到 8，但必须受内存上限约束。
    init(capacity: Int = 6) {
        self.capacity = max(1, capacity)
        self.storage = Array(repeating: nil, count: max(1, capacity))
    }

    /// 当前缓冲帧数。
    var count: Int { condition.withLock { storedCount } }

    /// 达到容量后 producer 应停止提交 sample。
    var isFull: Bool { condition.withLock { storedCount >= capacity } }

    /// stop 后 `enqueueWaiting` 会立即返回 false。
    var isCancelled: Bool { condition.withLock { cancelled } }

    /// 按 PTS 单调入队。满则返回 false。
    @discardableResult
    func enqueue(_ frame: DecodedFrame) -> Bool {
        condition.withLock {
            guard !cancelled, storedCount < capacity else { return false }
            return insert(frame)
        }
    }

    /// decoder queue 专用。满时等待 consumer 腾出槽位；stop 会唤醒并返回 false。
    @discardableResult
    func enqueueWaiting(_ frame: DecodedFrame) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        while storedCount >= capacity, !cancelled {
            condition.wait()
        }
        guard !cancelled else { return false }
        return insert(frame)
    }

    /// 取出最旧一帧。空则返回 nil，调用方不得阻塞主线程等待。
    func dequeue() -> DecodedFrame? {
        condition.withLock { removeFirst() }
    }

    /// 消费所有 PTS 不晚于 media time 的帧，只返回最后一帧，并报告被覆盖的过期帧数。
    func dequeueDue(at mediaTime: CMTime) -> (frame: DecodedFrame?, dropped: Int) {
        condition.withLock {
            var selected: DecodedFrame?
            var consumed = 0
            while let first = firstFrame(), CMTimeCompare(first.presentationTime, mediaTime) <= 0 {
                selected = removeFirst()
                consumed += 1
            }
            return (selected, max(0, consumed - 1))
        }
    }

    /// stop 时清空。保留容量避免反复分配。
    func removeAll() {
        condition.withLock {
            storage = Array(repeating: nil, count: capacity)
            head = 0
            tail = 0
            storedCount = 0
            condition.broadcast()
        }
    }

    /// 新循环开始前清空并允许再次入队。
    func reset() {
        condition.withLock {
            cancelled = false
            storage = Array(repeating: nil, count: capacity)
            head = 0
            tail = 0
            storedCount = 0
            condition.broadcast()
        }
    }

    /// 唤醒因满缓冲而阻塞的 decoder，并拒绝后续入队。
    func cancelWaiting() {
        condition.withLock {
            cancelled = true
            condition.broadcast()
        }
    }

    /// 要求 PTS 单调递增。乱序帧拒绝入队，避免消费端再排序。
    private func insert(_ frame: DecodedFrame) -> Bool {
        if let previous = lastFrame() {
            guard CMTimeCompare(previous.presentationTime, frame.presentationTime) <= 0 else { return false }
        }
        storage[tail] = frame
        tail = (tail + 1) % capacity
        storedCount += 1
        return true
    }

    /// 取出最旧一帧，并 signal 可能正在等待的 producer。
    private func removeFirst() -> DecodedFrame? {
        guard storedCount > 0 else { return nil }
        let frame = storage[head]
        storage[head] = nil
        head = (head + 1) % capacity
        storedCount -= 1
        condition.signal()
        return frame
    }

    /// 队头，即最早入队的一帧。
    private func firstFrame() -> DecodedFrame? {
        storedCount > 0 ? storage[head] : nil
    }

    /// 队尾，用于校验新帧 PTS 单调。
    private func lastFrame() -> DecodedFrame? {
        guard storedCount > 0 else { return nil }
        return storage[(tail - 1 + capacity) % capacity]
    }
}

extension NSCondition {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
