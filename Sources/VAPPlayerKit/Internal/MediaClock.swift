import Foundation
import QuartzCore

final class MediaClock {
    private var paused = true
    private var mediaTime: TimeInterval = 0
    private var hostTimeOffset: TimeInterval = 0

    func pause() {
        mediaTime = currentMediaTime()
        paused = true
    }

    func resume() {
        hostTimeOffset = CACurrentMediaTime() - mediaTime
        paused = false
    }

    func reset() {
        paused = true
        mediaTime = 0
        hostTimeOffset = 0
    }

    func currentMediaTime() -> TimeInterval {
        if paused {
            return mediaTime
        }
        return CACurrentMediaTime() - hostTimeOffset
    }
}
