import Foundation
import ObjectiveC
import UIKit

/// Optional SDWebImage hook. The kit never links SDWebImage / SDWebImageWebPCoder;
/// hosts that do can pass `SDAnimatedImage` and this bridge will drive frames.
enum SDWebImageRuntime {
    static var isAvailable: Bool {
        NSClassFromString("SDAnimatedImage") != nil
            && NSClassFromString("SDAnimatedImagePlayer") != nil
    }

    static func isAnimatedImage(_ image: UIImage) -> Bool {
        guard isAvailable, let cls = NSClassFromString("SDAnimatedImage"), image.isKind(of: cls) else {
            return false
        }
        return frameCount(of: image) > 1
    }

    static func frameCount(of image: UIImage) -> UInt {
        let sel = NSSelectorFromString("animatedImageFrameCount")
        guard image.responds(to: sel), let method = class_getInstanceMethod(type(of: image), sel) else {
            return 0
        }
        typealias Getter = @convention(c) (AnyObject, Selector) -> UInt
        return unsafeBitCast(method_getImplementation(method), to: Getter.self)(image, sel)
    }

    static func frame(of image: UIImage, at index: UInt) -> UIImage? {
        let sel = NSSelectorFromString("animatedImageFrameAtIndex:")
        guard image.responds(to: sel), let method = class_getInstanceMethod(type(of: image), sel) else {
            return nil
        }
        typealias FrameAtIndex = @convention(c) (AnyObject, Selector, UInt) -> Unmanaged<UIImage>?
        return unsafeBitCast(method_getImplementation(method), to: FrameAtIndex.self)(image, sel, index)?
            .takeUnretainedValue()
    }

    static func makePlayer(provider: UIImage, onFrame: @escaping (UInt, UIImage) -> Void) -> Player? {
        guard isAnimatedImage(provider), let cls = NSClassFromString("SDAnimatedImagePlayer") else {
            return nil
        }
        let factorySel = NSSelectorFromString("playerWithProvider:")
        guard let factory = class_getClassMethod(cls, factorySel) else { return nil }
        typealias Factory = @convention(c) (AnyClass, Selector, AnyObject) -> Unmanaged<AnyObject>?
        guard let unmanaged = unsafeBitCast(method_getImplementation(factory), to: Factory.self)(cls, factorySel, provider) else {
            return nil
        }
        guard let raw = unmanaged.takeUnretainedValue() as? NSObject else {
            return nil
        }

        // 0 means loop for as long as the VAP session keeps the player alive.
        setUnsigned(raw, selector: "setTotalLoopCount:", value: 0)

        typealias FrameHandler = @convention(block) (UInt, UIImage) -> Void
        let handler: FrameHandler = { index, frame in onFrame(index, frame) }
        let handlerSel = NSSelectorFromString("setAnimationFrameHandler:")
        if let method = class_getInstanceMethod(type(of: raw), handlerSel) {
            typealias Setter = @convention(c) (AnyObject, Selector, FrameHandler?) -> Void
            unsafeBitCast(method_getImplementation(method), to: Setter.self)(raw, handlerSel, handler)
        }
        return Player(raw: raw)
    }

    final class Player {
        private let raw: NSObject

        fileprivate init(raw: NSObject) {
            self.raw = raw
        }

        deinit {
            if Thread.isMainThread {
                call(raw, "stopPlaying")
                clearFrameHandler()
            }
        }

        func start() { call(raw, "startPlaying") }
        func pause() { call(raw, "pausePlaying") }

        func stop() {
            call(raw, "stopPlaying")
            clearFrameHandler()
        }

        private func clearFrameHandler() {
            let sel = NSSelectorFromString("setAnimationFrameHandler:")
            guard let method = class_getInstanceMethod(type(of: raw), sel) else { return }
            typealias FrameHandler = @convention(block) (UInt, UIImage) -> Void
            typealias Setter = @convention(c) (AnyObject, Selector, FrameHandler?) -> Void
            unsafeBitCast(method_getImplementation(method), to: Setter.self)(raw, sel, nil)
        }
    }
}

private func call(_ object: NSObject, _ selectorName: String) {
    let sel = NSSelectorFromString(selectorName)
    guard object.responds(to: sel), let method = class_getInstanceMethod(type(of: object), sel) else { return }
    typealias IMP = @convention(c) (AnyObject, Selector) -> Void
    unsafeBitCast(method_getImplementation(method), to: IMP.self)(object, sel)
}

private func setUnsigned(_ object: NSObject, selector: String, value: UInt) {
    let sel = NSSelectorFromString(selector)
    guard object.responds(to: sel), let method = class_getInstanceMethod(type(of: object), sel) else { return }
    typealias Setter = @convention(c) (AnyObject, Selector, UInt) -> Void
    unsafeBitCast(method_getImplementation(method), to: Setter.self)(object, sel, value)
}
