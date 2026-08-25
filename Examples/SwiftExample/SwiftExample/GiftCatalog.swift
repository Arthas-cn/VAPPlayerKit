import ImageIO
import SDWebImage
import SDWebImageWebPCoder
import UIKit
import VAPPlayerKit

enum GiftCatalog {
    enum ImagePolicy {
        case mixed
        case animatedOnly
    }

    static let replacementText = "Swift VAP Test"
    private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp"]
    private static let animatedExtensions: Set<String> = ["gif", "webp"]
    private static let webPCoderRegistration: Void = {
        SDImageCodersManager.shared.addCoder(SDImageWebPCoder.shared)
    }()

    static func prepareImageCoders() {
        _ = webPCoderRegistration
    }

    static func content(
        for source: SourceMetadata,
        imagePolicy: ImagePolicy = .mixed,
        animatedIndex: Int = 0
    ) -> DynamicContent {
        if source.kind == .text {
            return .textReplacement(replacementText)
        }
        if let gift = randomImage(policy: imagePolicy, tag: source.tag, animatedIndex: animatedIndex) {
            return .image(gift)
        }
        return .image(placeholder(size: source.slotSize, tag: source.tag))
    }

    static func animatedGiftCount(bundle: Bundle = .main) -> Int {
        imageURLs(bundle: bundle, policy: .animatedOnly).count
    }

    static func animatedGiftDisplayName(at index: Int, bundle: Bundle = .main) -> String {
        let urls = imageURLs(bundle: bundle, policy: .animatedOnly)
        guard !urls.isEmpty else { return "无动图" }
        return urls[((index % urls.count) + urls.count) % urls.count].lastPathComponent
    }

    static func randomImage(
        bundle: Bundle = .main,
        policy: ImagePolicy = .mixed,
        tag: String = "",
        animatedIndex: Int = 0
    ) -> UIImage? {
        let urls = imageURLs(bundle: bundle, policy: policy)
        guard !urls.isEmpty else { return nil }
        if policy == .animatedOnly {
            let index = ((animatedIndex % urls.count) + urls.count) % urls.count
            return image(at: urls[index])
        }
        for url in urls.shuffled() {
            if let image = image(at: url) {
                return image
            }
        }
        return nil
    }

    static func imageURLs(bundle: Bundle = .main, policy: ImagePolicy = .mixed) -> [URL] {
        let allowed = policy == .animatedOnly ? animatedExtensions : imageExtensions
        var candidates: [URL] = []
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

        if candidates.isEmpty {
            for fileExtension in allowed {
                candidates.append(contentsOf: bundle.urls(forResourcesWithExtension: fileExtension, subdirectory: "Gifts") ?? [])
            }
        }

        // Folder references normally preserve Gifts/, while some Xcode configurations flatten resources.
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
        if let animated = SDAnimatedImage(contentsOfFile: url.path), animated.size.width > 0, animated.size.height > 0 {
            return animated
        }
        if let image = UIImage(contentsOfFile: url.path), image.size.width > 0, image.size.height > 0 {
            return image
        }
        guard
            let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            CGImageSourceGetCount(source) > 0,
            let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }

    private static func placeholder(size: CGSize, tag: String) -> UIImage {
        let safeSize = CGSize(width: max(1, size.width), height: max(1, size.height))
        return UIGraphicsImageRenderer(size: safeSize).image { context in
            let colors = [
                UIColor(red: 0.15, green: 0.55, blue: 0.95, alpha: 1).cgColor,
                UIColor(red: 0.52, green: 0.22, blue: 0.92, alpha: 1).cgColor
            ] as CFArray
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
