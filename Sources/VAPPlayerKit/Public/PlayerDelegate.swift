import Foundation

/// Swift 侧播放回调。所有方法在主线程调用，每个 session 的终态最多一次。
///
/// 对照 `vap-master` 的 `HWDMP4PlayDelegate`，但回调线程固定主线程，且不再回传内部 frame 对象。
@MainActor
public protocol PlayerDelegate: AnyObject {
    /// 新 session 进入 playing。
    func playerDidStart(_ player: PlayerView)
    /// vapc / sample table 解析完成，可用于按 `canvasSize` 调整布局。
    func player(_ player: PlayerView, didUpdate metadata: AssetMetadata)
    /// 正常播完、stop 或 cancel。不会再跟 fail。
    func playerDidFinish(_ player: PlayerView, reason: FinishReason)
    /// 不可恢复错误。不会再跟 finish。
    func player(_ player: PlayerView, didFail error: Error)
}

/// Objective-C 侧可选回调。运行时符号名为 `VPKPlayerDelegate`。
///
/// 与 `PlayerDelegate` 共享同一套 session 事件，只是方法均为 optional，错误类型为 `NSError`。
@objc(VPKPlayerDelegate)
public protocol ObjCPlayerDelegate: NSObjectProtocol {
    /// 对应 `playerDidStart`。
    @objc optional func playerViewDidStart(_ playerView: PlayerView)
    /// 对应 `didUpdate metadata`。
    @objc optional func playerView(_ playerView: PlayerView, didResolveMetadata metadata: AssetMetadata)
    /// 对应 `didFail`。
    @objc optional func playerView(_ playerView: PlayerView, didFailWithError error: NSError)
    /// 对应 `playerDidFinish`。
    @objc optional func playerView(_ playerView: PlayerView, didFinishWithReason reason: FinishReason)
}
