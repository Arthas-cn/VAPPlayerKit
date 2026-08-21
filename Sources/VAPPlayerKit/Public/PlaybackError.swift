import Foundation

public let VPKPlaybackErrorDomain = "com.vapplayerkit.playback"

@objc(VPKPlaybackErrorCode)
public enum PlaybackErrorCode: Int, Sendable {
    case invalidURL = 1
    case fileNotFound
    case invalidMP4
    case invalidVapc
    case unsupportedCodec
    case decoderCreationFailed
    case decoderFailed
    case dynamicContentTimeout
    case metalUnavailable
    case drawableUnavailable
    case cancelled
    case audioFailed
}

public enum PlaybackError: Error, Sendable {
    case invalidURL
    case fileNotFound
    case invalidMP4(reason: String)
    case invalidVapc(reason: String)
    case unsupportedCodec(String)
    case decoderCreationFailed(osStatus: Int32)
    case decoderFailed(osStatus: Int32)
    case dynamicContentTimeout
    case metalUnavailable
    case drawableUnavailable
    case cancelled
    case audioFailed(reason: String)

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

    public var errorUserInfo: [String: Any] {
        var info: [String: Any] = [NSLocalizedDescriptionKey: errorDescription ?? "Playback failed."]
        info["stage"] = stage
        return info
    }

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
    public func asNSError() -> NSError {
        self as NSError
    }
}
