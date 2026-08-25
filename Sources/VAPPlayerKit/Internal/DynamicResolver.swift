import Foundation
import UIKit

/// 动态槽位解析后的可上传内容。组件不会保留原始 provider 回调对象。
enum ResolvedDynamicContent: @unchecked Sendable {
    /// 已按槽位缩放的静图。
    case image(UIImage)
    /// 可动画图片：保留 provider 以便 session 期间驱动帧，同时缓存第一帧。
    case animated(AnimatedDynamicSlot)
    /// 本槽位本轮不渲染。
    case hidden
}

/// 一次 prepare 得到的全部动态槽位内容，按 vapc `srcId` 索引。
struct DynamicSnapshot: @unchecked Sendable {
    let contents: [String: ResolvedDynamicContent]

    /// 没有动态槽位时的空快照。
    static let empty = DynamicSnapshot(contents: [:])
}

/// 准备动态图片 / 文字。不进入视频解码线程，不发网络请求。
@MainActor
final class DynamicResolver {
    /// Swift provider。与 ObjC provider 同时存在时优先 Swift。
    weak var provider: DynamicContentProvider?
    weak var objcProvider: ObjCDynamicContentProvider?
    /// 递增代数。新的 resolve / cancel 会使进行中的 completion 失效。
    private var generation: UInt64 = 0
    /// 尚未收口的 completion gate，cancel 时统一失败。
    private var activeGates: [UUID: DynamicResolutionGate] = [:]

    /// 并行解析全部 source。无 provider 时全部 hidden；超时抛 `dynamicContentTimeout`。
    func resolve(
        sources: [VapcSource],
        timeout: TimeInterval = 8,
        imagePlayback: DynamicImagePlaybackMode = .animated
    ) async throws -> DynamicSnapshot {
        generation &+= 1
        let currentGeneration = generation
        guard !sources.isEmpty else { return .empty }
        var totalBytes = 0
        for source in sources {
            guard
                let bytes = DynamicTextureLimits.byteCount(for: source.slotSize),
                bytes <= DynamicTextureLimits.maximumBytesPerTexture,
                totalBytes <= DynamicTextureLimits.maximumBytesPerSession - bytes
            else {
                throw PlaybackError.invalidVapc(reason: "Dynamic source textures exceed the allocation budget.")
            }
            totalBytes += bytes
        }
        guard provider != nil || objcProvider != nil else {
            return DynamicSnapshot(contents: Dictionary(uniqueKeysWithValues: sources.map { ($0.id, .hidden) }))
        }

        return try await withThrowingTaskGroup(of: (String, ResolvedDynamicContent).self) { group in
            for source in sources {
                group.addTask { @MainActor [weak self] in
                    guard let self, self.generation == currentGeneration else {
                        throw PlaybackError.cancelled
                    }
                    let content = try await self.resolveOne(
                        source,
                        timeout: timeout,
                        generation: currentGeneration,
                        imagePlayback: imagePlayback
                    )
                    return (source.id, content)
                }
            }
            var result: [String: ResolvedDynamicContent] = [:]
            for try await (id, content) in group {
                result[id] = content
            }
            return DynamicSnapshot(contents: result)
        }
    }

    /// 作废进行中的 provider 回调，使后续 completion 全部按 cancelled 收口。
    func cancel() {
        generation &+= 1
        let gates = activeGates.values
        activeGates.removeAll()
        for gate in gates {
            gate.finish(.failure(PlaybackError.cancelled))
        }
    }

