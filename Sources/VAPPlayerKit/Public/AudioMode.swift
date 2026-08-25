import Foundation

/// 音频策略。播放器不会在内部偷偷决定是否出声。
///
/// 对照旧 API 的 `setMute:`，但语义更完整：静音、内嵌音轨、交给宿主、完全忽略。
@objc(VPKAudioMode)
public enum AudioMode: Int, Sendable {
    /// 不创建音频资源，画面照常播放。
    case muted
    /// 播放 MP4 内嵌音轨，并与 pause / resume / stop 绑定。
    case embedded
    /// 组件不创建音频资源，由宿主自己的播放器和同步策略负责出声。
    case external
    /// 完全忽略音轨；metadata 仍可报告 `containsAudio`。
    case disabled
}
