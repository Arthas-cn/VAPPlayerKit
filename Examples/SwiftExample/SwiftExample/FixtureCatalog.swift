import Foundation

struct VAPFixture: Hashable {
    private static let expectedNegativeNames: Set<String> = [
        "0f691eda3e82a2808e38f34be2e80efde45d4b66084a7e3e80cbd7a9a209c23d.mp4",
        "38c168451bbfe1b792e84067260011202452d7b04ac762a0c2c0d1e0acd2377f.mp4"
    ]

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
            if $0.looksLikeMedia != $1.looksLikeMedia { return $0.looksLikeMedia && !$1.looksLikeMedia }
            if $0.byteCount != $1.byteCount { return $0.byteCount < $1.byteCount }
            return $0.fileName.localizedStandardCompare($1.fileName) == .orderedAscending
        }
    }
}
