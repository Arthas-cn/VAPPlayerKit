import Foundation

/// 定位仓库内提交的 VAP 样例。路径相对本测试源文件，不依赖 main bundle。
enum VAPFixture {
    /// 默认 Demo / 冒烟测试使用的最小合法 H.264 文件。
    static let defaultPlayableName = "18.mp4"

    /// 内容为 AccessDenied XML 的负向样例。
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

    static var defaultPlayableURL: URL {
        url(defaultPlayableName)
    }

    static var allMP4URLs: [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ))?
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
