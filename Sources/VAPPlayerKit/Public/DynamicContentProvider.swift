import UIKit

/// 槽位文字的绘制属性；仅在 MainActor 上创建并交给动态内容准备器使用。
@MainActor
public struct TextAttributes {
    /// 文字栅格化的字体；槽位裁剪和像素预算仍由播放器限制。
    public var font: UIFont
    /// 绘制颜色；透明文字不会改变视频底图。
    public var color: UIColor

    /// 创建文字样式，默认 17pt 白色；不在初始化时绘制纹理。
    public init(font: UIFont = .systemFont(ofSize: 17), color: UIColor = .white) {
        self.font = font
        self.color = color
    }
}

/// 宿主已经准备好的动态内容；不包含远程 URL、下载器或缓存所有权。
@MainActor
public enum DynamicContent {
    /// 按显式字体和颜色绘制文字；字符串可以为空以清空槽位。
    case text(String, attributes: TextAttributes)
    /// 使用素材声明的颜色和字重绘制替换字符串。
    case textReplacement(String)
    /// 已解码图片；由播放器按槽位缩放，宿主负责此前的下载与共享缓存。
    case image(UIImage)
    /// 不绘制此槽的覆盖内容，保留视频底图。
    case hidden
}

/// 素材声明的动态槽位类型；不按 tag 名称猜测内容种类。
public enum DynamicSourceKind: Sendable, Equatable {
    /// 图片槽位，只接受图片或 hidden。
    case image
    /// 文字槽位，接受文字或 hidden。
    case text
}

/// inspection 返回的不可变槽位描述，可以安全进入业务值状态。
public struct SourceMetadata: Sendable, Equatable {
    /// 大小写敏感的素材 tag，不是文件路径或网络地址。
    public let tag: String
    /// 槽位像素尺寸；播放器在创建纹理前再次检查预算。
    public let slotSize: CGSize
    /// 素材原始的图片/文字类型。
    public let kind: DynamicSourceKind

    /// 创建槽位描述；通常由 inspect 返回，测试也可以构造确定的描述。
    public init(tag: String, slotSize: CGSize, kind: DynamicSourceKind = .image) {
        self.tag = tag
        self.slotSize = slotSize
        self.kind = kind
    }
}

/// MainActor 上的异步槽位提供者；仅返回已准备内容，不在视频解码线程调用。
/// 取消必须协作退出；clearAndWait 会等实际 resolve 返回，不能提前释放其资源。
@MainActor
public protocol DynamicContentProvider: AnyObject {
    /// 为 tag 返回覆盖内容；nil 与 hidden 都表示不覆盖，失败直接阻止播放。
    func resolve(tag: String, source: SourceMetadata) async throws -> DynamicContent?
    /// 提供可选字体；nil 使用素材样式与槽位大小推算的默认字体。
    func font(forTag tag: String) -> UIFont?
}

/// 提供者无需覆盖字体时沿用素材的自动排版。
public extension DynamicContentProvider {
    /// 未定制 tag 时返回 nil，由准备器选择默认字体。
    func font(forTag tag: String) -> UIFont? { nil }
}
