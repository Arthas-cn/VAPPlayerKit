import ImageIO
import SDWebImage
import SDWebImageWebPCoder
import UIKit
import VAPPlayerKit

/// 为 Demo 的动态槽位提供 Bundle 图片和固定文案；UIKit 内容只在主线程构造。
@MainActor
enum GiftCatalog {
    /// 限制图片候选类型，用于对照静图和动图替换。
    enum ImagePolicy {
        /// 混合选择所有支持图片，保留目录预览的随机表现。
        case mixed
        /// 只选择 GIF、WebP，用于验证逐帧动态图片。
        case animatedOnly
        /// 只选择 PNG、JPEG，用于验证静态替换。
        case stillOnly
    }

    /// 缺少文案样本时使用的默认长文本。
    static let replacementText = "Swift VAP Test · 超长昵称用于验证文字跑马灯"

    /// 一组文案及它在选择器中的显示名称。
    struct ReplacementSample {
        /// 便于人工识别文案长度或类型的名称。
        let name: String
        /// 实际交给动态槽位的完整文本。
        let text: String
    }

    /// Playback Lab 用来对照截断 / 跑马灯的替换文字物料。
    static let replacementSamples: [ReplacementSample] = [
        ReplacementSample(
            name: "长昵称 · 溢出",
            text: replacementText
        ),
        ReplacementSample(
            name: "短文案 · 应静态",
            text: "VAP"
        ),
        ReplacementSample(
            name: "中等英文",
            text: "Swift VAP Test"
        ),
        ReplacementSample(
            name: "超长中英混合",
            text: "恭喜 Arthas 获得传说礼物「星河旅人」· Swift VAP Marquee · 这段文字用来观察无缝循环"
        ),
        ReplacementSample(
            name: "重复填充",
            text: String(repeating: "跑马灯滚动 ", count: 8)
        )
    ]

    /// 返回供选择器使用的数量；空目录仍保留默认项。
    static func replacementSampleCount() -> Int {
        max(replacementSamples.count, 1)
    }

    /// 循环归一化索引并返回名称，空数组显示占位。
    static func replacementSampleDisplayName(at index: Int) -> String {
        let samples = replacementSamples
        // 空集合无法做取模，保留明确占位名称。
        guard !samples.isEmpty else { return "无文案" }
        return samples[((index % samples.count) + samples.count) % samples.count].name
    }

    /// 循环归一化索引并返回文本，空数组回退到默认文案。
    static func replacementText(at index: Int) -> String {
        let samples = replacementSamples
        // 默认文案让空物料列表仍能验证文字槽位。
        guard !samples.isEmpty else { return replacementText }
        return samples[((index % samples.count) + samples.count) % samples.count].text
    }

    /// 混合模式允许的本地图片扩展名。
    private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp"]
    /// 可由 SDAnimatedImage 保留帧序列的格式。
    private static let animatedExtensions: Set<String> = ["gif", "webp"]
    /// 静图选择器允许的格式。
    private static let stillExtensions: Set<String> = ["png", "jpg", "jpeg"]
    /// 利用静态初始化保证 WebP coder 只注册一次。
    private static let webPCoderRegistration: Void = {
        SDImageCodersManager.shared.addCoder(SDImageWebPCoder.shared)
    }()

    /// 在读取 WebP 前确保其 coder 已注册。
    static func prepareImageCoders() {
        _ = webPCoderRegistration
    }

    /// 按槽位类型生成文本或本地图像；没有可用图片时返回可识别占位。
    static func content(
        for source: SourceMetadata,
        imagePolicy: ImagePolicy = .mixed,
        imageIndex: Int = 0,
        replacementIndex: Int = 0
    ) -> DynamicContent {
        // 文字槽位保留字符串语义，让 SDK 执行截断或跑马灯策略。
        if source.kind == .text {
            return .textReplacement(replacementText(at: replacementIndex))
        }
        // 真实本地图片优先，只有资源缺失或解码失败才用占位。
        if let gift = randomImage(policy: imagePolicy, tag: source.tag, imageIndex: imageIndex) {
            return .image(gift)
        }
        return .image(placeholder(size: source.slotSize, tag: source.tag))
    }

    /// 返回 Bundle 中可用动图候选的数量。
    static func animatedGiftCount(bundle: Bundle = .main) -> Int {
        giftCount(policy: .animatedOnly, bundle: bundle)
    }

    /// 返回 Bundle 中可用静图候选的数量。
    static func stillGiftCount(bundle: Bundle = .main) -> Int {
        giftCount(policy: .stillOnly, bundle: bundle)
    }

    /// 返回指定图片策略的候选数量。
    static func giftCount(policy: ImagePolicy, bundle: Bundle = .main) -> Int {
        imageURLs(bundle: bundle, policy: policy).count
    }

    /// 随机选择合法索引；空目录返回选择器默认值零。
    static func randomGiftIndex(policy: ImagePolicy, bundle: Bundle = .main) -> Int {
        let count = giftCount(policy: policy, bundle: bundle)
        // 空范围无法产生随机数，零由后续空目录分支处理。
        guard count > 0 else { return 0 }
        return Int.random(in: 0..<count)
    }

    /// 返回动图选择器当前样本名称。
    static func animatedGiftDisplayName(at index: Int, bundle: Bundle = .main) -> String {
        giftDisplayName(at: index, policy: .animatedOnly, empty: "无动图", bundle: bundle)
    }

