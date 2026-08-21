import Foundation

/// 定位仓库内提交的 VAP 样例。路径相对本测试源文件，不依赖 main bundle。
enum VAPFixture {
    /// 默认 Demo / 冒烟测试使用的最小合法 H.264 文件。
    static let defaultPlayableName = "e9b6b7196780ea5f64b9f05034571f12a96787278ed678c83141c7913af7318a.mp4"

    /// 内容为 AccessDenied XML 的负向样例。
    static let invalidXMLNames = [
        "0f691eda3e82a2808e38f34be2e80efde45d4b66084a7e3e80cbd7a9a209c23d.mp4",
        "38c168451bbfe1b792e84067260011202452d7b04ac762a0c2c0d1e0acd2377f.mp4"
    ]

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
        .sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []
    }
}
