import AVFoundation
import CoreVideo
import CoreMedia
import CoreGraphics

/// 对没有 vapc 的资源做保守的旧 packed VAP 识别。
///
/// 旧 VAP 的一半通常是无色 Alpha 灰度图，另一半是 RGB；普通视频默认走完整画面。
/// 这只是兼容历史文件的内容特征检测，不是格式证明。若普通视频本身恰好满足这些
/// 特征，宿主可通过 PlaybackOptions.assetMode 强制 `.ordinaryVideo`。
enum LegacyPackedVAPDetector {
    private struct SampleStats {
        let alphaChroma: Double
        let rgbChroma: Double
        let correlation: Double
        let alphaVariance: Double
    }

    private struct Split {
        let mode: AlphaMode
        let alphaOrigin: (x: Int, y: Int)
        let rgbOrigin: (x: Int, y: Int)
        let width: Int
        let height: Int
    }

    private static let maximumNeutralChroma = 4.0
    // A high chroma threshold is deliberately required when Alpha/RGB luma is
    // not correlated. This is the ambiguous case that ordinary split-screen
    // video can resemble; weak colour separation is not enough to crop a video.
    private static let minimumIndependentRGBChroma = 32.0
    private static let minimumLumaCorrelation = 0.65
    private static let maximumFlatAlphaVariance = 4.0
    private static let minimumFlatRGBChroma = 16.0

