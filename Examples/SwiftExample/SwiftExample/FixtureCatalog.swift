import Foundation

struct VAPFixture: Hashable {
    private static let expectedNegativeNames: Set<String> = ["2.mp4", "9.mp4", "u1.mp4", "u2.mp4", "u3.mp4"]

    let url: URL
    let byteCount: Int64

    var fileName: String { url.lastPathComponent }
    var identifier: String { url.deletingPathExtension().lastPathComponent }
    var shortIdentifier: String {
        let value = identifier
        guard value.count > 18 else { return value }
        return "\(value.prefix(10))…\(value.suffix(6))"
    }
    var formattedSize: String { ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file) }
    var looksLikeMedia: Bool { !Self.expectedNegativeNames.contains(fileName) }
    var numericID: Int { Int(identifier) ?? .max }
}

enum FixtureCatalog {
    static func scan(bundle: Bundle = .main) -> [VAPFixture] {
        var candidates = bundle.urls(forResourcesWithExtension: "mp4", subdirectory: "VAP") ?? []

        // Folder references normally preserve VAP/, while some Xcode configurations flatten resources.
        if candidates.isEmpty, let resourceURL = bundle.resourceURL,
           let enumerator = FileManager.default.enumerator(
               at: resourceURL,
               includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
               options: [.skipsHiddenFiles]
           ) {
            for case let url as URL in enumerator where url.pathExtension.lowercased() == "mp4" {
                candidates.append(url)
            }
        }

        var seen = Set<String>()
        return candidates.compactMap { url in
            let key = url.standardizedFileURL.path
            guard seen.insert(key).inserted else { return nil }
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values?.isRegularFile != false else { return nil }
            return VAPFixture(url: url, byteCount: Int64(values?.fileSize ?? 0))
        }.sorted {
            if $0.numericID != $1.numericID { return $0.numericID < $1.numericID }
            return $0.fileName.localizedStandardCompare($1.fileName) == .orderedAscending
        }
    }
}
