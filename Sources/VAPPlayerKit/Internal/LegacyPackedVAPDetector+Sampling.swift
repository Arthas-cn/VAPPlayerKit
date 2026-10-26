import Foundation

/// 旧拼接判型的像素统计与证据组合；与入口分开维护，不修改输入缓冲区或决定探测时刻。
extension LegacyPackedVAPDetector {
    /// 单一候选方向的稀疏采样统计，只用于保守判型，不改变输入像素。
    struct SampleStats {
        /// Alpha 区所有有效采样点中的最大色度偏差，必须接近中性。
        let maximumAlphaChroma: Double
        /// RGB 区最显著的色度偏差，用于辨认稀疏彩色内容。
        let maximumRGBChroma: Double
        /// RGB 区有效色度采样点的平均偏差。
        let rgbChroma: Double
        /// Alpha 区亮度均值，区分有效遮罩与普通黑边。
        let alphaMean: Double
        /// RGB 区亮度均值，用于检查两半亮度反差。
        let rgbMean: Double
        /// RGB 区亮度方差，值越大表示画面具有更多结构。
        let rgbVariance: Double
        /// 两半亮度的相关系数；缺少有效方差时以 -1 表示无证据。
        let correlation: Double
        /// Alpha 区亮度方差，近零表示遮罩基本平坦。
        let alphaVariance: Double
    }

    /// 一个对半候选的几何信息；只描述旧素材，不用于显式 packedAlpha。
    struct Split {
        /// 当前候选假定的 Alpha 所在方向。
        let mode: AlphaMode
        /// Alpha 半幅的编码像素起点。
        let alphaOrigin: (x: Int, y: Int)
        /// RGB 半幅的编码像素起点。
        let rgbOrigin: (x: Int, y: Int)
        /// 两个等尺寸半幅各自的像素宽度。
        let width: Int
        /// 两个等尺寸半幅各自的像素高度。
        let height: Int
    }

    /// 在候选两半上稀疏采样亮度与色度；可带内容位移，样本不足时返回 nil。
    static func stats(
        for split: Split,
        y: UnsafePointer<UInt8>,
        yBytesPerRow: Int,
        uv: UnsafePointer<UInt8>,
        uvBytesPerRow: Int,
        uvWidth: Int,
        uvHeight: Int,
        shift: Int = 0
    ) -> SampleStats? {
        // 无面积的候选无法计算有意义的均值与相关性。
        guard split.width > 0, split.height > 0 else { return nil }

        let stepX = max(1, split.width / 32)
        let stepY = max(1, split.height / 32)
        var values: [(Double, Double)] = []

        var alphaChromas: [Double] = []
        var rgbChroma = 0.0
        var rgbChromaCount = 0
        var maximumRGBChroma = 0.0
        for localY in stride(from: 0, to: split.height, by: stepY) {
            let rgbY = split.rgbOrigin.y + localY
            for localX in stride(from: 0, to: split.width, by: stepX) {
                var alphaX = split.alphaOrigin.x + localX
                var alphaY = split.alphaOrigin.y + localY
                let rgbX = split.rgbOrigin.x + localX
                switch split.mode {
                // 左右分割时两半内容沿竖直方向错位，横向位置保持不变。
                case .left, .right:
                    alphaY += shift
                // 上下分割时两半内容沿水平方向错位。
                case .top, .bottom:
                    alphaX += shift
                // 无 Alpha 不引入位移；正常候选构造不会产生此方向。
                case .none:
                    break
                }
                let shiftedAlphaX = alphaX - split.alphaOrigin.x
                let shiftedAlphaY = alphaY - split.alphaOrigin.y
                // 位移后超出 Alpha 半幅的点不参与统计，避免读进 RGB 或越界。
                guard shiftedAlphaX >= 0, shiftedAlphaY >= 0,
                      shiftedAlphaX < split.width, shiftedAlphaY < split.height else {
                    continue
                }
                // NV12 色度覆盖 2×2 亮度块；跨分界线的块会混入另一半颜色，必须排除。
                if containsChromaBlock(
                    atX: alphaX,
                    y: alphaY,
                    origin: split.alphaOrigin,
                    width: split.width,
                    height: split.height
                ) {
                    alphaChromas.append(chroma(
                        atX: alphaX,
                        y: alphaY,
                        uv: uv,
                        bytesPerRow: uvBytesPerRow,
                        width: uvWidth,
                        height: uvHeight
                    ))
                }
                // RGB 也只用完整落在本半幅的色度块，避免边界反向污染均值。
                if containsChromaBlock(
                    atX: rgbX,
                    y: rgbY,
                    origin: split.rgbOrigin,
                    width: split.width,
                    height: split.height
                ) {
                    let sampleChroma = chroma(
                        atX: rgbX,
                        y: rgbY,
                        uv: uv,
                        bytesPerRow: uvBytesPerRow,
                        width: uvWidth,
                        height: uvHeight
                    )
                    rgbChroma += sampleChroma
                    maximumRGBChroma = max(maximumRGBChroma, sampleChroma)
                    rgbChromaCount += 1
                }
                values.append((
                    Double(y[alphaY * yBytesPerRow + alphaX]),
                    Double(y[rgbY * yBytesPerRow + rgbX])
                ))
            }
        }

        // 亮度样本或任一侧色度证据不足时拒绝计算，不能把空集当成中性透明区。
        guard values.count >= 16, !alphaChromas.isEmpty, rgbChromaCount > 0 else { return nil }
        let count = Double(values.count)
        let leftMean = values.reduce(0.0) { $0 + $1.0 } / count
        let rightMean = values.reduce(0.0) { $0 + $1.1 } / count
        guard let maximumAlphaChroma = alphaChromas.max() else { return nil }
        var leftCentered = 0.0
        var rightCentered = 0.0
        var cross = 0.0
        for (left, right) in values {
            let leftDelta = left - leftMean
            let rightDelta = right - rightMean
            leftCentered += leftDelta * leftDelta
            rightCentered += rightDelta * rightDelta
            cross += leftDelta * rightDelta
        }
        let rgbVariance = rightCentered / count
        let correlation: Double
        // 两侧均有结构时才能计算相关系数；任一侧近常数时明确记为无相关证据。
        if leftCentered > 0.001, rightCentered > 0.001 {
            correlation = cross / sqrt(leftCentered * rightCentered)
        } else {
            // -1 不代表真实反相关，只禁止平坦信号走强相关分支。
            correlation = -1
        }
        return SampleStats(
            maximumAlphaChroma: maximumAlphaChroma,
            maximumRGBChroma: maximumRGBChroma,
            rgbChroma: rgbChroma / Double(rgbChromaCount),
            alphaMean: leftMean,
            rgbMean: rightMean,
            rgbVariance: rgbVariance,
            correlation: correlation,
            alphaVariance: leftCentered / count
        )
    }

