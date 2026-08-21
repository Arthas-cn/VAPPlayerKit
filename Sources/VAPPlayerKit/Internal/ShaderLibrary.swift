import Foundation
import Metal

enum ShaderLibrary {
    static func make(device: MTLDevice) throws -> MTLLibrary {
        if let url = metallibURL {
            return try device.makeLibrary(URL: url)
        }
        if let source = metalSource {
            return try device.makeLibrary(source: source, options: nil)
        }
        if let library = try? device.makeDefaultLibrary(bundle: .module) {
            return library
        }
        throw PlaybackError.metalUnavailable
    }

    static var shaderResourceURL: URL? {
        metallibURL ?? metalSourceURL
    }

    static var metallibURL: URL? {
        Bundle.module.url(forResource: "VPKShaders", withExtension: "metallib", subdirectory: "Shaders")
            ?? Bundle.module.url(forResource: "VPKShaders", withExtension: "metallib")
            ?? Bundle.module.url(forResource: "default", withExtension: "metallib")
    }

    static var metalSourceURL: URL? {
        Bundle.module.url(forResource: "VPKShaders", withExtension: "metal", subdirectory: "Shaders")
            ?? Bundle.module.url(forResource: "VPKShaders", withExtension: "metal")
    }

    private static var metalSource: String? {
        guard let url = metalSourceURL else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }
}
