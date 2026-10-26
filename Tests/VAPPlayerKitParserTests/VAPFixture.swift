import Foundation

/// 定位解析测试使用的正式素材与负向样例，不依赖构建主机路径。
enum VAPFixture {
    /// 默认采用最小合法 H.264 素材，减少非目标解码开销。
    static let defaultPlayableName = "18.mp4"

    /// 扩展名虽为 MP4、内容实际为拒绝访问 XML 的负向样例。
    static let invalidXMLNames = ["2.mp4", "9.mp4", "u1.mp4", "u2.mp4", "u3.mp4"]

    /// 只返回当前 bundle 确实存在的负向资源，供目录断言使用。
    static var existingInvalidXMLNames: [String] {
        invalidXMLNames.filter { FileManager.default.fileExists(atPath: url($0).path) }
    }

    /// 随测试目标打包的真实 fixture 目录，不依赖主机源码的绝对路径。
    static var directory: URL {
        Bundle.module.bundleURL.appendingPathComponent("VAP", isDirectory: true)
    }

    /// 拼接测试 bundle 内的文件 URL，不替测试创建或下载缺失资源。
    static func url(_ fileName: String) -> URL {
        directory.appendingPathComponent(fileName)
    }

    /// 扫描 bundle 中所有 MP4 后缀文件，数字 ID 优先稳定排序。
    static var allMP4URLs: [URL] {
        (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension.lowercased() == "mp4" }
            .sorted { numericID($0) < numericID($1) } ?? []
    }

    /// 排除已知 XML 假文件后保留全部应能真实播放的素材。
    static var playableURLs: [URL] {
        let invalid = Set(invalidXMLNames)
        return allMP4URLs.filter { !invalid.contains($0.lastPathComponent) }
    }

    /// 当前 bundle 中存在的补充场景，保持精简 fixture 环境可运行。
    static var optionalFixtureNames: [String] {
        ["home.mp4", "nationalDayEffect.mp4", "nation.mp4", "movie01.mp4", "movie02.mp4", "u1.mp4", "u2.mp4", "u3.mp4"].filter {
            FileManager.default.fileExists(atPath: url($0).path)
        }
    }

    /// 数字文件按 ID 排列，具名资源放在数字之后。
    private static func numericID(_ url: URL) -> Int {
        Int(url.deletingPathExtension().lastPathComponent) ?? .max
    }
}
