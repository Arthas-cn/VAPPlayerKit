import Foundation
import CoreGraphics

final class AssetInspector {
    func inspect(url: URL) async throws -> AssetMetadata {
        guard url.isFileURL else {
            throw PlaybackError.invalidURL
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw PlaybackError.fileNotFound
        }

        // Phase 1 will parse moov / vapc and emit immutable metadata.
        // Phase 0 only proves the inspect pipeline and error mapping compile.
        throw PlaybackError.invalidMP4(reason: "AssetInspector is a Phase 1 parser stub.")
    }
}
