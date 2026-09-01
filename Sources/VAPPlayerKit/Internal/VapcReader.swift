import Foundation
import CoreGraphics

/// vapc 里一个动态 source 槽位。对照 JSON `src` 数组元素。
struct VapcSource: Sendable {
    /// vapc `srcType`：`img` 或 `txt`。
    enum Kind: String, Sendable {
        case image = "img"
        case text = "txt"
    }

    /// JSON `srcId`，attachment 通过它引用本槽位。
    let id: String
    /// 图片或文字。
    let kind: Kind
    /// 宿主 provider 用来查内容的 tag。
    let tag: String
    /// 预缩放目标像素尺寸。
    let slotSize: CGSize
    /// vapc `loadType`，组件不解释下载语义。
    let loadType: String
    /// vapc `fitType`，当前渲染路径按槽位 AspectFill。
    let fitType: String
    /// 文字颜色，例如 `#RRGGBB`。
    let color: String?
    /// 粗体等粗粒度样式标记。
    let style: String?
}

/// 某一视频帧上的一个动态 overlay。
struct VapcAttachment: Sendable {
    /// 对应 `VapcSource.id`。
    let sourceID: String
    /// 决定走打孔+overlay 还是仅 overlay。
    let kind: VapcSource.Kind
    /// 绘制顺序，升序表示更靠上。
    let zIndex: Int
    /// 落在逻辑画布上的矩形。
    let renderRect: CGRect
    /// packed 视频里作为 mask 的区域。
    let maskRect: CGRect
    /// mask 旋转角度，仅处理 0/90/180/270。
    let maskRotation: Int
}

/// vapc `frame` 数组里的一帧及其 attachments。
struct VapcFrame: Sendable {
    let index: Int
    let attachments: [VapcAttachment]
}

/// 解析后的 vapc 不可变文档。
struct VapcDocument {
    /// vapc 版本。未知版本必须失败，不能静默猜测。
    let version: Int
    /// 逻辑画布。
    let canvasSize: CGSize
    /// packed Alpha 布局。
    let alphaMode: AlphaMode
    /// 可展示帧数。
    let frameCount: Int
    /// vapc 声明的 fps，仅作参考；真正消费仍用 sample duration。
    let framesPerSecond: Int
    /// packed 编码尺寸，含 RGB+Alpha。
    let encodedVideoSize: CGSize
    /// RGB 区域，尺寸必须等于 `canvasSize`。
    let rgbRect: CGRect
    /// Alpha 区域，与 RGB 不得重叠。
    let alphaRect: CGRect
    /// 动态 source 槽位。
    let sources: [VapcSource]
    /// 按帧序号索引的 attachments；没有 overlay 的帧可以缺省。
    let frames: [Int: [VapcAttachment]]
}

/// 读取 MP4 中的 vapc box。对照 `vap-master/tool` 的 JSON 描述和 iOS `QGVAPConfigModel`。
final class VapcReader {
    /// vapc JSON payload 上限 8 MiB，防止异常 box 拖垮解析。
    static let maximumJSONSize = 8 * 1_024 * 1_024
    /// 单个尺寸字段上限，防止异常 JSON 申请超大纹理。
    private let maximumDimension: CGFloat = 16_384
    private let maximumSources = 256
    private let maximumFrames = 100_000
    private let maximumAttachmentsPerFrame = 256

    /// 解析 vapc box 的 JSON payload。所有数组、尺寸和 rect 在构造模型前完成上限校验。
    func read(from data: Data) throws -> VapcDocument {
        try read(from: data, legacyFrameCount: nil)
    }

    /// 解析旧版 VAPC。部分生成器只写入布局信息，不写 `info.v` / `info.f`；
    /// 这种格式必须由调用方根据 AVFoundation 的媒体轨道提供帧数，不能从 JSON 猜测。
    func read(from data: Data, legacyFrameCount: Int) throws -> VapcDocument {
        try read(from: data, legacyFrameCount: Optional(legacyFrameCount))
    }

    /// `legacyFrameCount` 只对同时缺少 `v` 和 `f` 的旧版 VAPC 生效。
    /// 缺少其中一个字段的结构化 VAPC 仍然视为非法，避免把损坏元数据静默当成兼容格式。
    func read(from data: Data, legacyFrameCount: Int?) throws -> VapcDocument {
        guard !data.isEmpty, data.count <= Self.maximumJSONSize else {
            throw invalid("JSON payload is empty or exceeds 8 MiB.")
        }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw invalid("JSON cannot be decoded.")
        }
        guard let root = object as? [String: Any], let info = root["info"] as? [String: Any] else {
            throw invalid("Missing info object.")
        }

