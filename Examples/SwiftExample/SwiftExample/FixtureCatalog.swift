import Foundation

/// Bundle 中的本地测试样本值；路径与大小可安全交给异步基准任务。
struct VAPFixture: Hashable, Sendable {
    /// 已知损坏样本的固定名单，目录顺序与自动化预期保持不变。
    private static let expectedNegativeNames: Set<String> = ["2.mp4", "9.mp4", "u1.mp4", "u2.mp4", "u3.mp4"]

    /// 当前 Bundle 内现存资源的本地 URL。
    let url: URL
    /// 扫描时取得的文件字节数，读取失败时为 0。
    let byteCount: Int64

    /// 含扩展名的原始名称，供列表与错误报告使用。
    var fileName: String { url.lastPathComponent }
    /// 去掉扩展名的目录身份，保留现有 UI 测试查找语义。
    var identifier: String { url.deletingPathExtension().lastPathComponent }
    /// 缩略显示长名称，不改变真实文件身份。
    var shortIdentifier: String {
        let value = identifier
        // 短名称保持完整，只有长 Hash 才省略中段。
        guard value.count > 18 else { return value }
        return "\(value.prefix(10))…\(value.suffix(6))"
    }
    /// 人类可读的文件大小，只用于展示。
    var formattedSize: String { ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file) }
    /// 是否应该通过播放验证；只由正式负向样本名单决定。
    var looksLikeMedia: Bool { !Self.expectedNegativeNames.contains(fileName) }
    /// 数字文件优先按数值排序，其他名称放在其后。
    var numericID: Int { Int(identifier) ?? .max }
}

/// 扫描既有 Bundle/VAP 目录，不创建或下载测试素材。
enum FixtureCatalog {
    /// 返回按既有规则排序、路径去重的样本；找不到资源时返回空数组。
    static func scan(bundle: Bundle = .main) -> [VAPFixture] {
        var candidates = bundle.urls(forResourcesWithExtension: "mp4", subdirectory: "VAP") ?? []

        // 文件夹引用保留 VAP/；只有目录未找到时才兼容旧工程的资源扁平化。
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
            // 同一路径只计入一次，避免资源同时被两种扫描方式发现。
            guard seen.insert(key).inserted else { return nil }
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            // 目录不能冒充 MP4；旧扫描允许未知文件属性，以保留既有测试数量。
            guard values?.isRegularFile != false else { return nil }
            return VAPFixture(url: url, byteCount: Int64(values?.fileSize ?? 0))
        }.sorted {
            // 数字样本的稳定顺序保持既有目录与自动化定位。
            if $0.numericID != $1.numericID { return $0.numericID < $1.numericID }
            return $0.fileName.localizedStandardCompare($1.fileName) == .orderedAscending
        }
    }
}
