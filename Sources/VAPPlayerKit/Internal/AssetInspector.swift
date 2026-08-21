import Foundation
import CoreGraphics

/// 将本地文件转换为不可变 `AssetMetadata`。只在后台运行，结果不得夹带 parser cursor 或文件句柄。
///
/// 对照 `vap-master` 的 `QGMP4Parser` + `QGVAPConfigManager`。Phase 0 只打通错误映射。
final class AssetInspector {
    /// 校验 file URL 与文件存在性。Phase 1 将解析 moov / vapc / sample table。
    func inspect(url: URL) async throws -> AssetMetadata {
        guard url.isFileURL else {
            throw PlaybackError.invalidURL
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw PlaybackError.fileNotFound
        }

        // Phase 1 will parse moov / vapc and emit immutable metadata.
        // Phase 0 only proves the inspect pipeline and error mapping compile.
        throw PlaybackError.invalidMP4(reason: "AssetInspector is a Phase 1 parser stub.")
    }
}
