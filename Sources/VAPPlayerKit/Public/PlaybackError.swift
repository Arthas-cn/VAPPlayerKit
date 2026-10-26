import Foundation

/// Foundation 日志使用的错误域，不暴露 Objective-C 播放接口。
public let VPKPlaybackErrorDomain = "com.vapplayerkit.playback"

/// 稳定的诊断错误分类；业务应优先匹配 PlaybackError 的具体分支。
public enum PlaybackErrorCode: Int, Sendable {
    /// URL 不是本地 file URL。
    case invalidURL = 1
    /// 本地文件不存在。
    case fileNotFound
    /// MP4 容器非法或缺少必需 box。
    case invalidMP4
    /// vapc JSON 非法、越界或版本无法识别。
    case invalidVapc
    /// 编码格式当前设备无法解码。
    case unsupportedCodec
    /// 系统解码管线创建失败。
    case decoderCreationFailed
    /// 解码过程中系统管线返回不可恢复错误。
    case decoderFailed
    /// 动态资源在超时前没有完成、失败或取消。
    case dynamicContentTimeout
    /// 设备没有可用 MTLDevice。
    case metalUnavailable
    /// nextDrawable 为 nil 或 drawableSize 为 0，且无法恢复。
    case drawableUnavailable
    /// 当前 session 已被取消。
    case cancelled
    /// 输入配置不合法，不能静默修正。
    case invalidArgument
    /// 显式透明矩形不合法或不匹配编码帧。
    case invalidAlphaLayout
    /// 音频路径失败。
    case audioFailed
}

/// 播放器的可比较值错误；跨异步边界保留明确的失败阶段。
public enum PlaybackError: Error, Sendable, Equatable {
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
    /// 输入配置不合法，reason 不包含资源绝对路径。
    case invalidArgument(reason: String)
    /// 透明区域非法、重叠或超出编码帧。
    case invalidAlphaLayout(reason: String)
    /// 音频启动或同步失败。
    case audioFailed(reason: String)

    /// 对应的 Foundation 诊断分类。
    public var code: PlaybackErrorCode {
        switch self {
        // 配置违约独立分类，避免被上层当作媒体损坏重新下载。
        case .invalidArgument: return .invalidArgument
        // 外部透明矩形错误需要修正布局参数，不与通用配置错误混合。
        case .invalidAlphaLayout: return .invalidAlphaLayout
        // 非本地输入在访问文件前拒绝，不能记成文件缺失。
        case .invalidURL: return .invalidURL
        // 资源缺失与格式损坏的修复方式不同，保留独立分类。
        case .fileNotFound: return .fileNotFound
        // 容器或轨道错误属于媒体检查，不能误归为动态布局错误。
        case .invalidMP4: return .invalidMP4
        // VAP 描述无效时可能仍有正常视频轨，诊断需与容器失败区分。
        case .invalidVapc: return .invalidVapc
        // 编码能力不支持不等于文件损坏，保留能力错误分类。
        case .unsupportedCodec: return .unsupportedCodec
        // 创建阶段失败与运行中失败分开统计，定位系统资源或初始化问题。
        case .decoderCreationFailed: return .decoderCreationFailed
        // 已运行的解码管线故障不能被统计成首次创建失败。
        case .decoderFailed: return .decoderFailed
        // 宿主动态内容未完成属于准备屏障，不混入视频解码故障。
        case .dynamicContentTimeout: return .dynamicContentTimeout
        // 渲染能力不可用与暂时缺少展示表面具有不同恢复条件。
        case .metalUnavailable: return .metalUnavailable
        // 表面不可用保留独立分类，避免误判设备完全不支持 Metal。
        case .drawableUnavailable: return .drawableUnavailable
        // 主动撤销不计为媒体故障，供上层抑制错误提示和重试。
        case .cancelled: return .cancelled
        // 音轨就绪或定位故障需要音频诊断，不能归到视频解码器。
        case .audioFailed: return .audioFailed
        }
    }
}

