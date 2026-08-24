import UIKit
import VAPPlayerKit

enum GiftCatalog {
    static let replacementText = "Swift VAP Test"

    static func content(for source: SourceMetadata) -> DynamicContent {
        if source.kind == .text {
            return .textReplacement(replacementText)
        }
        if let gift = randomImage() {
            return .image(gift)
        }
        return .image(placeholder(size: source.slotSize, tag: source.tag))
    }

    static func randomImage(bundle: Bundle = .main) -> UIImage? {
        guard let url = imageURLs(bundle: bundle).randomElement() else { return nil }
        return UIImage(contentsOfFile: url.path)
    }

    static func imageURLs(bundle: Bundle = .main) -> [URL] {
        var candidates = bundle.urls(forResourcesWithExtension: "png", subdirectory: "Gifts") ?? []
        if candidates.isEmpty, let resourceURL = bundle.resourceURL,
           let enumerator = FileManager.default.enumerator(
               at: resourceURL,
               includingPropertiesForKeys: [.isRegularFileKey],
               options: [.skipsHiddenFiles]
           ) {
            for case let url as URL in enumerator where url.pathExtension.lowercased() == "png" {
                candidates.append(url)
            }
        }
        var seen = Set<String>()
        return candidates.filter { seen.insert($0.standardizedFileURL.path).inserted }
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
