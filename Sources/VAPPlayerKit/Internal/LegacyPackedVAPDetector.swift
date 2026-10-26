import AVFoundation
import CoreVideo
import CoreMedia
import CoreGraphics

/// 一次旧 packed VAP 识别结果。`alphaOffset` 为 0 表示 Alpha 与 RGB 在分割轴上对齐。
///
/// 负值表示 Alpha 内容相对 RGB 更靠近原点（左右分割时更靠上，上下分割时更靠左）。
struct LegacyPackedLayout: Equatable {
    /// Alpha 区域位于编码帧哪一侧；检测结果不会使用 none。
    let alphaMode: AlphaMode
    /// 两半内容在延伸方向上的像素位移；零表示可直接对齐采样。
    let alphaOffset: Int
}

/// 对没有 vapc 的资源做保守的旧 packed VAP 识别。
///
/// 旧 VAP 的一半通常是无色 Alpha 灰度图，另一半是 RGB；普通视频默认走完整画面。
/// 个别素材的两半轮廓一致，但在分割轴上整体错开，对齐采样时相关性会接近 0。
/// 这只是兼容历史文件的内容特征检测，不是格式证明。若普通视频本身恰好满足这些
/// 特征，宿主可通过 PlaybackOptions.assetMode 强制 `.ordinaryVideo`。
enum LegacyPackedVAPDetector {
    /// 允许的 Alpha 最大色度偏差；任何明显彩色采样都会否决候选。
    static let maximumNeutralChroma = 4.0
    /// Alpha 与 RGB 独立制作时，足够强的 RGB 色度可补充亮度相关证据。
    static let minimumIndependentRGBChroma = 32.0
    /// 对齐候选至少达到的亮度相关系数。
    static let minimumLumaCorrelation = 0.65
    /// Alpha 方差低于此值时按平坦遮罩检查。
    static let maximumFlatAlphaVariance = 4.0
    /// 平坦遮罩旁的 RGB 至少具备的平均色度。
    static let minimumFlatRGBChroma = 16.0
    /// 借助亮度反差判型时，RGB 至少具备的亮度方差。
    static let minimumRGBLumaVariance = 64.0
    /// 借助亮度反差判型时，两半均值至少相差的亮度值。
    static let minimumAlphaRGBMeanDifference = 24.0
    /// 错位至少要跨过若干像素，避免把采样噪声当成第二种布局。
    private static let minimumAbsoluteContentShift = 8
    /// 错位后仍须留下过半画面，避免把无关条带配成 Alpha。
    private static let maximumShiftFraction = 0.40
    /// 错位路径不复用对齐采样的点相关判定，投影相关和增益因此高于对齐路径的 0.65。
    /// 0.85 仍覆盖 7878 在 20% 处约 0.88 的轮廓相关。
    private static let minimumShiftedLumaCorrelation = 0.85
    /// 错位相关性必须明显高于零位移，避免普通画面的弱相似被裁开。
    private static let minimumShiftCorrelationGain = 0.40
    /// 固定按总时长的 20%、50%、70% 探测；首个可靠结果立即结束后续探测。
    private static let detectionPercentages: [Double] = [0.20, 0.50, 0.70]

    /// 根据整个素材的时长生成探测时刻；无效时长没有可安全读取的时刻。
    static func probeTimes(for duration: TimeInterval) -> [TimeInterval] {
        // NaN、无穷或非正时长不能传入 reader 的时间范围。
        guard duration.isFinite, duration > 0 else { return [] }
        return detectionPercentages.map { duration * $0 }
    }

