import UIKit

enum GiftCatalog {
    static let replacementText = "Swift VAP Test"

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
}
