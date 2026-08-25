import CoreGraphics

/// 宿主动态纹理的共享分配上限。必须在 UIKit 真正分配 bitmap 之前校验。
enum DynamicTextureLimits {
    /// RGBA8 每像素字节数。
    static let bytesPerPixel = 4
    /// 单张动态纹理上限 64 MiB。
    static let maximumBytesPerTexture = 64 * 1_024 * 1_024
    /// 单次 session 全部动态纹理上限 128 MiB。
    static let maximumBytesPerSession = 128 * 1_024 * 1_024

    /// 由 `CGSize` 计算字节数。非法或溢出返回 nil。
    static func byteCount(for size: CGSize) -> Int? {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return nil }
        let width = ceil(size.width)
        let height = ceil(size.height)
        guard width <= CGFloat(Int.max), height <= CGFloat(Int.max) else { return nil }
        return byteCount(width: Int(width), height: Int(height))
    }

    /// 用溢出检测计算 `width * height * 4`，避免超大尺寸绕回成小整数。
    static func byteCount(width: Int, height: Int) -> Int? {
        guard width > 0, height > 0 else { return nil }
        let (pixels, pixelOverflow) = width.multipliedReportingOverflow(by: height)
        let (bytes, byteOverflow) = pixels.multipliedReportingOverflow(by: bytesPerPixel)
        guard !pixelOverflow, !byteOverflow else { return nil }
        return bytes
    }
}
