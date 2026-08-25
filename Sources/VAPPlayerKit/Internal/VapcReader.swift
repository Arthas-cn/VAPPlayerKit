import Foundation
import CoreGraphics

struct VapcSource: Sendable {
    enum Kind: String, Sendable {
        case image = "img"
        case text = "txt"
    }

    let id: String
    let kind: Kind
    let tag: String
    let slotSize: CGSize
    let loadType: String
    let fitType: String
    let color: String?
    let style: String?
}

struct VapcAttachment: Sendable {
    let sourceID: String
    let kind: VapcSource.Kind
    let zIndex: Int
    let renderRect: CGRect
    let maskRect: CGRect
    let maskRotation: Int
}

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
    let frameCount: Int
    let framesPerSecond: Int
    let encodedVideoSize: CGSize
    let rgbRect: CGRect
    let alphaRect: CGRect
    let sources: [VapcSource]
    let frames: [Int: [VapcAttachment]]
}

/// 读取 MP4 中的 vapc box。对照 `vap-master/tool` 的 JSON 描述和 iOS `QGVAPConfigModel`。
final class VapcReader {
    static let maximumJSONSize = 8 * 1_024 * 1_024
    private let maximumDimension: CGFloat = 16_384
    private let maximumSources = 256
    private let maximumFrames = 100_000
    private let maximumAttachmentsPerFrame = 256

    /// 解析 vapc box 的 JSON payload。所有数组、尺寸和 rect 在构造模型前完成上限校验。
    func read(from data: Data) throws -> VapcDocument {
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

        let version = try integer(info, "v")
        guard version == 1 || version == 2 else {
            throw invalid("Unsupported version \(version).")
        }
        let frameCount = try positiveInteger(info, "f", maximum: maximumFrames)
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

    private func positiveInteger(_ dictionary: [String: Any], _ key: String, maximum: Int) throws -> Int {
        let value = try integer(dictionary, key)
        guard value > 0, value <= maximum else {
            throw invalid("Field \(key) is out of range.")
        }
        return value
    }

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

    private func alphaMode(alphaRect: CGRect, rgbRect: CGRect) throws -> AlphaMode {
        if alphaRect.maxX <= rgbRect.minX { return .left }
        if alphaRect.minX >= rgbRect.maxX { return .right }
        if alphaRect.maxY <= rgbRect.minY { return .top }
        if alphaRect.minY >= rgbRect.maxY { return .bottom }
        throw invalid("Alpha and RGB regions overlap or have an unknown layout.")
    }

    private func validDimension(_ value: CGFloat) -> Bool {
        value.isFinite && value > 0 && value <= maximumDimension
    }

    private func nonEmptyString(_ value: Any?) -> String? {
        guard let value = value as? String, !value.isEmpty, value.utf8.count <= 1_024 else { return nil }
        return value
    }

    private func invalid(_ reason: String) -> PlaybackError {
        .invalidVapc(reason: reason)
    }
}
