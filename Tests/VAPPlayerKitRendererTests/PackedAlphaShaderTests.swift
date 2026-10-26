import Metal
import Testing
@testable import VAPPlayerKit

/// 直接执行正式 Metal shader，验证任意矩形的灰度 Alpha 及预乘颜色输出。
struct PackedAlphaShaderTests {
    /// 黑、灰、白分别应输出透明、半透明、不透明；左右/上下及反向区域都不得猜半幅。
    @Test(arguments: [AlphaMode.left, .right, .top, .bottom], [UInt8(16), 126, 235])
    func samplesDeclaredRegions(direction: AlphaMode, alpha: UInt8) async throws {
        let rectangles = regions(direction: direction)
        var luma = [UInt8](repeating: 16, count: 16 * 12)
        fill(&luma, rect: rectangles.color, value: 235)
        fill(&luma, rect: rectangles.alpha, value: alpha)
        let chroma = [UInt8](repeating: 128, count: 8 * 6 * 2)
        let pixel = try await render(
            luma: luma, chroma: chroma, rectangles: rectangles, width: 1, height: 1
        )
        let expected = Int((Double(Int(alpha) - 16) / 219 * 255).rounded())
        #expect(abs(Int(pixel[3]) - expected) <= 2)
        for color in pixel.prefix(3) {
            #expect(abs(Int(color) - expected) <= 3)
        }
    }

    /// 不等大奇数区域放大后，四条边必须保持恒定 Alpha/白色，不混入外邻区黑色及强色度。
    @Test(arguments: [AlphaMode.left, .right, .top, .bottom])
    func magnifiedEdgesExcludeNeighboringLumaAndChroma(direction: AlphaMode) async throws {
        let rectangles = regions(direction: direction)
        var luma = [UInt8](repeating: 16, count: 16 * 12)
        fill(&luma, rect: rectangles.color, value: 235)
        fill(&luma, rect: rectangles.alpha, value: 126)

        // 区域外填强色度，仅覆盖颜色矩形的 NV12 色度 texel 为中性；没有 CPU 预合成。
        var chroma = [UInt8](repeating: 0, count: 8 * 6 * 2)
        for index in stride(from: 0, to: chroma.count, by: 2) {
            chroma[index] = 16
            chroma[index + 1] = 240
        }
        fillNeutralChroma(&chroma, colorRect: rectangles.color)
        let width = rectangles.color.width * 4
        let height = rectangles.color.height * 4
        let pixels = try await render(
            luma: luma, chroma: chroma, rectangles: rectangles, width: width, height: height
        )
        let expected = Int((110.0 / 219 * 255).rounded())
        for y in 0..<height {
            for x in 0..<width {
                // 中央像素由原有用例覆盖；这里逐一检查最容易采入邻区的四条边及角落。
                guard x == 0 || y == 0 || x == width - 1 || y == height - 1 else { continue }
                let offset = (y * width + x) * 4
                #expect(abs(Int(pixels[offset + 3]) - expected) <= 2, "边缘 (\(x), \(y)) 的 Alpha 应保持恒定")
                for channel in 0..<3 {
                    #expect(abs(Int(pixels[offset + channel]) - expected) <= 3, "边缘 (\(x), \(y)) 不应采入外部亮度或色度")
                }
            }
        }
    }

