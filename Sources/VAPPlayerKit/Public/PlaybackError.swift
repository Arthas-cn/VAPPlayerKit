import Foundation

/// NSError.domain，Objective-C 与 Swift 共用。
public let VPKPlaybackErrorDomain = "com.vapplayerkit.playback"

/// 与 `PlaybackError` 一一对应的 ObjC 错误码。从 1 开始，0 不使用。
@objc(VPKPlaybackErrorCode)
public enum PlaybackErrorCode: Int, Sendable {
    /// URL 不是本地 file URL。
    case invalidURL = 1
    /// 本地文件不存在。
    case fileNotFound
    /// MP4 容器非法或缺少必需 box。
    case invalidMP4
    /// vapc JSON 非法、越界或版本无法识别。
    case invalidVapc
    /// 编码格式当前设备无法硬解。
    case unsupportedCodec
    /// VTDecompressionSession 创建失败。
    case decoderCreationFailed
    /// 解码过程中 VT 返回不可恢复错误。
    case decoderFailed
    /// 动态资源在超时前没有完成、失败或取消。
    case dynamicContentTimeout
    /// 设备没有可用 MTLDevice。
    case metalUnavailable
    /// nextDrawable 为 nil 或 drawableSize 为 0，且无法恢复。
    case drawableUnavailable
    /// 当前 session 已被取消。
    case cancelled
    /// 音频路径失败。
    case audioFailed
}

/// Swift 侧 canonical 错误。可转换为 `NSError(domain:code:)` 给 Objective-C。
public enum PlaybackError: Error, Sendable {
    /// 只接受本地 file URL，网络地址不属于本组件。
    case invalidURL
    /// 路径指向的文件不存在。
    case fileNotFound
    /// MP4 无法解析。`reason` 描述缺失的 moov、视频轨等。
    case invalidMP4(reason: String)
    /// vapc 无法解析。`reason` 描述 JSON、尺寸或 source rect 问题。
    case invalidVapc(reason: String)
    /// 不支持的 codec 名称，例如软解-only 格式。
    case unsupportedCodec(String)
    /// 创建解码器失败，附带原始 OSStatus。
    case decoderCreationFailed(osStatus: Int32)
    /// 运行中解码失败，附带原始 OSStatus。
    case decoderFailed(osStatus: Int32)
    /// 动态内容等待组超时。
    case dynamicContentTimeout
    /// Metal 不可用。
    case metalUnavailable
    /// 当前无法拿到可绘制表面。
    case drawableUnavailable
    /// token 失效或宿主取消。
    case cancelled
    /// 音频启动或同步失败。
    case audioFailed(reason: String)

    /// 对应的 ObjC / NSError 错误码。
    public var code: PlaybackErrorCode {
        switch self {
        case .invalidURL: return .invalidURL
        case .fileNotFound: return .fileNotFound
        case .invalidMP4: return .invalidMP4
        case .invalidVapc: return .invalidVapc
        case .unsupportedCodec: return .unsupportedCodec
        case .decoderCreationFailed: return .decoderCreationFailed
        case .decoderFailed: return .decoderFailed
        case .dynamicContentTimeout: return .dynamicContentTimeout
        case .metalUnavailable: return .metalUnavailable
        case .drawableUnavailable: return .drawableUnavailable
        case .cancelled: return .cancelled
        case .audioFailed: return .audioFailed
        }
    }
}

extension PlaybackError: LocalizedError {
    /// 面向日志和 UI 的简短说明，不包含本地绝对路径。
    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "The provided URL is not a local file URL."
        case .fileNotFound:
            return "The VAP file does not exist."
        case .invalidMP4(let reason):
            return "Invalid MP4 container: \(reason)"
        case .invalidVapc(let reason):
            return "Invalid vapc metadata: \(reason)"
        case .unsupportedCodec(let codec):
            return "Unsupported codec: \(codec)"
        case .decoderCreationFailed(let osStatus):
            return "Failed to create video decoder (OSStatus \(osStatus))."
        case .decoderFailed(let osStatus):
            return "Video decoder failed (OSStatus \(osStatus))."
        case .dynamicContentTimeout:
            return "Timed out while resolving dynamic content."
        case .metalUnavailable:
            return "Metal is not available on this device."
        case .drawableUnavailable:
            return "The Metal drawable is currently unavailable."
        case .cancelled:
            return "Playback was cancelled."
        case .audioFailed(let reason):
            return "Audio playback failed: \(reason)"
        }
    }
}

extension PlaybackError: CustomNSError {
    public static var errorDomain: String { VPKPlaybackErrorDomain }

    public var errorCode: Int { code.rawValue }

    /// 额外诊断字段。当前仅包含 `stage`，后续可加 session id 与 fingerprint。
    public var errorUserInfo: [String: Any] {
        var info: [String: Any] = [NSLocalizedDescriptionKey: errorDescription ?? "Playback failed."]
        info["stage"] = stage
        return info
    }

    /// 失败发生的流水线阶段，便于埋点和重试判断。
    public var stage: String {
        switch self {
        case .invalidURL, .fileNotFound, .invalidMP4, .invalidVapc, .unsupportedCodec:
            return "inspect"
        case .decoderCreationFailed, .decoderFailed:
            return "decode"
        case .dynamicContentTimeout:
            return "prepare"
        case .metalUnavailable, .drawableUnavailable:
            return "render"
        case .audioFailed:
            return "audio"
        case .cancelled:
            return "prepare"
        }
    }
}

extension PlaybackError {
    /// 转成 Objective-C 可消费的 `NSError`。
    public func asNSError() -> NSError {
        self as NSError
    }
}