    /// 读取一个 NV12 色度块到中性点 128 的偏差；调用方已保证色度平面尺寸为正。
    static func chroma(
        atX x: Int,
        y: Int,
        uv: UnsafePointer<UInt8>,
        bytesPerRow: Int,
        width: Int,
        height: Int
    ) -> Double {
        let uvRow = min(height - 1, max(0, y / 2))
        let uvColumn = min(width - 1, max(0, x / 2))
        let offset = uvRow * bytesPerRow + uvColumn * 2
        return abs(Double(uv[offset]) - 128.0)
            + abs(Double(uv[offset + 1]) - 128.0)
    }

    /// 检查亮度点对应的完整 2×2 色度块是否落在同一半幅，排除跨分界线的混色。
    static func containsChromaBlock(
        atX x: Int,
        y: Int,
        origin: (x: Int, y: Int),
        width: Int,
        height: Int
    ) -> Bool {
        let blockX = (x / 2) * 2
        let blockY = (y / 2) * 2
        return blockX >= origin.x
            && blockY >= origin.y
            && blockX + 1 < origin.x + width
            && blockY + 1 < origin.y + height
    }

    /// 组合中性色度、亮度结构与反差信号；只是启发式证据，不承诺识别任意普通视频。
    static func isMatch(_ stats: SampleStats) -> Bool {
        // 全黑平坦区无法与普通视频黑边区分；交给后续探测帧，不据此裁切当前画面。
        guard stats.correlation >= minimumLumaCorrelation
                || stats.alphaVariance >= maximumFlatAlphaVariance || stats.alphaMean > 20 else {
            return false
        }

        // Alpha 可与 RGB 独立制作，亮度不一定相关；强色度或亮度反差可提供后备证据。
        // 普通视频可能具有相同构图，宿主仍可显式选择 ordinaryVideo 禁用这条推断。
        let hasMatchedLuma = stats.correlation >= minimumLumaCorrelation
            || (stats.alphaVariance < maximumFlatAlphaVariance
                && stats.rgbChroma >= minimumFlatRGBChroma)
            || stats.rgbChroma >= minimumIndependentRGBChroma
            || (stats.rgbVariance >= minimumRGBLumaVariance
                && abs(stats.alphaMean - stats.rgbMean) >= minimumAlphaRGBMeanDifference)
        // Alpha 的每个有效采样点都必须中性，不能把“大部分是灰色”的分屏当成遮罩。
        return stats.maximumAlphaChroma <= maximumNeutralChroma && hasMatchedLuma
    }
}
