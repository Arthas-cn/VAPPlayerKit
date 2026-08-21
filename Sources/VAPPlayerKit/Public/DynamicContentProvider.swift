import UIKit

/// 动态文字的绘制属性。圆角、裁剪等业务处理应在 provider 侧完成，不要放进每帧 Metal 路径。
public struct TextAttributes: @unchecked Sendable {
    /// 用于离屏绘制文字纹理的字体。
    public var font: UIFont
    /// 文字颜色。
    public var color: UIColor

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
    /// 已经解码的图片，组件会按 slot 预缩放。
    case image(UIImage)
    /// 仅表达「这是一个图片 URL」。下载仍由宿主完成；组件不会发网络请求。
    case imageURL(URL)
    /// 该 tag 本轮不渲染。
    case hidden
}

/// vapc 里一个动态 source 槽位的只读描述。
@objc(VPKSourceMetadata)
public final class SourceMetadata: NSObject {
    /// vapc 中的 tag，例如 `avatar`、`userName`。
    @objc public let tag: String
    /// 该槽位的像素尺寸，动态图必须按此预缩放。
    @objc public let slotSize: CGSize

    @objc public init(tag: String, slotSize: CGSize) {
        self.tag = tag
        self.slotSize = slotSize
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
}

/// Objective-C 简化版动态内容协议，以 `UIImage` 表达已经加载好的结果。
@objc(VPKDynamicContentProvider)
public protocol ObjCDynamicContentProvider: NSObjectProtocol {
    /// 解析 tag。失败时 `image` 为 nil 并给出 `NSError`。
    func resolveTag(
        _ tag: String,
        source: SourceMetadata,
        completion: @escaping (UIImage?, NSError?) -> Void
    )
}
