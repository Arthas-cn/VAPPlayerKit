import Foundation

/// SwiftUI 单次播放的不可变输入；只引用本地资源，不承担下载或文件所有权。
public struct VAPPlaybackRequest: Sendable, Equatable, Identifiable {
    /// 本次播放的稳定身份；重播或改变资源、配置时必须创建新 ID。
    public let id: UUID
    /// 准备与播放期间持续可读的本地普通文件 URL。
    public let url: URL
    /// 本次配置快照；SwiftUI 宿主统一接管挂起与恢复，不允许底层自动恢复。
    public let options: PlaybackOptions

    /// 创建请求描述，不执行 I/O；默认配置使用显式 VAP 模式。
    public init(id: UUID, url: URL, options: PlaybackOptions = .init()) {
        self.id = id
        self.url = url
        self.options = options
    }
}

/// SwiftUI 宿主的播放意图；终态请求必须更换 ID 才能重新开始。
public enum VAPPlaybackIntent: Sendable, Equatable {
    /// 准备完成后播放；恢复系统暂停时还须递增 controlRevision。
    case playing
    /// 保留当前内容与进度，准备完成后也不自动开播。
    case paused
    /// 结束当前请求并清理资源；之后改回 playing 不会复活当前 ID。
    case stopped
}

/// SwiftUI 层暂停的原因；系统恢复不会覆盖用户自己的暂停意图。
public enum VAPPlaybackPauseReason: Sendable, Equatable {
    /// 宿主显式传入 paused。
    case user
    /// 场景 inactive 或音频中断；结束后仍须显式恢复。
    case system
    /// 宿主暂时离窗或没有正数尺寸；恢复尺寸只解除这一项。
    case surfaceUnavailable
}

/// SwiftUI 播放事件中的纯值错误，不向业务暴露任意跨隔离域的 Error 对象。
public enum VAPPlaybackFailure: Error, Sendable, Equatable {
    /// 同一 ID 的不可变请求被修改；旧请求终结，需新 ID 重试。
    case requestChanged
    /// 播放内核已分类的错误，保留其诊断信息。
    case playback(PlaybackError)
    /// 系统或宿主 provider 的其他错误，仅保留可显示的说明。
    case underlying(message: String)
}

/// SwiftUI 播放的低频状态事件；身份始终属于产生事件的原请求。
public struct VAPPlaybackEvent: Sendable, Equatable {
    /// 原请求 ID；业务应先核对它再更新当前界面。
    public let requestID: UUID
    /// 当前状态变化；finished 与 failed 是互斥终态。
    public let kind: Kind

    /// 创建用于业务处理或测试的事件快照，不驱动播放器。
    public init(requestID: UUID, kind: Kind) {
        self.requestID = requestID
        self.kind = kind
    }

    /// 事件的具体含义；不提供逐帧回调或可变 SDK 对象。
    public enum Kind: Sendable, Equatable {
        /// 等待有效窗口、尺寸或活动场景，尚未开始 prepare。
        case waitingForPresentation
        /// 已接纳请求，正在准备内核；此时尚未调用首次 play。
        case preparing
        /// prepare 成功；暂停意图或系统门仍可能阻止开始。
        case ready
        /// 当前请求首次进入运行态，不表示肉眼已经看见首帧。
        case started
        /// 当前请求因指定原因暂停，不结束请求。
        case paused(VAPPlaybackPauseReason)
        /// 已开始的请求获得显式或展示条件恢复，不重复发送 started。
        case resumed
        /// 当前请求自然完成、停止或被替换，之后不再发送业务事件。
        case finished(FinishReason)
        /// 请求失败；物理清理可能仍在进行，终态不会重复发送。
        case failed(VAPPlaybackFailure)
    }
}
