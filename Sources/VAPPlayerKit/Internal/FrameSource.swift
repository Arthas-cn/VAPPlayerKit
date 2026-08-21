import Foundation
import CoreGraphics

protocol FrameSource: AnyObject {
    func prepare() async throws -> FrameSourceMetadata
    func startProducing(to buffer: FrameRingBuffer, token: SessionToken)
    func pause()
    func cancel()
}

struct FrameSourceMetadata {
    let encodedVideoSize: CGSize
    let codec: String
}