    /// 解析单个 source：调用 provider，并用超时 Task 兜底。completion 必须且只能生效一次。
    private func resolveOne(
        _ source: VapcSource,
        timeout: TimeInterval,
        generation: UInt64,
        imagePlayback: DynamicImagePlaybackMode
    ) async throws -> ResolvedDynamicContent {
        let metadata = SourceMetadata(
            tag: source.tag,
            slotSize: source.slotSize,
            kind: source.kind == .text ? .text : .image
        )
        let gate = DynamicResolutionGate()
        let gateID = UUID()
        activeGates[gateID] = gate
        defer { activeGates[gateID] = nil }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                gate.install(continuation)
                if let provider {
                    provider.resolve(tag: source.tag, source: metadata) { content, error in
                        Task { @MainActor [weak self] in
                            guard let self, self.generation == generation else {
                                gate.finish(.failure(PlaybackError.cancelled))
                                return
                            }
                            if let error {
                                gate.finish(.failure(error))
                            } else {
                                let resolved = await self.materialize(
                                    content ?? .hidden,
                                    source: source,
                                    imagePlayback: imagePlayback
                                )
                                guard self.generation == generation else {
                                    gate.finish(.failure(PlaybackError.cancelled))
                                    return
                                }
                                gate.finish(.success(resolved))
                            }
                        }
                    }
                } else if let objcProvider {
                    objcProvider.resolveTag(source.tag, source: metadata) { [weak self] image, replacementText, error in
                        Task { @MainActor in
                            guard let self, self.generation == generation else {
                                gate.finish(.failure(PlaybackError.cancelled))
                                return
                            }
                            if let error {
                                gate.finish(.failure(error))
                            } else if let replacementText {
                                let resolved = await self.materialize(
                                    .textReplacement(replacementText),
                                    source: source,
                                    imagePlayback: imagePlayback
                                )
                                guard self.generation == generation else {
                                    gate.finish(.failure(PlaybackError.cancelled))
                                    return
                                }
                                gate.finish(.success(resolved))
                            } else if let image {
                                let resolved = await self.materialize(
                                    .image(image),
                                    source: source,
                                    imagePlayback: imagePlayback
                                )
                                guard self.generation == generation else {
                                    gate.finish(.failure(PlaybackError.cancelled))
                                    return
                                }
                                gate.finish(.success(resolved))
                            } else {
                                gate.finish(.success(.hidden))
                            }
                        }
                    }
                }
                Task {
                    try? await Task.sleep(nanoseconds: UInt64(max(0.01, timeout) * 1_000_000_000))
                    gate.finish(.failure(PlaybackError.dynamicContentTimeout))
                }
            }
        } onCancel: {
            gate.finish(.failure(PlaybackError.cancelled))
        }
    }

    /// 把宿主返回的 `DynamicContent` 栅格化成可上传纹理。`imageURL` 视为 hidden，组件不下载。
    private func materialize(
        _ content: DynamicContent,
        source: VapcSource,
        imagePlayback: DynamicImagePlaybackMode
    ) async -> ResolvedDynamicContent {
        // 所有分支都走 UIKit 绘制。串行化到本 @MainActor，避免真机上图片和 TextKit 并发渲染死锁。
        switch content {
        case .hidden, .imageURL:
            return .hidden
        case .image(let image):
            return Self.resolveImage(image, source: source, imagePlayback: imagePlayback)
        case .text(let text, let attributes):
            return .image(Self.rasterizedText(text, attributes: attributes, source: source))
        case .textReplacement(let text):
            return .image(Self.rasterizedReplacementText(text, source: source, font: self.font(for: source)))
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

    /// 优先问 Swift provider 的 `font(forTag:)`，否则问 ObjC 可选方法。
    private func font(for source: VapcSource) -> UIFont? {
        if let provider {
            return provider.font(forTag: source.tag)
        }
        return objcProvider?.fontForTag?(source.tag)
    }

    /// 把 `.textReplacement` 绘制到槽位尺寸的预乘纹理，过宽时尾部截断。
    private static func rasterizedReplacementText(
        _ text: String,
        source: VapcSource,
        font: UIFont?
    ) -> UIImage {
        let attributes = replacementTextAttributes(text, source: source, font: font)
        return rasterizedText(
            text,
            attributes: attributes,
            source: source,
            lineBreakMode: .byTruncatingTail
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
    /// 系统字体最多缩小三次，仍放不下时交给 UIKit 尾部截断。
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
        case 6:
            return UIColor(
                red: CGFloat((number >> 16) & 0xff) / 255,
                green: CGFloat((number >> 8) & 0xff) / 255,
                blue: CGFloat(number & 0xff) / 255,
                alpha: 1
            )
        case 8:
            return UIColor(
                red: CGFloat((number >> 16) & 0xff) / 255,
                green: CGFloat((number >> 8) & 0xff) / 255,
                blue: CGFloat(number & 0xff) / 255,
                alpha: CGFloat((number >> 24) & 0xff) / 255
            )
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

/// 保证 provider completion、超时和 cancel 三路只会 resume 一次 continuation。
private final class DynamicResolutionGate {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<ResolvedDynamicContent, Error>?
    private var result: Result<ResolvedDynamicContent, Error>?
    private var completed = false

    /// 安装 continuation。若结果已先到，立即 resume。
    func install(_ continuation: CheckedContinuation<ResolvedDynamicContent, Error>) {
        let pending: Result<ResolvedDynamicContent, Error>? = lock.withLock {
            if let result { return result }
            self.continuation = continuation
            return nil
        }
        if let pending { continuation.resume(with: pending) }
    }

    /// 第一次调用生效；后续超时 / cancel / provider 重复回调都被忽略。
    func finish(_ result: Result<ResolvedDynamicContent, Error>) {
        let continuation: CheckedContinuation<ResolvedDynamicContent, Error>? = lock.withLock {
            guard !completed else { return nil }
            completed = true
            guard let continuation = self.continuation else {
                self.result = result
                return nil
            }
            self.continuation = nil
            return continuation
        }
        continuation?.resume(with: result)
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
