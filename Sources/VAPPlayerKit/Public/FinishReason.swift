import Foundation

/// 一次播放 session 的终态原因。每个 session 最多报告一次终态。
@objc(VPKFinishReason)
public enum FinishReason: Int, Sendable {
    /// 按 `loopCount` 播完，正常结束。
    case completed
    /// 宿主调用了 `stop()` 或后台策略要求停止。
    case stopped
    /// 被更新的 session token 取消，例如快速切换资源。
    case cancelled
}
