import Foundation

/// 按 `AudioMode` 执行音频策略，不反向控制视频状态机。
final class AudioCoordinator {
    /// 与 session pause 对齐，冻结音频时钟。
    func pause() {}

    /// 与 session resume 对齐。
    func resume() {}

    /// stop / fail 时释放音频资源。
    func stop() {}
}