    /// 返回旧 packed VAP 的 Alpha 方向和沿分割轴的内容错位；`nil` 表示更像普通视频或无法解码。
    ///
    /// 旧 VAP 没有 vapc 方向字段，但编码器可以把等尺寸的 Alpha/RGB 区域
    /// 放在左、右、上、下四个方向。方向必须和布局一起返回，不能检测成功后
    /// 又在 inspector 里固定写死为 `.left`。内容错位同样要带回，不能检测成功后
    /// 仍按零位移裁切。
    static func detect(
        asset: AVAsset,
        track: AVAssetTrack,
        encodedVideoSize: CGSize,
        duration: TimeInterval
    ) async -> LegacyPackedLayout? {
        let width = Int(encodedVideoSize.width)
        let height = Int(encodedVideoSize.height)
        // 缺少有效画布或时长时只放弃启发式识别，交回普通视频路径。
        guard width > 0, height > 0, duration.isFinite, duration > 0 else { return nil }

        do {
            let trackRange = try await track.load(.timeRange)
            let trackDuration = CMTimeGetSeconds(trackRange.duration)
            // 视频轨没有有效范围时不能按素材总时长构造采样窗口。
            guard trackDuration.isFinite, trackDuration > 0 else { return nil }

            // 时刻未必落在帧边界；窗口允许 reader 找到其后第一帧，但每次只分析一帧。
            let nominalFrameRate = Double(try await track.load(.nominalFrameRate))
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
            // 可选自动识别失败不应阻止原本可播放的普通 MP4，由外层处理取消与资源错误。
            return nil
        }
    }

    /// 按固定顺序执行探测，首个可靠结果即返回；独立入口便于不创建 decoder 测试时间策略。
    static func firstMatchingMode(
        duration: TimeInterval,
        trackRange: CMTimeRange,
        readDuration: CMTime,
        sampleDetector: (CMTimeRange) -> LegacyPackedLayout?
    ) -> LegacyPackedLayout? {
        for targetSeconds in probeTimes(for: duration) {
            // 百分比相对从零开始的素材时间轴，不相对视频轨起点或轨道自身时长。
            let target = CMTime(
                seconds: targetSeconds,
                preferredTimescale: 600
            )
            // 有些轨道晚于素材开始；落在轨道外的探测点直接跳过，不挪动原定百分比。
            guard CMTimeCompare(target, trackRange.start) >= 0,
                  CMTimeCompare(target, trackRange.end) < 0
            else { continue }
            let availableDuration = CMTimeSubtract(trackRange.end, target)
            // 尾部不足以读取时不构造零长或负长的 reader 区间。
            guard CMTimeCompare(availableDuration, .zero) > 0 else { continue }

            let range = CMTimeRange(
                start: target,
                duration: min(readDuration, availableDuration)
            )
            // 已有明确方向后停止，不让后续空白帧否定先前证据。
            if let mode = sampleDetector(range) {
                return mode
            }
        }
        return nil
    }

    /// 只读取指定短窗口的第一帧；无法建立输出或取帧时返回 nil，reader 初始化失败向外抛出。
    private static func detect(
        asset: AVAsset,
        track: AVAssetTrack,
        timeRange: CMTimeRange
    ) throws -> LegacyPackedLayout? {
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
        // 不支持该轨道输出时放弃此探测点，不改变后续播放的解码配置。
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        // 空窗口或解码失败没有判型证据，由后续探测点继续尝试。
        guard reader.startReading(),
              let sample = output.copyNextSampleBuffer(),
              let pixelBuffer = CMSampleBufferGetImageBuffer(sample)
        else { return nil }
        return detect(pixelBuffer: pixelBuffer)
    }

