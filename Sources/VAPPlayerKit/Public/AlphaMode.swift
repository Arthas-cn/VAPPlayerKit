import Foundation

/// packed VAP 帧中 Alpha 通道相对 RGB 区域的空间布局。
///
/// 对照 `vap-master` 中 vapc 的 alpha 方向字段。不能用编码分辨率直接当画布尺寸。
@objc(VPKAlphaMode)
public enum AlphaMode: Int, Sendable {
    /// Alpha 在画面左侧，RGB 在右侧。
    case left
    /// Alpha 在画面右侧，RGB 在左侧。
    case right
    /// Alpha 在画面上方，RGB 在下方。
    case top
    /// Alpha 在画面下方，RGB 在上方。
    case bottom
}