    /// 返回静图选择器当前样本名称。
    static func stillGiftDisplayName(at index: Int, bundle: Bundle = .main) -> String {
        giftDisplayName(at: index, policy: .stillOnly, empty: "无静图", bundle: bundle)
    }

    /// 返回归一化索引对应的文件名，没有候选时返回调用者占位文案。
    static func giftDisplayName(
        at index: Int,
        policy: ImagePolicy,
        empty: String,
        bundle: Bundle = .main
    ) -> String {
        let urls = imageURLs(bundle: bundle, policy: policy)
        // 保留调用者区分动图、静图缺失的文案。
        guard !urls.isEmpty else { return empty }
        return urls[((index % urls.count) + urls.count) % urls.count].lastPathComponent
    }

    /// 专用策略按索引选图，混合策略随机尝试到首张可解码图片；失败返回 nil。
    static func randomImage(
        bundle: Bundle = .main,
        policy: ImagePolicy = .mixed,
        tag: String = "",
        imageIndex: Int = 0
    ) -> UIImage? {
        let urls = imageURLs(bundle: bundle, policy: policy)
        // 空目录交给上层占位，避免创建不存在的文件路径。
        guard !urls.isEmpty else { return nil }
        // 专用选择器要求切换索引后稳定重现同一张图。
        if policy != .mixed {
            let index = ((imageIndex % urls.count) + urls.count) % urls.count
            return image(at: urls[index])
        }
        for url in urls.shuffled() {
            // 混合模式跳过损坏图片，仍尝试剩余真实候选。
            if let image = image(at: url) {
                return image
            }
        }
        return nil
    }

    /// 扫描本地 Gifts 目录并兼容 Bundle 扁平复制，去重后按文件名排序。
    static func imageURLs(bundle: Bundle = .main, policy: ImagePolicy = .mixed) -> [URL] {
        let allowed: Set<String>
        switch policy {
        // 混合预览允许所有既有图片格式。
        case .mixed: allowed = imageExtensions
        // 动图对照只选能保留动画帧的格式。
        case .animatedOnly: allowed = animatedExtensions
        // 静图对照排除动画格式。
        case .stillOnly: allowed = stillExtensions
        }
        var candidates: [URL] = []
        // 优先保留 Gifts 目录的真实资源组织。
        if let giftsURL = bundle.url(forResource: "Gifts", withExtension: nil),
           let enumerator = FileManager.default.enumerator(
               at: giftsURL,
               includingPropertiesForKeys: [.isRegularFileKey],
               options: [.skipsHiddenFiles]
           ) {
            for case let url as URL in enumerator where allowed.contains(url.pathExtension.lowercased()) {
                candidates.append(url)
            }
        }

        // 个别 Bundle 复制方式无法枚举目录，补用资源查询接口。
        if candidates.isEmpty {
            for fileExtension in allowed {
                candidates.append(contentsOf: bundle.urls(forResourcesWithExtension: fileExtension, subdirectory: "Gifts") ?? [])
            }
        }

        // 部分 Xcode 配置会扁平复制文件，目录为空时再扫描 Bundle 根目录。
        if candidates.isEmpty, let resourceURL = bundle.resourceURL,
           let enumerator = FileManager.default.enumerator(
               at: resourceURL,
               includingPropertiesForKeys: [.isRegularFileKey],
               options: [.skipsHiddenFiles]
           ) {
            for case let url as URL in enumerator where allowed.contains(url.pathExtension.lowercased()) {
                candidates.append(url)
            }
        }

        var seen = Set<String>()
        return candidates.filter { seen.insert($0.standardizedFileURL.path).inserted }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// 优先交给 SDAnimatedImage，这样 GIF / 动画 WebP 会成为可动画 Image 对象。
    static func image(at url: URL) -> UIImage? {
        prepareImageCoders()
        // SDAnimatedImage 优先保留 GIF、WebP 的帧信息。
        if let animated = SDAnimatedImage(contentsOfFile: url.path), animated.size.width > 0, animated.size.height > 0 {
            return animated
        }
        // 系统支持的静图无需进入更底层 ImageIO 路径。
        if let image = UIImage(contentsOfFile: url.path), image.size.width > 0, image.size.height > 0 {
            return image
        }
        // 两种高级解码都失败后尝试首帧；仍失败则明确返回 nil。
        guard
            let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            CGImageSourceGetCount(source) > 0,
            let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }

    /// 为缺图槽位绘制带 tag 首字母的本地占位图。
    private static func placeholder(size: CGSize, tag: String) -> UIImage {
        let safeSize = CGSize(width: max(1, size.width), height: max(1, size.height))
        return UIGraphicsImageRenderer(size: safeSize).image { context in
            let colors = [
                UIColor(red: 0.15, green: 0.55, blue: 0.95, alpha: 1).cgColor,
                UIColor(red: 0.52, green: 0.22, blue: 0.92, alpha: 1).cgColor
            ] as CFArray
            // 渐变创建失败时仍可绘制字符，保证占位过程不抛错。
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
                context.cgContext.drawLinearGradient(
                    gradient,
                    start: .zero,
                    end: CGPoint(x: safeSize.width, y: safeSize.height),
                    options: []
                )
            }
            let symbol = String(tag.prefix(1)).uppercased()
            let font = UIFont.boldSystemFont(ofSize: min(safeSize.width, safeSize.height) * 0.42)
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.white]
            let measured = symbol.size(withAttributes: attributes)
            symbol.draw(
                at: CGPoint(x: (safeSize.width - measured.width) / 2, y: (safeSize.height - measured.height) / 2),
                withAttributes: attributes
            )
        }
    }
}
