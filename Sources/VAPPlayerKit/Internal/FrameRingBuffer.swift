import Foundation

final class FrameRingBuffer {
    private let capacity: Int
    private var frames: [DecodedFrame] = []

    init(capacity: Int = 6) {
        self.capacity = max(1, capacity)
    }

    var count: Int { frames.count }

    var isFull: Bool { frames.count >= capacity }

    func enqueue(_ frame: DecodedFrame) -> Bool {
        guard !isFull else { return false }
        frames.append(frame)
        return true
    }

    func dequeue() -> DecodedFrame? {
        guard !frames.isEmpty else { return nil }
        return frames.removeFirst()
    }

    func removeAll() {
        frames.removeAll(keepingCapacity: true)
    }
}
