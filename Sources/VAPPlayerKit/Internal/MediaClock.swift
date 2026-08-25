import Foundation
import QuartzCore

/// session 私有的单调媒体时钟。pause 冻结媒体时间，resume 重算 host offset。
///
/// 不用屏幕刷新率当视频 FPS，也不用平均 FPS 覆盖 sample duration。
final class MediaClock {
    /// `true` 时 `currentMediaTime()` 返回冻结值。
    private var paused = true
    /// 已播放的媒体时间（秒）。
    private var mediaTime: TimeInterval = 0
    /// `resume` 时记录的 `CACurrentMediaTime() - mediaTime`。
    private var hostTimeOffset: TimeInterval = 0

    /// 记录当前媒体时间并停止推进。
    func pause() {
        mediaTime = currentMediaTime()
        paused = true
    }

    /// 以「现在的 host time - 已播放媒体时间」恢复。
    func resume() {
        hostTimeOffset = CACurrentMediaTime() - mediaTime
        paused = false
    }

    /// 循环边界或新 session 时归零。
    func reset() {
        paused = true
        mediaTime = 0
        hostTimeOffset = 0
    }

    /// 当前应展示的媒体时间（秒）。paused 时返回冻结值。
    func currentMediaTime() -> TimeInterval {
        if paused {
            return mediaTime
        }
        return CACurrentMediaTime() - hostTimeOffset
    }
}
