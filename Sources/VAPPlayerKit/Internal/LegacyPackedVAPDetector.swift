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
        let maximumAlphaChroma: Double
        let rgbChroma: Double
        let alphaMean: Double
        let rgbMean: Double
        let rgbVariance: Double
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
    // Some legacy files use independently authored Alpha and RGB animations. In
    // those files luma correlation is not reliable, and the RGB half may still
    // be dark or nearly monochrome. A strong luma contrast is an additional
    // signal for that case.
    private static let minimumIndependentRGBChroma = 32.0
    private static let minimumLumaCorrelation = 0.65
    private static let maximumFlatAlphaVariance = 4.0
    private static let minimumFlatRGBChroma = 16.0
    private static let minimumRGBLumaVariance = 64.0
    private static let minimumAlphaRGBMeanDifference = 24.0
    // Probe order is intentionally fixed: A (20%), B (50%), C (70%).
    private static let detectionPercentages: [Double] = [0.20, 0.50, 0.70]

    static func probeTimes(for duration: TimeInterval) -> [TimeInterval] {
        guard duration.isFinite, duration > 0 else { return [] }
        return detectionPercentages.map { duration * $0 }
    }

    /// 返回旧 packed VAP 的 Alpha 方向；`nil` 表示更像普通视频或无法解码。
    ///
    /// 旧 VAP 没有 vapc 方向字段，但编码器可以把等尺寸的 Alpha/RGB 区域
    /// 放在左、右、上、下四个方向。方向必须和布局一起返回，不能检测成功后
    /// 又在 inspector 里固定写死为 `.left`。
    static func detect(
        asset: AVAsset,
        track: AVAssetTrack,
        encodedVideoSize: CGSize,
        duration: TimeInterval
    ) -> AlphaMode? {
        let width = Int(encodedVideoSize.width)
        let height = Int(encodedVideoSize.height)
        guard width > 0, height > 0, duration.isFinite, duration > 0 else { return nil }

        do {
            let trackRange = track.timeRange
            let trackDuration = CMTimeGetSeconds(trackRange.duration)
            guard trackDuration.isFinite, trackDuration > 0 else { return nil }

            // A single sample is read for each percentage. The small range gives
            // AVAssetReader room to return the frame at/just after a timestamp
            // that is not exactly aligned to the track's frame duration, while
            // the detector itself examines only that one returned frame.
            let nominalFrameRate = Double(track.nominalFrameRate)
            let frameWindow = max(
                1.0 / 30.0,
                nominalFrameRate > 0 ? 1.0 / nominalFrameRate : 1.0 / 30.0
            )
            let readDuration = CMTime(
                seconds: min(frameWindow * 2.0, trackDuration),
                preferredTimescale: 600
            )

            return firstMatchingMode(
                duration: duration,
                trackRange: trackRange,
                readDuration: readDuration
            ) { range in
                try? detect(asset: asset, track: track, timeRange: range)
            }
        } catch {
            // Automatic detection must not make an otherwise decodable ordinary MP4 fail.
            return nil
        }
    }

    /// Builds and evaluates the A/B/C probe schedule. Kept separate so the
    /// timestamp policy and its short-circuit behavior can be regression-tested
    /// without opening a decoder.
    static func firstMatchingMode(
        duration: TimeInterval,
        trackRange: CMTimeRange,
        readDuration: CMTime,
        sampleDetector: (CMTimeRange) -> AlphaMode?
    ) -> AlphaMode? {
        for targetSeconds in probeTimes(for: duration) {
            // The percentage is relative to the asset timeline (which starts
            // at zero), not relative to the video track's start or duration.
            let target = CMTime(
                seconds: targetSeconds,
                preferredTimescale: 600
            )
            guard CMTimeCompare(target, trackRange.start) >= 0,
                  CMTimeCompare(target, trackRange.end) < 0
            else { continue }
            let availableDuration = CMTimeSubtract(trackRange.end, target)
            guard CMTimeCompare(availableDuration, .zero) > 0 else { continue }

            let range = CMTimeRange(
                start: target,
                duration: min(readDuration, availableDuration)
            )
            if let mode = sampleDetector(range) {
                return mode
            }
        }
        return nil
    }

    private static func detect(
        asset: AVAsset,
        track: AVAssetTrack,
        timeRange: CMTimeRange
    ) throws -> AlphaMode? {
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = timeRange
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
              let pixelBuffer = CMSampleBufferGetImageBuffer(sample),
              CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly) == kCVReturnSuccess
        else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        return detect(pixelBuffer: pixelBuffer)
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
        // If more than one orientation matches, this probe frame is ambiguous;
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

        var alphaChromas: [Double] = []
        var rgbChroma = 0.0
        var rgbChromaCount = 0
        for localY in stride(from: 0, to: split.height, by: stepY) {
            let alphaY = split.alphaOrigin.y + localY
            let rgbY = split.rgbOrigin.y + localY
            for localX in stride(from: 0, to: split.width, by: stepX) {
                let alphaX = split.alphaOrigin.x + localX
                let rgbX = split.rgbOrigin.x + localX
                // NV12 chroma covers a 2x2 luma block. Do not let a block
                // straddling the Alpha/RGB split contaminate either region's
                // chroma statistic, especially for odd top/bottom dimensions.
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
                if containsChromaBlock(
                    atX: rgbX,
                    y: rgbY,
                    origin: split.rgbOrigin,
                    width: split.width,
                    height: split.height
                ) {
                    rgbChroma += chroma(
                        atX: rgbX,
                        y: rgbY,
                        uv: uv,
                        bytesPerRow: uvBytesPerRow,
                        width: uvWidth,
                        height: uvHeight
                    )
                    rgbChromaCount += 1
                }
                values.append((
                    Double(y[alphaY * yBytesPerRow + alphaX]),
                    Double(y[rgbY * yBytesPerRow + rgbX])
                ))
            }
        }

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
        if leftCentered > 0.001, rightCentered > 0.001 {
            correlation = cross / sqrt(leftCentered * rightCentered)
        } else {
            correlation = -1
        }
        return SampleStats(
            maximumAlphaChroma: maximumAlphaChroma,
            rgbChroma: rgbChroma / Double(rgbChromaCount),
            alphaMean: leftMean,
            rgbMean: rightMean,
            rgbVariance: rgbVariance,
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

    private static func containsChromaBlock(
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
            || (stats.rgbVariance >= minimumRGBLumaVariance
                && abs(stats.alphaMean - stats.rgbMean) >= minimumAlphaRGBMeanDifference)
        // Every sampled point in the candidate Alpha region must remain neutral.
        // This rejects ordinary split-screen video with only a mostly-gray side.
        return stats.maximumAlphaChroma <= maximumNeutralChroma && hasMatchedLuma
    }
}
