/// 解析后 Alpha 区域相对颜色区域的方向；不是透明布局的输入配置。
public enum AlphaMode: Sendable, Hashable {
    /// Alpha 区域在颜色区域左侧，双方沿 X 轴不相交。
    case left
    /// Alpha 区域在颜色区域右侧，双方沿 X 轴不相交。
    case right
    /// Alpha 区域在颜色区域上侧，双方沿 Y 轴不相交。
    case top
    /// Alpha 区域在颜色区域下侧，双方沿 Y 轴不相交。
    case bottom
    /// 普通视频使用完整不透明画面，没有拼接 Alpha 区域。
    case none
}
