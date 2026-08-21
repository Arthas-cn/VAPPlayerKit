import Foundation

/// 页面退到后台、离开 window 或 Metal drawable 暂不可用时的策略。
///
/// 这些情况不能当成播放完成。对照 `vap-master` 的 `HWDMP4EBOperationType`，但不再提供 DoNothing 这种易误用选项。
@objc(VPKBackgroundPolicy)
public enum BackgroundPolicy: Int, Sendable {
    /// 进入 suspended，保留进度；回到前台后由宿主决定是否 resume。
    case suspend
    /// 直接停止当前 session，并给出 `FinishReason.stopped`。
    case stop
}