    /// 返回旧 packed VAP 的 Alpha 方向；`nil` 表示更像普通视频或无法解码首帧。
    ///
    /// 旧 VAP 没有 vapc 方向字段，但编码器可以把等尺寸的 Alpha/RGB 区域
    /// 放在左、右、上、下四个方向。方向必须和布局一起返回，不能检测成功后
    /// 又在 inspector 里固定写死为 `.left`。
    static func detect(
        asset: AVAsset,
        track: AVAssetTrack,
        encodedVideoSize: CGSize
    ) -> AlphaMode? {
        let width = Int(encodedVideoSize.width)
        let height = Int(encodedVideoSize.height)
        guard width > 0, height > 0 else { return nil }

        do {
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(
                track: track,
                outputSettings: [
                    kCVPixelBufferPixelFormatTypeKey as String:
                        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
                ]
            )
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else { return nil }
            reader.add(output)
            guard reader.startReading(),
                  let sample = output.copyNextSampleBuffer(),
                  let pixelBuffer = CMSampleBufferGetImageBuffer(sample)
            else { return nil }

            guard CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly) == kCVReturnSuccess else {
                return nil
            }
            defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
            return detect(pixelBuffer: pixelBuffer)
        } catch {
            // Automatic detection must not make an otherwise decodable ordinary MP4 fail.
            return nil
        }
    }

    private static func detect(pixelBuffer: CVPixelBuffer) -> AlphaMode? {
        let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        guard width > 0, height > 0,
              let yBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0),
              let uvBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1)
        else { return nil }

        let y = yBase.assumingMemoryBound(to: UInt8.self)
        let uv = uvBase.assumingMemoryBound(to: UInt8.self)
        let yBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        let uvBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)
        let uvWidth = CVPixelBufferGetWidthOfPlane(pixelBuffer, 1)
        let uvHeight = CVPixelBufferGetHeightOfPlane(pixelBuffer, 1)
        guard uvWidth > 0, uvHeight > 0 else { return nil }

        let splits = [
            Split(
                mode: .left,
                alphaOrigin: (0, 0),
                rgbOrigin: (width / 2, 0),
                width: width / 2,
                height: height
            ),
            Split(
                mode: .right,
                alphaOrigin: (width / 2, 0),
                rgbOrigin: (0, 0),
                width: width / 2,
                height: height
            ),
            Split(
                mode: .top,
                alphaOrigin: (0, 0),
                rgbOrigin: (0, height / 2),
                width: width,
                height: height / 2
            ),
            Split(
                mode: .bottom,
                alphaOrigin: (0, height / 2),
                rgbOrigin: (0, 0),
                width: width,
                height: height / 2
            )
        ].filter { split in
            switch split.mode {
            case .left, .right:
                return width >= 2 && width % 2 == 0
            case .top, .bottom:
                return height >= 2 && height % 2 == 0
            case .none:
                return false
            }
        }

        let matches = splits.compactMap { split -> AlphaMode? in
            guard let stats = stats(
                for: split,
                y: y,
                yBytesPerRow: yBytesPerRow,
                uv: uv,
                uvBytesPerRow: uvBytesPerRow,
                uvWidth: uvWidth,
                uvHeight: uvHeight
            ) else { return nil }
            return isMatch(stats) ? split.mode : nil
        }
        // If more than one orientation matches, the first frame is ambiguous;
        // keep the ordinary-video interpretation instead of cropping arbitrarily.
        return matches.count == 1 ? matches[0] : nil
    }

    private static func stats(
        for split: Split,
        y: UnsafePointer<UInt8>,
        yBytesPerRow: Int,
        uv: UnsafePointer<UInt8>,
        uvBytesPerRow: Int,
        uvWidth: Int,
        uvHeight: Int
    ) -> SampleStats? {
        guard split.width > 0, split.height > 0 else { return nil }

        let stepX = max(1, split.width / 32)
        let stepY = max(1, split.height / 32)
        var values: [(Double, Double)] = []

        var alphaChroma = 0.0
        var rgbChroma = 0.0
        for localY in stride(from: 0, to: split.height, by: stepY) {
            let alphaY = split.alphaOrigin.y + localY
            let rgbY = split.rgbOrigin.y + localY
            for localX in stride(from: 0, to: split.width, by: stepX) {
                let alphaX = split.alphaOrigin.x + localX
                let rgbX = split.rgbOrigin.x + localX
                alphaChroma += chroma(
                    atX: alphaX,
                    y: alphaY,
                    uv: uv,
                    bytesPerRow: uvBytesPerRow,
                    width: uvWidth,
                    height: uvHeight
                )
                rgbChroma += chroma(
                    atX: rgbX,
                    y: rgbY,
                    uv: uv,
                    bytesPerRow: uvBytesPerRow,
                    width: uvWidth,
                    height: uvHeight
                )
                values.append((
                    Double(y[alphaY * yBytesPerRow + alphaX]),
                    Double(y[rgbY * yBytesPerRow + rgbX])
                ))
            }
        }

        guard values.count >= 16 else { return nil }
        let count = Double(values.count)
        let leftMean = values.reduce(0.0) { $0 + $1.0 } / count
        let rightMean = values.reduce(0.0) { $0 + $1.1 } / count
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
        let correlation: Double
        if leftCentered > 0.001, rightCentered > 0.001 {
            correlation = cross / sqrt(leftCentered * rightCentered)
        } else {
            correlation = -1
        }
        return SampleStats(
            alphaChroma: alphaChroma / count,
            rgbChroma: rgbChroma / count,
            correlation: correlation,
            alphaVariance: leftCentered / count
        )
    }

    private static func chroma(
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

    private static func isMatch(_ stats: SampleStats) -> Bool {
        // The neutral Alpha plane is the key legacy signature. Most packed files
        // also have related luma in both regions, but that is not guaranteed: the
        // Alpha mask can animate independently from the RGB artwork. A strongly
        // chromatic RGB region is therefore an independent packed-layout signal.
        // The ordinary-video override remains available for the inherently
        // ambiguous case where a normal video has the same visual composition.
        let hasMatchedLuma = stats.correlation >= minimumLumaCorrelation
            || (stats.alphaVariance < maximumFlatAlphaVariance
                && stats.rgbChroma >= minimumFlatRGBChroma)
            || stats.rgbChroma >= minimumIndependentRGBChroma
        return stats.alphaChroma <= maximumNeutralChroma && hasMatchedLuma
    }
}
