import Foundation
import CoreGraphics

@objc(VPKAssetMetadata)
public final class AssetMetadata: NSObject {
    @objc public let encodedVideoSize: CGSize
    @objc public let canvasSize: CGSize
    @objc public let alphaMode: AlphaMode
    @objc public let frameCount: Int
    @objc public let duration: TimeInterval
    @objc public let containsAudio: Bool
    @objc public let codec: String

    @objc public init(
        encodedVideoSize: CGSize,
        canvasSize: CGSize,
        alphaMode: AlphaMode,
        frameCount: Int,
        duration: TimeInterval,
        containsAudio: Bool,
        codec: String
    ) {
        self.encodedVideoSize = encodedVideoSize
        self.canvasSize = canvasSize
        self.alphaMode = alphaMode
        self.frameCount = frameCount
        self.duration = duration
        self.containsAudio = containsAudio
        self.codec = codec
        super.init()
    }
}