        let hasVersion = info["v"] != nil
        let hasFrameCount = info["f"] != nil
        let version: Int
        let frameCount: Int
        switch (hasVersion, hasFrameCount) {
        case (true, true):
            version = try integer(info, "v")
            guard version == 1 || version == 2 else {
                throw invalid("Unsupported version \(version).")
            }
            frameCount = try positiveInteger(info, "f", maximum: maximumFrames)
        case (false, false):
            guard let legacyFrameCount else {
                throw invalid("Missing numeric field v.")
            }
            guard legacyFrameCount > 0, legacyFrameCount <= maximumFrames else {
                throw invalid("Legacy frame count is out of range.")
            }
            version = 0
            frameCount = legacyFrameCount
        default:
            throw invalid("Legacy vapc must omit both v and f fields.")
        }
        let fps = try positiveInteger(info, "fps", maximum: 240)
        let canvasSize = try size(info, width: "w", height: "h")
        let videoSize = try size(info, width: "videoW", height: "videoH")
        let rgbRect = try rect(info["rgbFrame"], name: "rgbFrame", within: videoSize)
        let alphaRect = try rect(info["aFrame"], name: "aFrame", within: videoSize)
        guard rgbRect.size == canvasSize else {
            throw invalid("rgbFrame size must match the logical canvas size.")
        }
        let alphaMode = try alphaMode(alphaRect: alphaRect, rgbRect: rgbRect)

        let sourceObjects = root["src"] as? [[String: Any]] ?? []
        guard sourceObjects.count <= maximumSources else {
            throw invalid("Too many dynamic sources.")
        }
        var sourceIDs = Set<String>()
        var dynamicTextureBytes = 0
        let sources = try sourceObjects.map { source -> VapcSource in
            guard
                let id = nonEmptyString(source["srcId"]),
                let rawKind = nonEmptyString(source["srcType"]),
                let kind = VapcSource.Kind(rawValue: rawKind),
                let tag = nonEmptyString(source["srcTag"])
            else {
                throw invalid("A source is missing srcId, srcType, or srcTag.")
            }
            guard sourceIDs.insert(id).inserted else {
                throw invalid("Duplicate source id \(id).")
            }
            let slotSize = try size(source, width: "w", height: "h")
            guard
                let textureBytes = DynamicTextureLimits.byteCount(for: slotSize),
                textureBytes <= DynamicTextureLimits.maximumBytesPerTexture,
                dynamicTextureBytes <= DynamicTextureLimits.maximumBytesPerSession - textureBytes
            else {
                throw invalid("Dynamic source textures exceed the allocation budget.")
            }
            dynamicTextureBytes += textureBytes
            return VapcSource(
                id: id,
                kind: kind,
                tag: tag,
                slotSize: slotSize,
                loadType: nonEmptyString(source["loadType"]) ?? "local",
                fitType: nonEmptyString(source["fitType"]) ?? "fitXY",
                color: nonEmptyString(source["color"]),
                style: nonEmptyString(source["style"])
            )
        }
        let sourceKindByID = Dictionary(uniqueKeysWithValues: sources.map { ($0.id, $0.kind) })

        let frameObjects = root["frame"] as? [[String: Any]] ?? []
        guard frameObjects.count <= maximumFrames else {
            throw invalid("Too many frame entries.")
        }
        var frames: [Int: [VapcAttachment]] = [:]
        for frameObject in frameObjects {
            let index = try integer(frameObject, "i")
            guard index >= 0, index < frameCount else {
                throw invalid("Frame index \(index) is out of range.")
            }
            guard frames[index] == nil else {
                throw invalid("Duplicate frame index \(index).")
            }
            let objects = frameObject["obj"] as? [[String: Any]] ?? []
            guard objects.count <= maximumAttachmentsPerFrame else {
                throw invalid("Frame \(index) has too many attachments.")
            }
            let attachments = try objects.map { item -> VapcAttachment in
                guard let sourceID = nonEmptyString(item["srcId"]), sourceIDs.contains(sourceID) else {
                    throw invalid("Frame \(index) references an unknown source.")
                }
                let renderRect = try rect(item["frame"], name: "frame", within: canvasSize)
                let maskRect = try rect(item["mFrame"], name: "mFrame", within: videoSize)
                return VapcAttachment(
                    sourceID: sourceID,
                    kind: sourceKindByID[sourceID] ?? .image,
                    zIndex: (item["z"] as? NSNumber)?.intValue ?? 0,
                    renderRect: renderRect,
                    maskRect: maskRect,
                    maskRotation: (item["mt"] as? NSNumber)?.intValue ?? 0
                )
            }
            frames[index] = attachments.sorted { $0.zIndex < $1.zIndex }
        }