    /// 把原始 Y/UV 平面直接提交给正式 fragment，并在 GPU 完成后读取完整 RGBA 输出。
    private func render(
        luma: [UInt8],
        chroma: [UInt8],
        rectangles: (color: VideoPixelRect, alpha: VideoPixelRect),
        width: Int,
        height: Int
    ) async throws -> [UInt8] {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let library = try ShaderLibrary.make(device: device)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "vpk_vertex")
        descriptor.fragmentFunction = library.makeFunction(name: "vpk_fragment")
        descriptor.colorAttachments[0].pixelFormat = .rgba8Unorm
        let pipeline = try await device.makeRenderPipelineState(descriptor: descriptor)
        let queue = try #require(device.makeCommandQueue())
        let command = try #require(queue.makeCommandBuffer())
        let yTexture = try texture(device: device, width: 16, height: 12, format: .r8Unorm)
        yTexture.replace(region: MTLRegionMake2D(0, 0, 16, 12), mipmapLevel: 0, withBytes: luma, bytesPerRow: 16)
        let uvTexture = try texture(device: device, width: 8, height: 6, format: .rg8Unorm)
        uvTexture.replace(region: MTLRegionMake2D(0, 0, 8, 6), mipmapLevel: 0, withBytes: chroma, bytesPerRow: 16)
        let output = try texture(device: device, width: width, height: height, format: .rgba8Unorm)
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = output
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        let encoder = try #require(command.makeRenderCommandEncoder(descriptor: pass))
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(yTexture, index: 0)
        encoder.setFragmentTexture(uvTexture, index: 1)
        var uniforms = ShaderUniforms(color: normalized(rectangles.color), alpha: normalized(rectangles.alpha))
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<ShaderUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        // 读取必须等 GPU 真正结束；不以提交成功或固定延时替代完成证据。
        await withCheckedContinuation { continuation in
            command.addCompletedHandler { _ in continuation.resume() }
            command.commit()
        }
        #expect(command.status == .completed)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        output.getBytes(&pixels, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        return pixels
    }

    /// 中性化与颜色区相交的色度 texel；NV12 每个 texel 覆盖 2×2 亮度像素。
    private func fillNeutralChroma(_ chroma: inout [UInt8], colorRect: VideoPixelRect) {
        // 奇数边缘与邻区共用一个原始色度 texel，保留这一事实而非伪造独立全分辨率 UV。
        let firstX = colorRect.x / 2
        let firstY = colorRect.y / 2
        let endX = (colorRect.x + colorRect.width + 1) / 2
        let endY = (colorRect.y + colorRect.height + 1) / 2
        for y in firstY..<endY {
            for x in firstX..<endX {
                let offset = (y * 8 + x) * 2
                chroma[offset] = 128
                chroma[offset + 1] = 128
            }
        }
    }

    /// 创建允许 CPU 填入与读回的共享纹理，供真实 shader 的离屏渲染使用。
    private func texture(device: any MTLDevice, width: Int, height: Int, format: MTLPixelFormat) throws -> any MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false)
        descriptor.usage = [.shaderRead, .renderTarget]
        descriptor.storageMode = .shared
        return try #require(device.makeTexture(descriptor: descriptor))
    }

    /// 选择互不等大的奇数区域并保留边缘留白，防止对半实现偶然通过。
    private func regions(direction: AlphaMode) -> (color: VideoPixelRect, alpha: VideoPixelRect) {
        switch direction {
        // 左 Alpha、右颜色的两个区域宽高不同。
        case .left:
            return (.init(x: 9, y: 2, width: 5, height: 7), .init(x: 1, y: 1, width: 3, height: 5))
        // 右 Alpha 使用相反顺序，其余约束相同。
        case .right:
            return (.init(x: 1, y: 2, width: 5, height: 7), .init(x: 9, y: 1, width: 3, height: 5))
        // 上 Alpha 不要求两个区域各占编码高度的一半。
        case .top:
            return (.init(x: 2, y: 7, width: 7, height: 3), .init(x: 1, y: 1, width: 5, height: 3))
        // 下 Alpha 与顶部颜色分别独立采样。
        case .bottom:
            return (.init(x: 2, y: 1, width: 7, height: 3), .init(x: 1, y: 7, width: 5, height: 3))
        // 参数集合不会传 none；保留确定返回值使辅助函数覆盖整个枚举。
        case .none:
            return (.init(x: 0, y: 0, width: 1, height: 1), .init(x: 2, y: 0, width: 1, height: 1))
        }
    }

    /// 将像素区域填为固定亮度，测试预期不依赖生产布局帮助函数。
    private func fill(_ pixels: inout [UInt8], rect: VideoPixelRect, value: UInt8) {
        for y in rect.y..<(rect.y + rect.height) {
            for x in rect.x..<(rect.x + rect.width) { pixels[y * 16 + x] = value }
        }
    }

    /// 按本测试的完整编码尺寸归一化任意区域。
    private func normalized(_ rect: VideoPixelRect) -> SIMD4<Float> {
        SIMD4(Float(rect.x) / 16, Float(rect.y) / 12, Float(rect.width) / 16, Float(rect.height) / 12)
    }
}

/// 与正式 fragment buffer ABI 对齐的输入，测试直接绑定 Metal 函数而不复制 shader 算法。
private struct ShaderUniforms {
    /// 颜色区的归一化原点与尺寸。
    var color: SIMD4<Float>
    /// Alpha 区的归一化原点与尺寸。
    var alpha: SIMD4<Float>
    /// 选择 BT.709；中性色输入使此测试只验证 Alpha 合成。
    var colorMatrix: UInt32 = 1
    /// 明确打开 Alpha，普通视频分支不参与此组输入。
    var alphaEnabled: UInt32 = 1
    /// 对齐正式 Metal 结构体的尾部 padding。
    var padding = SIMD2<UInt32>(repeating: 0)
}
