import UIKit

public struct TextAttributes {
    public var font: UIFont
    public var color: UIColor

    public init(font: UIFont = .systemFont(ofSize: 17), color: UIColor = .white) {
        self.font = font
        self.color = color
    }
}

public enum DynamicContent {
    case text(String, attributes: TextAttributes)
    case image(UIImage)
    case imageURL(URL)
    case hidden
}

@objc(VPKSourceMetadata)
public final class SourceMetadata: NSObject {
    @objc public let tag: String
    @objc public let slotSize: CGSize

    @objc public init(tag: String, slotSize: CGSize) {
        self.tag = tag
        self.slotSize = slotSize
        super.init()
    }
}

public protocol DynamicContentProvider: AnyObject {
    func resolve(
        tag: String,
        source: SourceMetadata,
        completion: @escaping (DynamicContent?, Error?) -> Void
    )
}

@objc(VPKDynamicContentProvider)
public protocol ObjCDynamicContentProvider: NSObjectProtocol {
    func resolveTag(
        _ tag: String,
        source: SourceMetadata,
        completion: @escaping (UIImage?, NSError?) -> Void
    )
}
