import Foundation

@MainActor
public protocol PlayerDelegate: AnyObject {
    func playerDidStart(_ player: PlayerView)
    func player(_ player: PlayerView, didUpdate metadata: AssetMetadata)
    func playerDidFinish(_ player: PlayerView, reason: FinishReason)
    func player(_ player: PlayerView, didFail error: Error)
}

@objc(VPKPlayerDelegate)
public protocol ObjCPlayerDelegate: NSObjectProtocol {
    @objc optional func playerViewDidStart(_ playerView: PlayerView)
    @objc optional func playerView(_ playerView: PlayerView, didResolveMetadata metadata: AssetMetadata)
    @objc optional func playerView(_ playerView: PlayerView, didFailWithError error: NSError)
    @objc optional func playerView(_ playerView: PlayerView, didFinishWithReason reason: FinishReason)
}
