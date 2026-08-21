import Foundation

@objc(VPKAudioMode)
public enum AudioMode: Int, Sendable {
    case muted
    case embedded
    case external
    case disabled
}
