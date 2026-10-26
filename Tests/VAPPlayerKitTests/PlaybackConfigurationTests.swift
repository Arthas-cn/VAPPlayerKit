import Testing
import UIKit
@testable import VAPPlayerKit

/// 覆盖 v2 配置快照、明确默认路由和非法参数的拒绝语义。
struct PlaybackConfigurationTests {
    /// 默认按 VAP 单轮播放，保留动态内容与内嵌音轨功能，并可通过校验。
    @Test func defaultsUseExplicitVAP() throws {
        let options = PlaybackOptions()
        try options.validate()
        #expect(options.assetMode == .vap)
        #expect(options.loopCount == 1)
        #expect(options.contentMode == .scaleAspectFit)
        #expect(options.audioMode == .embedded)
        #expect(options.clearsAfterFinish)
        #expect(options.backgroundPolicy == .suspend)
        #expect(options.automaticallyResumesAfterSuspension)
        #expect(options.dynamicImagePlaybackMode == .animated)
        #expect(options.dynamicTextOverflowMode == .truncate)
        #expect(options.marqueeSpeed == 80)
        #expect(options.marqueeStartDelay == 0.6)
    }

    /// 修改配置副本不会改动原快照；新增生命周期字段也参与值相等判断。
    @Test func copyHasIndependentValueSemantics() {
        let original = PlaybackOptions(assetMode: .ordinaryVideo, loopCount: 0)
        var changed = original
        changed.assetMode = .vap
        changed.loopCount = 2
        changed.dynamicImagePlaybackMode = .still
        changed.dynamicTextOverflowMode = .marquee
        changed.marqueeSpeed = 20
        changed.marqueeStartDelay = 1.2
        changed.automaticallyResumesAfterSuspension = false
        #expect(original.assetMode == .ordinaryVideo)
        #expect(original.loopCount == 0)
        #expect(original.dynamicImagePlaybackMode == .animated)
        #expect(original.dynamicTextOverflowMode == .truncate)
        #expect(original.marqueeSpeed == 80)
        #expect(original.marqueeStartDelay == 0.6)
        #expect(changed != original)
    }

    /// 非法循环、滚动时间与无对应渲染能力的 contentMode 都明确报 invalidArgument。
    @Test(arguments: [
        PlaybackOptions(loopCount: -1),
        PlaybackOptions(contentMode: .center),
        PlaybackOptions(marqueeSpeed: 0),
        PlaybackOptions(marqueeSpeed: -.infinity),
        PlaybackOptions(marqueeSpeed: .nan),
        PlaybackOptions(marqueeStartDelay: -1),
        PlaybackOptions(marqueeStartDelay: .infinity),
        PlaybackOptions(marqueeStartDelay: .nan)
    ])
    func invalidValuesAreRejected(_ options: PlaybackOptions) {
        #expect {
            try options.validate()
        } throws: { error in
            (error as? PlaybackError)?.code == .invalidArgument
        }
    }

    /// 透明布局形状错误保持专门错误码，不伪装成普通配置错误。
    @Test func invalidAlphaGeometryKeepsItsErrorCode() {
        let layout = PackedAlphaLayout(
            arrangement: .sideBySide,
            colorRect: VideoPixelRect(x: 0, y: 0, width: 10, height: 10),
            alphaRect: VideoPixelRect(x: 5, y: 0, width: 10, height: 10)
        )
        #expect {
            try PlaybackOptions(assetMode: .packedAlpha(layout)).validate()
        } throws: { error in
            (error as? PlaybackError)?.code == .invalidAlphaLayout
        }
    }
}
