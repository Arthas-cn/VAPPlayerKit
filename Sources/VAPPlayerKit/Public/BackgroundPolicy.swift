import Foundation

@objc(VPKBackgroundPolicy)
public enum BackgroundPolicy: Int, Sendable {
    case suspend
    case stop
}