/// 把值错误转换为脱敏的可展示说明，不暴露业务文件路径。
extension PlaybackError: LocalizedError {
    /// 面向日志和 UI 的简短说明，不包含本地绝对路径。
    public var errorDescription: String? {
        switch self {
        // 保留具体参数约束，调用方才能修正输入而不是反复加载资源。
        case .invalidArgument(let reason):
            return "Invalid playback configuration: \(reason)"
        // 几何校验原因用于核对外部矩形，不暗示已尝试自动布局回退。
        case .invalidAlphaLayout(let reason):
            return "Invalid packed alpha layout: \(reason)"
        // 只说明本地输入约束，不把业务传入的完整 URL 暴露到日志。
        case .invalidURL:
            return "The provided URL is not a local file URL."
        // 缺失文件只给稳定说明，避免把沙盒绝对路径传播到 UI。
        case .fileNotFound:
            return "The VAP file does not exist."
        // 保留检查器的容器原因，便于区分缺轨道和缺必需 box。
        case .invalidMP4(let reason):
            return "Invalid MP4 container: \(reason)"
        // 布局 JSON 的诊断与视频容器分开，便于定位素材生成问题。
        case .invalidVapc(let reason):
            return "Invalid vapc metadata: \(reason)"
        // 编码标识是能力排查所需的信息，不需要附带源文件路径。
        case .unsupportedCodec(let codec):
            return "Unsupported codec: \(codec)"
        // 初始化失败保留系统状态码，便于关联 AVFoundation 的创建故障。
        case .decoderCreationFailed(let osStatus):
            return "Failed to create video decoder (OSStatus \(osStatus))."
        // 运行故障保留系统状态码，同时明确它发生在解码过程中。
        case .decoderFailed(let osStatus):
            return "Video decoder failed (OSStatus \(osStatus))."
        // 超时只说明动态内容等待失败，不把取消请求当成底层已排空。
        case .dynamicContentTimeout:
            return "Timed out while resolving dynamic content."
        // 能力缺失没有可供业务修正的资源路径，使用稳定说明即可。
        case .metalUnavailable:
            return "Metal is not available on this device."
        // 表面缺失可能取决于展示条件，措辞不宣称设备永久不可渲染。
        case .drawableUnavailable:
            return "The Metal drawable is currently unavailable."
        // 明确区分用户/宿主撤销与资源失败，不附加伪造的错误原因。
        case .cancelled:
            return "Playback was cancelled."
        // 保留就绪或同步失败原因，避免统一成没有诊断价值的静音结果。
        case .audioFailed(let reason):
            return "Audio playback failed: \(reason)"
        }
    }
}

/// 为 Foundation 诊断提供稳定域、分类和阶段信息。
extension PlaybackError: CustomNSError {
    /// Foundation 日志所用错误域。
    public static var errorDomain: String { VPKPlaybackErrorDomain }

    /// NSError.code，对应 `PlaybackErrorCode.rawValue`。
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
        // 输入、容器、编码和布局均在创建播放管线前检查，合并为检查阶段。
        case .invalidURL, .fileNotFound, .invalidMP4, .invalidVapc, .unsupportedCodec, .invalidArgument, .invalidAlphaLayout:
            return "inspect"
        // 创建与运行失败都由解码后端负责，细分原因仍保留在 code 中。
        case .decoderCreationFailed, .decoderFailed:
            return "decode"
        // 动态内容完成前不能开播，因此超时归入完整准备屏障。
        case .dynamicContentTimeout:
            return "prepare"
        // 渲染能力与展示表面均属于 GPU 呈现路径，按同一阶段聚合。
        case .metalUnavailable, .drawableUnavailable:
            return "render"
        // 音频有独立就绪与同步路径，统计时不并入视频后端。
        case .audioFailed:
            return "audio"
        // 取消本身不携带发生阶段，沿用固定准备分类；是否故障由 code 区分。
        case .cancelled:
            return "prepare"
        }
    }
}

/// 提供 Foundation 错误转换，播放器控制本身始终使用 Swift API。
extension PlaybackError {
    /// 转换为 Foundation 错误，用于系统日志和故障报告。
    public func asNSError() -> NSError {
        self as NSError
    }
}