    /// 检查一帧 NV12 像素的唯一可信布局；只临时只读锁定，不修改或保存调用方缓冲区。
    static func detect(pixelBuffer: CVPixelBuffer) -> LegacyPackedLayout? {
        // 无法锁定时不可读取底层指针；成功路径用 defer 对称解锁。
        guard CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly) == kCVReturnSuccess else {
            return nil
        }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        // 缺少亮度或色度平面时不对不完整数据猜测透明布局。
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
        // 色度寻址需要至少一个有效采样块。
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
            // 左右候选共享等宽约束；仅 legacy 探测要求切分轴可对半。
            case .left, .right:
                return width >= 2 && width % 2 == 0
            // 上下候选共享等高约束，与显式矩形允许奇数边界的合同不同。
            case .top, .bottom:
                return height >= 2 && height % 2 == 0
            // 无 Alpha 不是待检测的拼接候选。
            case .none:
                return false
            }
        }

        // 对应轮廓比黑边的亮度反差更可靠；多方向命中仍有歧义，不能据此裁开普通视频。
        // 强相关候选优先；只有完全没有强候选且弱候选唯一时才采用后备结果。
        var correlatedModes: [AlphaMode] = []
        var fallbackModes: [AlphaMode] = []
        for split in splits {
            // 统计不足或色度/亮度证据不成立时，此方向不参与唯一性判定。
            guard let stats = stats(
                for: split,
                y: y,
                yBytesPerRow: yBytesPerRow,
                uv: uv,
                uvBytesPerRow: uvBytesPerRow,
                uvWidth: uvWidth,
                uvHeight: uvHeight
            ), isMatch(stats) else { continue }
            // 相关轮廓属于强证据；单纯色度或亮度反差留作后备，不能挤掉强证据。
            if stats.correlation >= minimumLumaCorrelation {
                correlatedModes.append(split.mode)
            } else {
                // 已通过 isMatch 的弱证据只在没有强候选时使用。
                fallbackModes.append(split.mode)
            }
        }
        // 多个强方向同样可能来自灰度重复画面，宁可保留普通视频也不任选方向。
        if !correlatedModes.isEmpty {
            guard correlatedModes.count == 1, let mode = correlatedModes.first else { return nil }
            return LegacyPackedLayout(alphaMode: mode, alphaOffset: 0)
        }
        // 后备方向也必须唯一，避免把黑边误作透明半幅。
        if !fallbackModes.isEmpty {
            guard fallbackModes.count == 1, let mode = fallbackModes.first else { return nil }
            return LegacyPackedLayout(alphaMode: mode, alphaOffset: 0)
        }
        return shiftedLayout(
            splits: splits,
            y: y,
            yBytesPerRow: yBytesPerRow,
            uv: uv,
            uvBytesPerRow: uvBytesPerRow,
            uvWidth: uvWidth,
            uvHeight: uvHeight
        )
    }

    /// 对齐采样失败后，沿分割轴寻找唯一的轮廓错位。
    ///
    /// 错位不是格式证明。除了 Alpha 必须接近中性、RGB 必须有彩色，
    /// 垂直错位时水平投影也要对得上，避免把半灰半彩的普通分屏裁开。
    /// 多个方向同时命中时返回 nil。
    private static func shiftedLayout(
        splits: [Split],
        y: UnsafePointer<UInt8>,
        yBytesPerRow: Int,
        uv: UnsafePointer<UInt8>,
        uvBytesPerRow: Int,
        uvWidth: Int,
        uvHeight: Int
    ) -> LegacyPackedLayout? {
        var matches: [LegacyPackedLayout] = []
        for split in splits {
            // 没有可靠投影位移的方向不再尝试用弱色度证据补齐。
            guard let shift = bestProfileShift(split: split, y: y, yBytesPerRow: yBytesPerRow) else {
                continue
            }
            // 稀疏素材在 32×32 网格上的相关性会被黑底稀释，投影相关才是错位证据。
            // 色度仍逐点检查，避免把带颜色的半幅当成 Alpha。
            guard let sample = stats(
                for: split,
                y: y,
                yBytesPerRow: yBytesPerRow,
                uv: uv,
                uvBytesPerRow: uvBytesPerRow,
                uvWidth: uvWidth,
                uvHeight: uvHeight,
                shift: shift
            ), sample.maximumAlphaChroma <= maximumNeutralChroma,
               sample.maximumRGBChroma >= minimumFlatRGBChroma,
               sample.alphaVariance >= maximumFlatAlphaVariance || sample.alphaMean > 20,
               crossAxisSupportsShift(split: split, y: y, yBytesPerRow: yBytesPerRow) else {
                continue
            }
            matches.append(LegacyPackedLayout(alphaMode: split.mode, alphaOffset: shift))
        }
        // 不同方向同时命中仍有歧义，不能按遍历顺序裁切画面。
        return matches.count == 1 ? matches[0] : nil
    }

    /// 在亮度投影上找相关性最高的偶数位移。零位移由对齐路径负责。
    private static func bestProfileShift(
        split: Split,
        y: UnsafePointer<UInt8>,
        yBytesPerRow: Int
    ) -> Int? {
        let vertical = split.mode == .left || split.mode == .right
        let length = vertical ? split.height : split.width
        let cross = vertical ? split.width : split.height
        // 投影过短时位移相关性不稳定，不进入搜索。
        guard length >= 32, cross > 0 else { return nil }
        let maxShift = (Int(Double(length) * maximumShiftFraction) / 2) * 2
        // 可搜索范围不足最小可信位移时，结果仍由对齐路径决定。
        guard maxShift >= minimumAbsoluteContentShift else { return nil }

        let step = max(1, cross / 48)
        var rgb = [Double](repeating: 0, count: length)
        var alpha = [Double](repeating: 0, count: length)
        // 左右半幅按行求投影，寻找竖直方向的内容偏移。
        if vertical {
            for row in 0..<length {
                var rgbSum = 0.0
                var alphaSum = 0.0
                var column = 0
                while column < cross {
                    rgbSum += Double(y[(split.rgbOrigin.y + row) * yBytesPerRow + split.rgbOrigin.x + column])
                    alphaSum += Double(y[(split.alphaOrigin.y + row) * yBytesPerRow + split.alphaOrigin.x + column])
                    column += step
                }
                rgb[row] = rgbSum
                alpha[row] = alphaSum
            }
        } else {
            // 上下半幅按列求投影，寻找水平方向的内容偏移。
            for column in 0..<length {
                var rgbSum = 0.0
                var alphaSum = 0.0
                var row = 0
                while row < cross {
                    rgbSum += Double(y[(split.rgbOrigin.y + row) * yBytesPerRow + split.rgbOrigin.x + column])
                    alphaSum += Double(y[(split.alphaOrigin.y + row) * yBytesPerRow + split.alphaOrigin.x + column])
                    row += step
                }
                rgb[column] = rgbSum
                alpha[column] = alphaSum
            }
        }

        let zero = profileCorrelation(rgb, alpha, shift: 0)
        var bestShift = 0
        var best = zero
        var shift = -maxShift
        while shift <= maxShift {
            // 零位移已经作为基线；这里只评估可带来额外证据的非零位移。
            if shift != 0 {
                let value = profileCorrelation(rgb, alpha, shift: shift)
                // 仅保留严格改善，相关度相等时不任意更换先前候选。
                if value > best {
                    best = value
                    bestShift = shift
                }
            }
            shift += 2
        }
        // 同时约束绝对相关度和相对提升，防止弱相似或采样噪声生成错误裁切。
        guard bestShift != 0,
              abs(bestShift) >= minimumAbsoluteContentShift,
              best >= minimumShiftedLumaCorrelation,
              best - zero >= minimumShiftCorrelationGain else {
            return nil
        }
        return bestShift
    }

    /// 错位轴的另一维也要是同一轮廓。两侧在这一维都没有结构时不否决。
    private static func crossAxisSupportsShift(
        split: Split,
        y: UnsafePointer<UInt8>,
        yBytesPerRow: Int
    ) -> Bool {
        let vertical = split.mode == .left || split.mode == .right
        let length = vertical ? split.width : split.height
        let span = vertical ? split.height : split.width
        // 交叉轴缺少足够采样宽度时不能证明两半属于同一轮廓。
        guard length >= 8, span > 0 else { return false }
        let step = max(1, span / 48)
        var rgb = [Double](repeating: 0, count: length)
        var alpha = [Double](repeating: 0, count: length)
        // 竖直错位用横向投影复核，防止无关的半灰半彩图碰巧对齐。
        if vertical {
            for column in 0..<length {
                var rgbSum = 0.0
                var alphaSum = 0.0
                var row = 0
                while row < span {
                    rgbSum += Double(y[(split.rgbOrigin.y + row) * yBytesPerRow + split.rgbOrigin.x + column])
                    alphaSum += Double(y[(split.alphaOrigin.y + row) * yBytesPerRow + split.alphaOrigin.x + column])
                    row += step
                }
                rgb[column] = rgbSum
                alpha[column] = alphaSum
            }
        } else {
            // 水平错位用纵向投影复核，判据与另一方向对称。
            for row in 0..<length {
                var rgbSum = 0.0
                var alphaSum = 0.0
                var column = 0
                while column < span {
                    rgbSum += Double(y[(split.rgbOrigin.y + row) * yBytesPerRow + split.rgbOrigin.x + column])
                    alphaSum += Double(y[(split.alphaOrigin.y + row) * yBytesPerRow + split.alphaOrigin.x + column])
                    column += step
                }
                rgb[row] = rgbSum
                alpha[row] = alphaSum
            }
        }
        let rgbHasDetail = profileHasDetail(rgb)
        let alphaHasDetail = profileHasDetail(alpha)
        // 两侧交叉轴都无结构时没有反证，不能否决沿主轴已经成立的轮廓。
        if !rgbHasDetail, !alphaHasDetail {
            return true
        }
        // 只有一侧存在结构时轮廓不相容；两侧都有细节才比较零位移相关性。
        guard rgbHasDetail, alphaHasDetail else { return false }
        return profileCorrelation(rgb, alpha, shift: 0) >= minimumLumaCorrelation
    }

    /// 判断投影是否有足以计算相关性的结构；空数组或近常数投影均为 false。
    private static func profileHasDetail(_ values: [Double]) -> Bool {
        // 空投影不是平坦遮罩的证据，避免除以零。
        guard !values.isEmpty else { return false }
        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)
        return variance > 1
    }

    /// 在等长投影的重叠区计算相关度；样本或方差不足时以 -1 表示无可靠证据。
    private static func profileCorrelation(_ rgb: [Double], _ alpha: [Double], shift: Int) -> Double {
        let count = rgb.count
        var pairs = 0
        var rgbSum = 0.0
        var alphaSum = 0.0
        for index in 0..<count {
            let alphaIndex = index + shift
            // 位移产生的非重叠区不能参与均值，否则会虚增亮度反差。
            guard alphaIndex >= 0, alphaIndex < count else { continue }
            rgbSum += rgb[index]
            alphaSum += alpha[alphaIndex]
            pairs += 1
        }
        // 重叠过短时即便数值相关也不可靠，统一视为没有证据。
        guard pairs >= 16 else { return -1 }
        let rgbMean = rgbSum / Double(pairs)
        let alphaMean = alphaSum / Double(pairs)
        var rgbCentered = 0.0
        var alphaCentered = 0.0
        var cross = 0.0
        for index in 0..<count {
            let alphaIndex = index + shift
            // 方差与协方差必须使用前面计算均值时的同一重叠区。
            guard alphaIndex >= 0, alphaIndex < count else { continue }
            let rgbDelta = rgb[index] - rgbMean
            let alphaDelta = alpha[alphaIndex] - alphaMean
            rgbCentered += rgbDelta * rgbDelta
            alphaCentered += alphaDelta * alphaDelta
            cross += rgbDelta * alphaDelta
        }
        // 近常数投影不能作为相关性证据，也不能进入近零除法。
        guard rgbCentered > 0.001, alphaCentered > 0.001 else { return -1 }
        return cross / sqrt(rgbCentered * alphaCentered)
    }


}
