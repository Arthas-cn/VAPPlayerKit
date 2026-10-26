import Foundation
import UIKit

/// 动态槽位解析后的可上传内容。组件不会保留原始 provider 回调对象。
enum ResolvedDynamicContent: Sendable {
    /// 已按槽位缩放的静图。
    case image(UIImage)
    /// 可动画图片：保留 provider 以便 session 期间驱动帧，同时缓存第一帧。
    case animated(AnimatedDynamicSlot)
    /// 溢出文字的跑马灯长条。session 期间滑动 UV 窗口。
    case marquee(MarqueeDynamicSlot)
    /// 本槽位本轮不渲染。
    case hidden
}

/// 一次 prepare 得到的全部动态槽位内容，按 vapc `srcId` 索引。
struct DynamicSnapshot: Sendable {
    /// 按素材 sourceID 索引的已准备覆盖内容，未传值的槽位保持隐藏。
    let contents: [String: ResolvedDynamicContent]

    /// 没有动态槽位时的空快照。
    static let empty = DynamicSnapshot(contents: [:])
}

/// 准备动态图片 / 文字。不进入视频解码线程，不发网络请求。
@MainActor
final class DynamicResolver {
    /// 当前请求强持有的提供者；不在准备期间切换为另一位业务消费者。
    var provider: (any DynamicContentProvider)?
    /// 递增的请求代次；迟到的 provider 结果不能进入下一轮纹理。
    private var generation: UInt64 = 0
    /// 正在执行的提供者任务；取消只是请求，排空仍等待真实返回。
    private var operations: [UUID: Task<ResolvedDynamicContent, Error>] = [:]
    /// 已触发截止时间的操作，用于区分主动取消与动态内容超时。
    private var timedOut: Set<UUID> = []

    /// 串行准备槽位，避免一个父加载名额再产生数百个并行解码任务。
    /// 超时会取消提供者；不合作的提供者仍由操作表持有直到返回。
    func resolve(
        sources: [VapcSource],
        timeout: TimeInterval = 8,
        imagePlayback: DynamicImagePlaybackMode = .animated,
        textOverflow: DynamicTextOverflowMode = .truncate
    ) async throws -> DynamicSnapshot {
        generation &+= 1
        let currentGeneration = generation
        var totalBytes = 0
        for source in sources {
            // 先检查全体槽位预算，再调用业务，防止已完成半份内容后才发现分配超额。
            guard let bytes = DynamicTextureLimits.byteCount(for: source.slotSize),
                  bytes <= DynamicTextureLimits.maximumBytesPerTexture,
                  totalBytes <= DynamicTextureLimits.maximumBytesPerSession - bytes else {
                throw PlaybackError.invalidVapc(reason: "Dynamic source textures exceed the allocation budget.")
            }
            totalBytes += bytes
        }
        var contents: [String: ResolvedDynamicContent] = [:]
        for source in sources {
            // 每个 await 后重验代次；clear 不会允许剩余槽位继续调用提供者。
            guard generation == currentGeneration, !Task.isCancelled else {
                throw CancellationError()
            }
            contents[source.id] = try await resolveOne(
                source, timeout: timeout, generation: currentGeneration,
                imagePlayback: imagePlayback, textOverflow: textOverflow
            )
        }
        return DynamicSnapshot(contents: contents)
    }

    /// 作废当前代次并请求全部提供者取消，不把取消意图当作实际任务结束。
    func cancel() {
        generation &+= 1
        for operation in operations.values { operation.cancel() }
    }

    /// 等待所有已进入的提供者真实退出；不能删文件或归还加载额度后再补等。
    func cancelAndWait() async {
        cancel()
        let pending = Array(operations.values)
        for operation in pending { _ = await operation.result }
    }

