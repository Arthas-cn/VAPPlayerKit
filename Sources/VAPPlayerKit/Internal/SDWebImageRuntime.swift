import Foundation
import ObjectiveC
import UIKit

/// 可选的 SDWebImage 运行时桥。组件从不链接 SDWebImage / SDWebImageWebPCoder；
/// 宿主若自行链接并传入 `SDAnimatedImage`，本桥会用 runtime selector 驱动帧。
enum SDWebImageRuntime {
    /// 进程里同时存在 `SDAnimatedImage` 和 `SDAnimatedImagePlayer` 才视为可用。
    static var isAvailable: Bool {
        NSClassFromString("SDAnimatedImage") != nil
            && NSClassFromString("SDAnimatedImagePlayer") != nil
    }

    /// 是否为帧数大于 1 的 `SDAnimatedImage`。普通 UIImage 返回 false。
    static func isAnimatedImage(_ image: UIImage) -> Bool {
        guard isAvailable, let cls = NSClassFromString("SDAnimatedImage"), image.isKind(of: cls) else {
            return false
        }
        return frameCount(of: image) > 1
    }

    /// 读取 `animatedImageFrameCount`。selector 不存在时返回 0。
    static func frameCount(of image: UIImage) -> UInt {
        let sel = NSSelectorFromString("animatedImageFrameCount")
        guard image.responds(to: sel), let method = class_getInstanceMethod(type(of: image), sel) else {
            return 0
        }
        typealias Getter = @convention(c) (AnyObject, Selector) -> UInt
        return unsafeBitCast(method_getImplementation(method), to: Getter.self)(image, sel)
    }

    /// 读取指定序号的动画帧。失败返回 nil。
    static func frame(of image: UIImage, at index: UInt) -> UIImage? {
        let sel = NSSelectorFromString("animatedImageFrameAtIndex:")
        guard image.responds(to: sel), let method = class_getInstanceMethod(type(of: image), sel) else {
            return nil
        }
        typealias FrameAtIndex = @convention(c) (AnyObject, Selector, UInt) -> Unmanaged<UIImage>?
        return unsafeBitCast(method_getImplementation(method), to: FrameAtIndex.self)(image, sel, index)?
            .takeUnretainedValue()
    }

    /// 创建 `SDAnimatedImagePlayer`，循环次数设为 0（跟随 VAP session 生命周期）。
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

        // 0 表示只要 VAP session 还活着就一直循环。
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

    /// 对 SDAnimatedImagePlayer 的轻量包装，避免把 ObjC 运行时细节漏到播放状态机。
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

        /// 清空 frame handler，切断对 session 的强引用。
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
