import CoreGraphics

/// 编码帧左上角为原点的整数像素矩形；不应用视频轨的 preferredTransform。
public struct VideoPixelRect: Sendable, Hashable {
    /// 左边界的像素位置，必须非负。
    public let x: Int
    /// 上边界的像素位置，必须非负。
    public let y: Int
    /// 区域宽度，必须大于 0；不要求偶数。
    public let width: Int
    /// 区域高度，必须大于 0；不要求偶数。
    public let height: Int

    /// 保存原始像素值；准备时验证形状与实际视频边界，失败抛 invalidAlphaLayout。
    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    /// 检查正尺寸与整数加法溢出，返回闭区间外侧的右/下边界。
    internal func validatedEdges() throws -> (maxX: Int, maxY: Int) {
        let horizontal = x.addingReportingOverflow(width)
        let vertical = y.addingReportingOverflow(height)
        // 先在整数域拒绝溢出，禁止转成 CGFloat 后丢失精度或得到反向区域。
        guard x >= 0, y >= 0, width > 0, height > 0,
              !horizontal.overflow, !vertical.overflow else {
            throw PlaybackError.invalidAlphaLayout(reason: "Pixel rectangles require nonnegative origins and positive, nonoverflowing dimensions.")
        }
        return (horizontal.partialValue, vertical.partialValue)
    }

    /// 转成 Metal 布局使用的矩形；调用者必须先验证整数形状与视频边界。
    internal var cgRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }
}

/// 显式透明视频的两个独立区域；颜色画布大小只取 colorRect，不要求等分或相同尺寸。
public struct PackedAlphaLayout: Sendable, Hashable {
    /// 两个区域的排列轴；沿声明轴不相交，颜色可在任意一侧。
    public enum Arrangement: Sendable, Hashable {
        /// 左右排列，区域沿 X 轴分离。
        case sideBySide
        /// 上下排列，区域沿 Y 轴分离。
        case topBottom
    }

    /// 几何必须沿此轴分离，不能由文件内容重新推断。
    public let arrangement: Arrangement
    /// 可见颜色区域；其宽高即最终逻辑画布。
    public let colorRect: VideoPixelRect
    /// 亮度透明区域，以局部 UV 重采样到颜色画布。
    public let alphaRect: VideoPixelRect

    /// 保存显式布局；不读文件，准备时验证并以 invalidAlphaLayout 报错。
    public init(arrangement: Arrangement, colorRect: VideoPixelRect, alphaRect: VideoPixelRect) {
        self.arrangement = arrangement
        self.colorRect = colorRect
        self.alphaRect = alphaRect
    }

    /// 验证区域的整数形状和声明轴，不检查尚未取得的视频尺寸。
    internal func validateGeometry() throws {
        _ = try resolvedAlphaMode()
    }

    /// 用实际编码尺寸验证边界并返回 Alpha 方位；不旋转、不对半、不裁切奇数边。
    internal func validatedAlphaMode(in encodedVideoSize: CGSize) throws -> AlphaMode {
        let mode = try resolvedAlphaMode()
        let colorEdges = try colorRect.validatedEdges()
        let alphaEdges = try alphaRect.validatedEdges()
        // 编码尺寸来自媒体轨；两区域必须完整落在同一个未旋转像素空间里。
        guard encodedVideoSize.width.isFinite, encodedVideoSize.height.isFinite,
              encodedVideoSize.width > 0, encodedVideoSize.height > 0,
              encodedVideoSize.width.rounded(.down) == encodedVideoSize.width,
              encodedVideoSize.height.rounded(.down) == encodedVideoSize.height,
              CGFloat(colorEdges.maxX) <= encodedVideoSize.width,
              CGFloat(colorEdges.maxY) <= encodedVideoSize.height,
              CGFloat(alphaEdges.maxX) <= encodedVideoSize.width,
              CGFloat(alphaEdges.maxY) <= encodedVideoSize.height else {
            throw PlaybackError.invalidAlphaLayout(reason: "Packed Alpha rectangles exceed the encoded video bounds.")
        }
        return mode
    }

    /// 按声明轴验证分离并确定方向；对角区域也必须服从调用方选择的轴。
    private func resolvedAlphaMode() throws -> AlphaMode {
        let colorEdges = try colorRect.validatedEdges()
        let alphaEdges = try alphaRect.validatedEdges()
        switch arrangement {
        // 左右模式只比较 X，避免把另一轴恰好分离误当合法左右布局。
        case .sideBySide:
            // 允许 Alpha 在任意一侧，留白与不等尺寸不影响判定。
            if alphaEdges.maxX <= colorRect.x { return .left }
            // 左侧条件不成立时独立检查右侧，不能把重叠区域默认视作右 Alpha。
            if colorEdges.maxX <= alphaRect.x { return .right }
        // 上下模式只比较 Y，不采用 legacy 的 X 优先推断。
        case .topBottom:
            // 上方和下方均为合法输入，不把颜色固定在第一块。
            if alphaEdges.maxY <= colorRect.y { return .top }
            // 下方同样必须完整分离，剩余情况交给统一错误分支。
            if colorEdges.maxY <= alphaRect.y { return .bottom }
        }
        throw PlaybackError.invalidAlphaLayout(reason: "Color and Alpha rectangles must be disjoint along the declared arrangement axis.")
    }
}