        return VapcDocument(
            version: version,
            canvasSize: canvasSize,
            alphaMode: alphaMode,
            frameCount: frameCount,
            framesPerSecond: fps,
            encodedVideoSize: videoSize,
            rgbRect: rgbRect,
            alphaRect: alphaRect,
            sources: sources,
            frames: frames
        )
    }

    /// 读取必填整数字段。
    private func integer(_ dictionary: [String: Any], _ key: String) throws -> Int {
        guard let number = dictionary[key] as? NSNumber else {
            throw invalid("Missing numeric field \(key).")
        }
        let value = number.doubleValue
        guard value.isFinite, value.rounded() == value else {
            throw invalid("Field \(key) must be an integer.")
        }
        return number.intValue
    }

    /// 读取 (0, maximum] 的正整数，用于帧数、fps 等。
    private func positiveInteger(_ dictionary: [String: Any], _ key: String, maximum: Int) throws -> Int {
        let value = try integer(dictionary, key)
        guard value > 0, value <= maximum else {
            throw invalid("Field \(key) is out of range.")
        }
        return value
    }

    /// 读取宽高，拒绝非有限或超大尺寸。
    private func size(_ dictionary: [String: Any], width: String, height: String) throws -> CGSize {
        guard
            let widthValue = dictionary[width] as? NSNumber,
            let heightValue = dictionary[height] as? NSNumber
        else {
            throw invalid("Missing size fields \(width)/\(height).")
        }
        let result = CGSize(width: widthValue.doubleValue, height: heightValue.doubleValue)
        guard validDimension(result.width), validDimension(result.height) else {
            throw invalid("Size \(width)/\(height) is out of range.")
        }
        return result
    }

    /// 读取 `[x, y, w, h]` 且必须完全落在 `bounds` 内。
    private func rect(_ value: Any?, name: String, within bounds: CGSize) throws -> CGRect {
        guard let values = value as? [NSNumber], values.count == 4 else {
            throw invalid("\(name) must contain four numbers.")
        }
        let rect = CGRect(
            x: values[0].doubleValue,
            y: values[1].doubleValue,
            width: values[2].doubleValue,
            height: values[3].doubleValue
        )
        guard
            rect.origin.x >= 0,
            rect.origin.y >= 0,
            validDimension(rect.width),
            validDimension(rect.height),
            rect.maxX <= bounds.width,
            rect.maxY <= bounds.height
        else {
            throw invalid("\(name) exceeds the encoded video bounds.")
        }
        return rect
    }

    /// 由 Alpha / RGB 矩形的相对位置推断 `AlphaMode`；重叠则失败。
    private func alphaMode(alphaRect: CGRect, rgbRect: CGRect) throws -> AlphaMode {
        if alphaRect.maxX <= rgbRect.minX { return .left }
        if alphaRect.minX >= rgbRect.maxX { return .right }
        if alphaRect.maxY <= rgbRect.minY { return .top }
        if alphaRect.minY >= rgbRect.maxY { return .bottom }
        throw invalid("Alpha and RGB regions overlap or have an unknown layout.")
    }

    /// 宽高必须为正有限值且不超过 `maximumDimension`。
    private func validDimension(_ value: CGFloat) -> Bool {
        value.isFinite && value > 0 && value <= maximumDimension
    }

    /// 非空且不超过 1 KiB 的字符串；过长 tag / id 直接丢弃。
    private func nonEmptyString(_ value: Any?) -> String? {
        guard let value = value as? String, !value.isEmpty, value.utf8.count <= 1_024 else { return nil }
        return value
    }

    /// 把 vapc 解析失败统一包装成 `PlaybackError.invalidVapc`。
    private func invalid(_ reason: String) -> PlaybackError {
        .invalidVapc(reason: reason)
    }
}
