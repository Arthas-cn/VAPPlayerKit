import Foundation
import Metal
import CoreVideo

/// 将 YUV pixel buffer、Alpha 布局和动态纹理合到 `CAMetalLayer`。
///
/// 对照 `vap-master` 的 `QGHWDMetalRenderer` / `QGVAPMetalRenderer`。
/// Phase 0 只负责创建设备、队列和 shader library，不提交 command buffer。
final class MetalRenderer {
    private var device: MTLDevice?
    private var commandQueue: MTLCommandQueue?
    private var library: MTLLibrary?

    /// 预热 device / queue / shader。失败抛 `metalUnavailable`。不得在主线程编译 pipeline 的长路径上阻塞 UI（后续会异步预热）。
    func prepare() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw PlaybackError.metalUnavailable
        }
        guard let commandQueue = device.makeCommandQueue() else {
            throw PlaybackError.metalUnavailable
        }
        self.device = device
        self.commandQueue = commandQueue
        self.library = try ShaderLibrary.make(device: device)
    }

    /// 释放 per-session GPU 对象。Phase 2 会等待 command buffer completion 再释放纹理。
    func dispose() {
        library = nil
        commandQueue = nil
        device = nil
    }
}
