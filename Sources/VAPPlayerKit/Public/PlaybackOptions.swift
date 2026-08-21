import UIKit

@objc(VPKPlaybackOptions)
public final class PlaybackOptions: NSObject, NSCopying {
    /// Total number of plays. `1` plays once, `2` plays twice, `0` loops forever.
    @objc public var loopCount: Int = 1
    @objc public var contentMode: UIView.ContentMode = .scaleAspectFit
    @objc public var audioMode: AudioMode = .muted
    @objc public var clearsAfterFinish: Bool = true
    @objc public var backgroundPolicy: BackgroundPolicy = .suspend

    @objc(defaultOptions)
    public static var defaultOptions: PlaybackOptions {
        PlaybackOptions()
    }

    @objc public override init() {
        super.init()
    }

    public func copy(with zone: NSZone? = nil) -> Any {
        let copy = PlaybackOptions()
        copy.loopCount = loopCount
        copy.contentMode = contentMode
        copy.audioMode = audioMode
        copy.clearsAfterFinish = clearsAfterFinish
        copy.backgroundPolicy = backgroundPolicy
        return copy
    }
}
