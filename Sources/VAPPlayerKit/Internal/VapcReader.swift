import Foundation
import CoreGraphics

/// 解析后的 vapc 文档子集。后续会补 source tag、层级和混合参数。
struct VapcDocument {
    /// vapc 版本。未知版本必须失败，不能静默猜测。
    let version: Int
    /// 逻辑画布。
    let canvasSize: CGSize
    /// packed Alpha 布局。
    let alphaMode: AlphaMode
}

/// 读取 MP4 中的 vapc box。对照 `vap-master/tool` 的 JSON 描述和 iOS `QGVAPConfigModel`。
final class VapcReader {
    /// Phase 0 stub。非法数据必须返回 `invalidVapc`，禁止按尺寸无限猜测。
    func read(from data: Data) throws -> VapcDocument {
        throw PlaybackError.invalidVapc(reason: "VapcReader is a Phase 1 parser stub.")
    }
}
