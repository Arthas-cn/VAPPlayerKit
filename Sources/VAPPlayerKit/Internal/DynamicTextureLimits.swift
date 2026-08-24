import CoreGraphics

/// Shared allocation limits for provider-backed textures. Validate before UIKit allocates.
enum DynamicTextureLimits {
    static let bytesPerPixel = 4
    static let maximumBytesPerTexture = 64 * 1_024 * 1_024
    static let maximumBytesPerSession = 128 * 1_024 * 1_024

    static func byteCount(for size: CGSize) -> Int? {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return nil }
        let width = ceil(size.width)
        let height = ceil(size.height)
        guard width <= CGFloat(Int.max), height <= CGFloat(Int.max) else { return nil }
        return byteCount(width: Int(width), height: Int(height))
    }

    static func byteCount(width: Int, height: Int) -> Int? {
        guard width > 0, height > 0 else { return nil }
        let (pixels, pixelOverflow) = width.multipliedReportingOverflow(by: height)
        let (bytes, byteOverflow) = pixels.multipliedReportingOverflow(by: bytesPerPixel)
        guard !pixelOverflow, !byteOverflow else { return nil }
        return bytes
    }
}
