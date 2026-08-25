import Foundation
import Metal

/// 通过 `Bundle.module` 定位 Metal shader，禁止假设 main bundle 或工作目录相对路径。
enum ShaderLibrary {
    /// 优先加载编译好的 metallib；否则读 `.metal` 源码运行时编译；再否则尝试 default library。
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

    /// 测试用：metallib 或 metal 源码任一存在即视为资源打包成功。
    static var shaderResourceURL: URL? {
        metallibURL ?? metalSourceURL
    }

    /// `.process("Resources")` 后可能生成 `VPKShaders.metallib` 或 `default.metallib`。
    static var metallibURL: URL? {
        Bundle.module.url(forResource: "VPKShaders", withExtension: "metallib", subdirectory: "Shaders")
            ?? Bundle.module.url(forResource: "VPKShaders", withExtension: "metallib")
            ?? Bundle.module.url(forResource: "default", withExtension: "metallib")
    }

    /// 回退用的 `.metal` 源码路径，供运行时编译。
    static var metalSourceURL: URL? {
        Bundle.module.url(forResource: "VPKShaders", withExtension: "metal", subdirectory: "Shaders")
            ?? Bundle.module.url(forResource: "VPKShaders", withExtension: "metal")
    }

    /// 读取 metal 源码文本。资源缺失时返回 nil，由 `make` 继续尝试 default library。
    private static var metalSource: String? {
        guard let url = metalSourceURL else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }
}
