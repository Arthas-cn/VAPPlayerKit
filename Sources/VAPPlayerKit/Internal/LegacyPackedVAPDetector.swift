import AVFoundation
import CoreVideo
import CoreMedia
import CoreGraphics

/// 对没有 vapc 的资源做保守的旧 packed VAP 识别。
///
/// 旧 VAP 的左半通常是无色 Alpha 灰度图，右半是 RGB；普通视频默认走完整画面。
/// 这只是兼容历史文件的内容特征检测，不是格式证明。若普通视频本身恰好满足这些
/// 特征，宿主可通过 PlaybackOptions.assetMode 强制 `.ordinaryVideo`。
enum LegacyPackedVAPDetector {
    private struct SampleStats {
        let leftChroma: Double
        let rightChroma: Double
        let correlation: Double
        let leftVariance: Double
    }

    /// 只解码首个样本，避免为了识别格式扫描整个媒体。
    static func isLikelyPacked(
        asset: AVAsset,
        track: AVAssetTrack,
        encodedVideoSize: CGSize
    ) -> Bool {
        let width = Int(encodedVideoSize.width)
        let height = Int(encodedVideoSize.height)
        guard width >= 2, width % 2 == 0, height > 0 else { return false }

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
            guard reader.canAdd(output) else { return false }
            reader.add(output)
            guard reader.startReading(),
                  let sample = output.copyNextSampleBuffer(),
                  let pixelBuffer = CMSampleBufferGetImageBuffer(sample)
            else { return false }

            guard CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly) == kCVReturnSuccess else {
                return false
            }
            defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
            return isLikelyPacked(pixelBuffer: pixelBuffer)
        } catch {
            // Automatic detection must not make an otherwise decodable ordinary MP4 fail.
            return false
        }
    }

    private static func isLikelyPacked(pixelBuffer: CVPixelBuffer) -> Bool {
        let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        let halfWidth = width / 2
        guard width >= 2, width % 2 == 0, height > 0,
              let yBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0),
              let uvBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1)
        else { return false }

        let y = yBase.assumingMemoryBound(to: UInt8.self)
        let uv = uvBase.assumingMemoryBound(to: UInt8.self)
        let yBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        let uvBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)
        let uvWidth = CVPixelBufferGetWidthOfPlane(pixelBuffer, 1)
        let uvHeight = CVPixelBufferGetHeightOfPlane(pixelBuffer, 1)
        guard uvWidth > 0, uvHeight > 0 else { return false }

        let stepX = max(1, halfWidth / 32)
        let stepY = max(1, height / 32)
        var values: [(Double, Double)] = []
        var leftChroma = 0.0
        var rightChroma = 0.0

        for row in stride(from: 0, to: height, by: stepY) {
            let uvRow = min(uvHeight - 1, row / 2)
            for column in stride(from: 0, to: halfWidth, by: stepX) {
                let uvColumn = min(uvWidth - 1, column / 2)
                let uvOffset = uvRow * uvBytesPerRow + uvColumn * 2
                leftChroma += abs(Double(uv[uvOffset]) - 128.0)
                    + abs(Double(uv[uvOffset + 1]) - 128.0)

                let rightColumn = column + halfWidth
                let rightUVColumn = min(uvWidth - 1, rightColumn / 2)
                let rightUVOffset = uvRow * uvBytesPerRow + rightUVColumn * 2
                rightChroma += abs(Double(uv[rightUVOffset]) - 128.0)
                    + abs(Double(uv[rightUVOffset + 1]) - 128.0)

                values.append((
                    Double(y[row * yBytesPerRow + column]),
                    Double(y[row * yBytesPerRow + rightColumn])
                ))
            }
        }

        guard values.count >= 16 else { return false }
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
        let stats = SampleStats(
            leftChroma: leftChroma / count,
            rightChroma: rightChroma / count,
            correlation: correlation,
            leftVariance: leftCentered / count
        )
        // The neutral left plane is the key legacy signature. Correlation protects
        // ordinary videos whose left side merely happens to be grayscale.
        let hasMatchedLuma = stats.correlation >= 0.65
            || (stats.leftVariance < 4 && stats.rightChroma >= 8)
        return stats.leftChroma <= 4 && hasMatchedLuma
    }
}
