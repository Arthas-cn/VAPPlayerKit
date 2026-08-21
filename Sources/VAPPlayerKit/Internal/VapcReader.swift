import Foundation
import CoreGraphics

struct VapcDocument {
    let version: Int
    let canvasSize: CGSize
    let alphaMode: AlphaMode
}

final class VapcReader {
    func read(from data: Data) throws -> VapcDocument {
        throw PlaybackError.invalidVapc(reason: "VapcReader is a Phase 1 parser stub.")
    }
}
