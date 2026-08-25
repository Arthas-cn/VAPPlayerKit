import Foundation

enum VAPFixture {
    static let defaultPlayableName = "18.mp4"

    static let invalidXMLNames = ["2.mp4", "9.mp4"]

    static var directory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/VAP", isDirectory: true)
    }

    static func url(_ fileName: String) -> URL {
        directory.appendingPathComponent(fileName)
    }

    static var allMP4URLs: [URL] {
        (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension.lowercased() == "mp4" }
            .sorted { numericID($0) < numericID($1) } ?? []
    }

    static var playableURLs: [URL] {
        let invalid = Set(invalidXMLNames)
        return allMP4URLs.filter { !invalid.contains($0.lastPathComponent) }
    }

    private static func numericID(_ url: URL) -> Int {
        Int(url.deletingPathExtension().lastPathComponent) ?? .max
    }
}
