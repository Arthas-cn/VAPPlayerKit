import CoreGraphics
import Testing
@testable import VAPPlayerKit

/// 验证透明区域始终按显式整数矩形和声明轴解释，不套用 legacy 半幅规则。
struct PackedAlphaLayoutTests {
    /// 不等宽、奇数边与留白均合法；颜色区宽高保持原值。
    @Test func unevenOddRegionsPreserveTheirBounds() throws {
        let layout = PackedAlphaLayout(
            arrangement: .sideBySide,
            colorRect: VideoPixelRect(x: 1, y: 3, width: 101, height: 155),
            alphaRect: VideoPixelRect(x: 119, y: 7, width: 63, height: 77)
        )
        let mode = try layout.validatedAlphaMode(in: CGSize(width: 193, height: 173))
        #expect(mode == .right)
        #expect(layout.colorRect.cgRect == CGRect(x: 1, y: 3, width: 101, height: 155))
        #expect(layout.alphaRect.cgRect == CGRect(x: 119, y: 7, width: 63, height: 77))
    }

    /// Alpha 可以在颜色区四侧，使用声明轴决定方向，不固定颜色在左或上。
    @Test(arguments: [AlphaMode.left, .right, .top, .bottom])
    func supportsEitherSideOfDeclaredAxis(_ expected: AlphaMode) throws {
        let origin = VideoPixelRect(x: 0, y: 0, width: 3, height: 5)
        let horizontal = VideoPixelRect(x: 7, y: 0, width: 9, height: 5)
        let vertical = VideoPixelRect(x: 0, y: 11, width: 3, height: 7)
        let layout: PackedAlphaLayout
        switch expected {
        // 左 Alpha 时颜色区位于右侧。
        case .left:
            layout = PackedAlphaLayout(arrangement: .sideBySide, colorRect: horizontal, alphaRect: origin)
        // 右 Alpha 时颜色区位于左侧。
        case .right:
            layout = PackedAlphaLayout(arrangement: .sideBySide, colorRect: origin, alphaRect: horizontal)
        // 上 Alpha 时颜色区位于下侧。
        case .top:
            layout = PackedAlphaLayout(arrangement: .topBottom, colorRect: vertical, alphaRect: origin)
        // 下 Alpha 时颜色区位于上侧。
        case .bottom:
            layout = PackedAlphaLayout(arrangement: .topBottom, colorRect: origin, alphaRect: vertical)
        // 参数集合不包含普通视频；若误加该项则让测试明确失败。
        case .none:
            Issue.record("This test requires a packed Alpha direction.")
            return
        }
        #expect(try layout.validatedAlphaMode(in: CGSize(width: 19, height: 23)) == expected)
    }

    /// 两轴都分离时仍遵守 topBottom，而不是沿用旧解析器的 X 优先推断。
    @Test func diagonalRegionsRespectDeclaredAxis() throws {
        let layout = PackedAlphaLayout(
            arrangement: .topBottom,
            colorRect: VideoPixelRect(x: 20, y: 0, width: 5, height: 5),
            alphaRect: VideoPixelRect(x: 0, y: 20, width: 5, height: 5)
        )
        #expect(try layout.validatedAlphaMode(in: CGSize(width: 30, height: 30)) == .bottom)
    }

    /// 负坐标、非正尺寸、加法溢出、越界和声明轴不分离都返回 invalidAlphaLayout。
    @Test(arguments: [
        VideoPixelRect(x: -1, y: 0, width: 4, height: 4),
        VideoPixelRect(x: 0, y: -1, width: 4, height: 4),
        VideoPixelRect(x: 10, y: 0, width: 0, height: 4),
        VideoPixelRect(x: 10, y: 0, width: 4, height: -1),
        VideoPixelRect(x: .max, y: 0, width: 1, height: 4),
        VideoPixelRect(x: 10, y: .max, width: 4, height: 1),
        VideoPixelRect(x: 29, y: 0, width: 4, height: 4),
        VideoPixelRect(x: 10, y: 29, width: 4, height: 4),
        VideoPixelRect(x: 2, y: 10, width: 4, height: 4)
    ])
    func invalidRegionsAreRejected(_ alpha: VideoPixelRect) {
        let layout = PackedAlphaLayout(
            arrangement: .sideBySide,
            colorRect: VideoPixelRect(x: 0, y: 0, width: 5, height: 5),
            alphaRect: alpha
        )
        #expect {
            try layout.validatedAlphaMode(in: CGSize(width: 30, height: 30))
        } throws: { error in
            (error as? PlaybackError)?.code == .invalidAlphaLayout
        }
    }

    /// 实际检查含 vapc 的素材时，显式矩形必须覆盖其布局并清空动态槽。
    @Test func explicitLayoutBypassesEmbeddedVapc() async throws {
        let layout = PackedAlphaLayout(
            arrangement: .sideBySide,
            colorRect: VideoPixelRect(x: 1, y: 3, width: 251, height: 333),
            alphaRect: VideoPixelRect(x: 701, y: 7, width: 129, height: 127)
        )
        let inspection = try await AssetInspector().inspectDetails(
            url: VAPFixture.url("8.mp4"),
            assetMode: .packedAlpha(layout)
        )
        #expect(inspection.metadata.canvasSize == CGSize(width: 251, height: 333))
        #expect(inspection.metadata.alphaMode == .right)
        #expect(inspection.metadata.vapVersion == 0)
        #expect(inspection.metadata.dynamicSources.isEmpty)
        #expect(inspection.vapc.rgbRect == layout.colorRect.cgRect)
        #expect(inspection.vapc.alphaRect == layout.alphaRect.cgRect)
    }

    /// 显式区域超出真实视频帧时失败，不退回素材原有 vapc 或普通视频路径。
    @Test func inspectionRejectsOutOfBoundsLayout() async {
        let layout = PackedAlphaLayout(
            arrangement: .sideBySide,
            colorRect: VideoPixelRect(x: 0, y: 0, width: 100, height: 100),
            alphaRect: VideoPixelRect(x: 2000, y: 0, width: 100, height: 100)
        )
        await #expect {
            try await AssetInspector().inspect(url: VAPFixture.url("8.mp4"), assetMode: .packedAlpha(layout))
        } throws: { error in
            (error as? PlaybackError)?.code == .invalidAlphaLayout
        }
    }
}
