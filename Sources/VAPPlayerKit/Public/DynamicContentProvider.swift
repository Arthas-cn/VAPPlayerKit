import UIKit

/// 动态文字的绘制属性。圆角、裁剪等业务处理应在 provider 侧完成，不要放进每帧 Metal 路径。
public struct TextAttributes: @unchecked Sendable {
    /// 用于离屏绘制文字纹理的字体。
    public var font: UIFont
    /// 文字颜色。
    public var color: UIColor

    /// 默认字体 17pt、白色。业务圆角和裁剪应在调用前处理。
    public init(font: UIFont = .systemFont(ofSize: 17), color: UIColor = .white) {
        self.font = font
        self.color = color
    }
}

/// 宿主提供的动态内容。用枚举而不是字符串猜测类型。
///
/// 对照 `vap-master` 的 `contentForVapTag:` / `loadVapImageWithURL:`，但结果类型明确。
public enum DynamicContent: @unchecked Sendable {
    /// 由组件按 `source.slotSize` 预绘成纹理。
    case text(String, attributes: TextAttributes)
    /// 只替换字符串。组件使用 vapc source 声明的颜色和字重，并按槽位自动适配字号。
    ///
    /// vapc 不携带字体文件或精确 point size，因此这里保持的是动效声明的样式与布局约束；
    /// 需要按 tag 指定字体时可在 provider 的 `font(forTag:)` 中返回字体。
    case textReplacement(String)
    /// 已经解码的图片，组件会按 slot 预缩放。
    /// 宿主若链接 SDWebImage 并传入 `SDAnimatedImage`（帧数 > 1），可按 `PlaybackOptions.dynamicImagePlaybackMode` 播放动图。
    case image(UIImage)
    /// 仅表达「这是一个图片 URL」。下载仍由宿主完成；组件不会发网络请求。
    case imageURL(URL)
    /// 该 tag 本轮不渲染。
    case hidden
}

/// vapc `srcType`。宿主应按此决定返回文字还是图片，不要从 tag 字符串猜测。
@objc(VPKDynamicSourceKind)
public enum DynamicSourceKind: Int, Sendable {
    /// 图片槽位，应对应 `DynamicContent.image` / `.imageURL` / `.hidden`。
    case image = 0
    /// 文字槽位，应对应 `.text` / `.textReplacement` / `.hidden`。
    case text = 1
}

/// vapc 里一个动态 source 槽位的只读描述。
@objc(VPKSourceMetadata)
public final class SourceMetadata: NSObject {
    /// vapc 中的 tag，例如 `avatar`、`userName`。
    @objc public let tag: String
    /// 该槽位的像素尺寸，动态图必须按此预缩放。
    @objc public let slotSize: CGSize
    /// vapc 声明的槽位类型：`img` 或 `txt`。
    @objc public let kind: DynamicSourceKind

    /// 兼容旧调用：未声明 kind 时按图片槽位处理。
    @objc public convenience init(tag: String, slotSize: CGSize) {
        self.init(tag: tag, slotSize: slotSize, kind: .image)
    }

    /// 完整构造。`kind` 必须与 vapc `srcType` 一致。
    @objc public init(tag: String, slotSize: CGSize, kind: DynamicSourceKind) {
        self.tag = tag
        self.slotSize = slotSize
        self.kind = kind
        super.init()
    }
}

/// Swift 动态内容提供者。组件不绑定任何图片库或下载器。
///
/// `completion` 必须且只能调用一次；超时、取消、provider 释放都要收口。
public protocol DynamicContentProvider: AnyObject {
    /// 为指定 tag 返回文字、图片或隐藏。
    /// - Parameters:
    ///   - tag: vapc source tag。
    ///   - source: 槽位尺寸等元数据。
    ///   - completion: 主线程或后台均可，组件内部会收敛到 session queue。
    func resolve(
        tag: String,
        source: SourceMetadata,
        completion: @escaping (DynamicContent?, Error?) -> Void
    )

    /// 可选的 tag 字体覆盖。返回 `nil` 时，`.textReplacement` 使用组件的自动字号估算。
    func font(forTag tag: String) -> UIFont?
}

/// 未实现 `font(forTag:)` 时的默认行为：使用组件自动字号估算。
public extension DynamicContentProvider {
    func font(forTag tag: String) -> UIFont? { nil }
}

/// Objective-C 动态内容协议。图片槽位返回 `UIImage`；文字槽位返回替换字符串，
/// 由组件按 vapc 样式自动估算字号，与 Swift `.textReplacement` 一致。
@objc(VPKDynamicContentProvider)
public protocol ObjCDynamicContentProvider: NSObjectProtocol {
    /// 解析 tag。失败时给出 `NSError`。文字替换传 `replacementText`，图片传 `image`。
    func resolveTag(
        _ tag: String,
        source: SourceMetadata,
        completion: @escaping (UIImage?, String?, NSError?) -> Void
    )

    /// 可选的 tag 字体覆盖；未实现或返回 nil 时使用自动字号估算。
    @objc optional func fontForTag(_ tag: String) -> UIFont?
}
