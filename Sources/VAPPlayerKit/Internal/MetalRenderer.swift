import Foundation
import Metal
import CoreVideo

final class MetalRenderer {
    private var device: MTLDevice?
    private var commandQueue: MTLCommandQueue?
    private var library: MTLLibrary?

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

    func dispose() {
        library = nil
        commandQueue = nil
        device = nil
    }
}