    /// 解析一个槽位并物化内容，操作任务和截止时间任务都有明确结束路径。
    private func resolveOne(
        _ source: VapcSource, timeout: TimeInterval, generation: UInt64,
        imagePlayback: DynamicImagePlaybackMode, textOverflow: DynamicTextOverflowMode
    ) async throws -> ResolvedDynamicContent {
        // 无提供者时保持视频底图；透明视频没有 source，自然不会进入这里。
        guard let provider else { return .hidden }
        let id = UUID()
        let metadata = SourceMetadata(tag: source.tag, slotSize: source.slotSize,
                                      kind: source.kind == .text ? .text : .image)
        let operation = Task { @MainActor in
            let content = try await provider.resolve(tag: source.tag, source: metadata)
            try Task.checkCancellation()
            return await self.materialize(content ?? .hidden, source: source,
                                          imagePlayback: imagePlayback, textOverflow: textOverflow)
        }
        operations[id] = operation
        let deadline = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(max(0.01, timeout))) }
            catch { return }
            // 截止时间只使结果失效；真正的 provider 返回仍是排空边界。
            self?.timedOut.insert(id)
            operation.cancel()
        }
        defer {
            deadline.cancel()
            operations[id] = nil
            timedOut.remove(id)
        }
        let result = await withTaskCancellationHandler {
            await operation.result
        } onCancel: { operation.cancel() }
        // 截止时间任务也持有 operation；等待其取消真实返回，避免排空后仍残留计时任务。
        deadline.cancel()
        await deadline.value
        // 超时优先于操作内部的 CancellationError，主动清理则按取消交还上层。
        if timedOut.contains(id) { throw PlaybackError.dynamicContentTimeout }
        guard self.generation == generation, !Task.isCancelled else { throw CancellationError() }
        return try result.get()
    }

    /// 把宿主返回的 `DynamicContent` 栅格化成可上传纹理。
    private func materialize(
        _ content: DynamicContent,
        source: VapcSource,
        imagePlayback: DynamicImagePlaybackMode,
        textOverflow: DynamicTextOverflowMode
    ) async -> ResolvedDynamicContent {
        // 所有分支都走 UIKit 绘制。串行化到本 @MainActor，避免真机上图片和 TextKit 并发渲染死锁。
        switch content {
        // 隐藏和未覆盖都保留视频底图，不分配占位纹理。
        case .hidden:
            return .hidden
        // 图片只物化宿主已提供的数据，不在内核补做网络下载。
        case .image(let image):
            return Self.resolveImage(image, source: source, imagePlayback: imagePlayback)
        // 显式文字属性优先于素材默认样式。
        case .text(let text, let attributes):
            return Self.resolveText(text, attributes: attributes, source: source, overflow: textOverflow)
        // 仅替换文字时才合并素材槽位样式与可选字体。
        case .textReplacement(let text):
            return Self.resolveText(
                text,
                attributes: Self.replacementTextAttributes(text, source: source, font: self.font(for: source)),
                source: source,
                overflow: textOverflow
            )
        }
    }

    /// 静图直接缩放；若是 SDAnimatedImage 且允许动图，则保留 provider 供 session 驱动。
    static func resolveImage(
        _ image: UIImage,
        source: VapcSource,
        imagePlayback: DynamicImagePlaybackMode
    ) -> ResolvedDynamicContent {
        let stillSource: UIImage
        if SDWebImageRuntime.isAnimatedImage(image), let firstFrame = SDWebImageRuntime.frame(of: image, at: 0) {
            stillSource = firstFrame
        } else {
            stillSource = image
        }
        let stillFrame = resized(stillSource, source: source)
        if imagePlayback == .animated, SDWebImageRuntime.isAnimatedImage(image) {
            return .animated(AnimatedDynamicSlot(provider: image, firstFrame: stillFrame, source: source))
        }
        return .image(stillFrame)
    }

    /// 从本次强持有的 Swift 提供者取得字体，未提供时使用自动样式。
    private func font(for source: VapcSource) -> UIFont? {
        provider?.font(forTag: source.tag)
    }

    /// 把 `.textReplacement` / `.text` 画成槽位纹理。放得下则居中；溢出则按 truncate / marquee。
    static func resolveText(
        _ text: String,
        attributes: TextAttributes,
        source: VapcSource,
        overflow: DynamicTextOverflowMode
    ) -> ResolvedDynamicContent {
        let measured = singleLineSize(text, attributes: attributes)
        if measured.width <= source.slotSize.width {
            return .image(rasterizedText(text, attributes: attributes, source: source))
        }
        if overflow == .marquee, let slot = rasterizedMarqueeSlot(text, attributes: attributes, source: source) {
            return .marquee(slot)
        }
        return .image(
            rasterizedText(
                text,
                attributes: attributes,
                source: source,
                lineBreakMode: .byTruncatingTail
            )
        )
    }

    /// 单行测量，与 `draw(at:)` 使用同一套属性，避免 boundingRect 换行。
    private static func singleLineSize(_ text: String, attributes: TextAttributes) -> CGSize {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .left
        paragraph.lineBreakMode = .byClipping
        return (text as NSString).size(withAttributes: [
            .font: attributes.font,
            .foregroundColor: attributes.color,
            .paragraphStyle: paragraph
        ])
    }

    /// 预绘 `[文字][间隙][文字]` 长条。超出纹理预算时返回 nil，调用方回退截断。
    private static func rasterizedMarqueeSlot(
        _ text: String,
        attributes: TextAttributes,
        source: VapcSource
    ) -> MarqueeDynamicSlot? {
        let measured = singleLineSize(text, attributes: attributes)
        let textWidth = max(1, ceil(measured.width))
        let gap = ceil(MarqueeLayout.gap(slotWidth: source.slotSize.width))
        let slotHeight = max(1, source.slotSize.height.rounded())
        let stripSize = MarqueeLayout.stripSize(textWidth: textWidth, gap: gap, slotHeight: slotHeight)
        guard MarqueeLayout.canAllocateStrip(size: stripSize) else { return nil }
        let slotWidth = CGFloat(max(1, Int(source.slotSize.width.rounded())))
        let image = renderPremultipliedImage(size: stripSize) {
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .left
            paragraph.lineBreakMode = .byClipping
            let drawingAttributes: [NSAttributedString.Key: Any] = [
                .font: attributes.font,
                .foregroundColor: attributes.color,
                .paragraphStyle: paragraph
            ]
            let attributed = NSAttributedString(string: text, attributes: drawingAttributes)
            let y = max(0, (slotHeight - measured.height) / 2)
            attributed.draw(at: CGPoint(x: 0, y: y))
            attributed.draw(at: CGPoint(x: textWidth + gap, y: y))
        }
        guard image.size.width > 0, image.size.height > 0 else { return nil }
        return MarqueeDynamicSlot(
            strip: image,
            slotWidth: slotWidth,
            cycleWidth: textWidth + gap,
            textureWidth: image.size.width
        )
    }

    /// 测试缝：确认字符串替换路径真正消费了 vapc 的颜色 / 字重，而不只是画出正确尺寸的图。
    static func replacementTextAttributes(
        _ text: String,
        source: VapcSource,
        font: UIFont? = nil
    ) -> TextAttributes {
        let color = textColor(source.color) ?? .white
        if let font {
            return TextAttributes(font: font, color: color)
        }
        let isBold = source.style?.localizedCaseInsensitiveContains("b") == true
        let fontSize = fittedFontSize(text: text, source: source, bold: isBold)
        let font = isBold
            ? UIFont.boldSystemFont(ofSize: fontSize)
            : UIFont.systemFont(ofSize: fontSize)
        return TextAttributes(font: font, color: color)
    }

    /// vapc 只有槽位尺寸、颜色和粗粒度样式，没有字体文件或精确字号。
    /// 系统字体最多缩小三次，仍放不下时按 `dynamicTextOverflowMode` 截断或跑马灯。
    private static func fittedFontSize(text: String, source: VapcSource, bold: Bool) -> CGFloat {
        guard !text.isEmpty else { return 1 }
        var candidate = min(max(source.slotSize.height, 1), 50)
        for attempt in 0...3 {
            let font = bold ? UIFont.boldSystemFont(ofSize: candidate) : UIFont.systemFont(ofSize: candidate)
            let size = (text as NSString).size(withAttributes: [.font: font])
            if size.width <= source.slotSize.width, size.height <= source.slotSize.height {
                return candidate
            }
            guard attempt < 3 else { break }
            candidate *= 0.80
        }
        return max(1, candidate)
    }

    /// 解析 `#RRGGBB` / `#AARRGGBB`。非法值返回 nil，调用方回退白色。
    private static func textColor(_ value: String?) -> UIColor? {
        guard var value, value.hasPrefix("#") else { return nil }
        value.removeFirst()
        guard let number = UInt64(value, radix: 16) else { return nil }
        switch value.count {
        // RGB 未携带透明度，按完全不透明解释。
        case 6:
            return UIColor(
                red: CGFloat((number >> 16) & 0xff) / 255,
                green: CGFloat((number >> 8) & 0xff) / 255,
                blue: CGFloat(number & 0xff) / 255,
                alpha: 1
            )
        // 八位格式把最高字节作为 Alpha，不能按 RGBA 交换末尾字节。
        case 8:
            return UIColor(
                red: CGFloat((number >> 16) & 0xff) / 255,
                green: CGFloat((number >> 8) & 0xff) / 255,
                blue: CGFloat(number & 0xff) / 255,
                alpha: CGFloat((number >> 24) & 0xff) / 255
            )
        // 不接受缩写或未知位数，交给调用方统一回退文字颜色。
        default:
            return nil
        }
    }

    /// 在槽位尺寸上居中绘制文字。截断模式画单行；否则按实际字形尺寸居中。
    private static func rasterizedText(
        _ text: String,
        attributes textAttributes: TextAttributes,
        source: VapcSource,
        lineBreakMode: NSLineBreakMode = .byWordWrapping
    ) -> UIImage {
        return renderPremultipliedImage(size: source.slotSize) {
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            paragraph.lineBreakMode = lineBreakMode
            let attributes: [NSAttributedString.Key: Any] = [
                .font: textAttributes.font,
                .foregroundColor: textAttributes.color,
                .paragraphStyle: paragraph
            ]
            let attributed = NSAttributedString(string: text, attributes: attributes)
            if lineBreakMode == .byTruncatingTail {
                let lineHeight = textAttributes.font.lineHeight
                attributed.draw(
                    with: CGRect(
                        x: 0,
                        y: max(0, (source.slotSize.height - lineHeight) / 2),
                        width: source.slotSize.width,
                        height: lineHeight
                    ),
                    options: [.usesLineFragmentOrigin, .usesFontLeading],
                    context: nil
                )
                return
            }
            // `draw(at:)` 是单行绘制，必须按同样布局测量。
            // 若用槽位约束的 boundingRect，可能允许换行，导致实际单行字形被裁切。
            let bounds = (text as NSString).size(withAttributes: attributes)
            attributed.draw(at: CGPoint(
                x: max(0, (source.slotSize.width - bounds.width) / 2),
                y: max(0, (source.slotSize.height - bounds.height) / 2)
            ))
        }
    }

    /// 按槽位做 AspectFill 居中缩放，保持预乘透明。
    static func resized(_ image: UIImage, source: VapcSource) -> UIImage {
        return renderPremultipliedImage(size: source.slotSize) {
            let target: CGRect
            if image.size.width > 0, image.size.height > 0 {
                let scale = max(
                    source.slotSize.width / image.size.width,
                    source.slotSize.height / image.size.height
                )
                let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
                target = CGRect(
                    x: (source.slotSize.width - size.width) / 2,
                    y: (source.slotSize.height - size.height) / 2,
                    width: size.width,
                    height: size.height
                )
            } else {
                target = CGRect(origin: .zero, size: source.slotSize)
            }
            image.draw(in: target, blendMode: .normal, alpha: 1)
        }
    }

    /// 画到 8-bit 预乘 RGBA bitmap，保证透明像素保持透明。
    /// `UIGraphicsImageRenderer` 可能产出扩展色域图，其 `cgImage` 会把 alpha 拍成不透明槽位。
    private static func renderPremultipliedImage(size: CGSize, draw: () -> Void) -> UIImage {
        let width = max(1, Int(size.width.rounded()))
        let height = max(1, Int(size.height.rounded()))
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo
        ) else {
            return UIImage()
        }
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        UIGraphicsPushContext(context)
        draw()
        UIGraphicsPopContext()
        guard let cgImage = context.makeImage() else { return UIImage() }
        return UIImage(cgImage: cgImage, scale: 1, orientation: .up)
    }
}
