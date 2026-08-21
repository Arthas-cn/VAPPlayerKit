import Foundation

@objc(VPKFinishReason)
public enum FinishReason: Int, Sendable {
    case completed
    case stopped
    case cancelled
}
