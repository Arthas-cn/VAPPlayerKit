import Foundation
import QuartzCore
import simd
import UIKit

/// 一次 session 里需要按媒体无关时钟滑动的文字槽位。
struct MarqueeDynamicSlot: @unchecked Sendable {
    /// 预绘的 `[文字][间隙][文字]` 长条，高度等于槽位。
    let strip: UIImage
    /// 可见窗口宽度，与槽位栅格化像素宽一致。
    let slotWidth: CGFloat
    /// 无缝循环一圈的距离：`textWidth + gap`。
    let cycleWidth: CGFloat
    /// 长条纹理宽度，供 UV 归一化。
    let textureWidth: CGFloat
}

/// 跑马灯几何与时间偏移。纯函数，便于单测。
enum MarqueeLayout {
    static let defaultSpeed: CGFloat = 80
    static let defaultStartDelay: TimeInterval = 0.6
    /// 循环间隙，单位 pt。两份文字之间的空白。
    static let defaultGap: CGFloat = 25

    /// 循环间隙。与槽位宽度无关，固定 `defaultGap`。
    static func gap(slotWidth _: CGFloat) -> CGFloat {
        max(0, defaultGap)
    }

    /// 长条尺寸：两份文字加一份间隙。
    static func stripSize(textWidth: CGFloat, gap: CGFloat, slotHeight: CGFloat) -> CGSize {
        CGSize(width: textWidth + gap + textWidth, height: slotHeight)
    }

    /// 长条是否落在单张纹理的字节和边长预算内。
    static func canAllocateStrip(size: CGSize) -> Bool {
        guard
            let bytes = DynamicTextureLimits.byteCount(for: size),
            bytes <= DynamicTextureLimits.maximumBytesPerTexture
        else {
            return false
        }
        let width = ceil(size.width)
        let height = ceil(size.height)
        let maxDimension = CGFloat(DynamicTextureLimits.maximumTextureDimension)
        return width <= maxDimension && height <= maxDimension
    }

    /// 每个滚动循环都在开头停顿 `startDelay`，再按 `speed` 滑过 `cycleWidth`。
    static func offset(
        elapsed: TimeInterval,
        startDelay: TimeInterval,
        speed: CGFloat,
        cycleWidth: CGFloat
    ) -> CGFloat {
        guard cycleWidth > 0, speed > 0 else { return 0 }
        let delay = max(0, startDelay)
        let scrollDuration = TimeInterval(cycleWidth / speed)
        let cycleDuration = delay + scrollDuration
        guard cycleDuration > 0, elapsed.isFinite, elapsed >= 0 else { return 0 }
        var timeInCycle = elapsed.truncatingRemainder(dividingBy: cycleDuration)
        if timeInCycle < 0 { timeInCycle += cycleDuration }
        guard timeInCycle > delay else { return 0 }
        return min(cycleWidth, CGFloat(timeInCycle - delay) * speed)
    }

    /// 可见窗口在长条上的归一化 UV。
    static func sourceUV(
        offset: CGFloat,
        slotWidth: CGFloat,
        textureWidth: CGFloat
    ) -> (origin: SIMD2<Float>, size: SIMD2<Float>) {
        guard textureWidth > 0, slotWidth > 0 else {
            return (SIMD2(0, 0), SIMD2(1, 1))
        }
        return (
            SIMD2(Float(offset / textureWidth), 0),
            SIMD2(Float(slotWidth / textureWidth), 1)
        )
    }
}

/// 在单个 VAP session 内驱动文字跑马灯 UV。时钟与视频 loop 无关，pause / suspend 时冻结。
@MainActor
final class MarqueeDynamicPlayback {
    private weak var renderer: MetalRenderer?
    private var slots: [(id: String, slot: MarqueeDynamicSlot)] = []
    private var paused = true
    private var elapsed: TimeInterval = 0
    private var hostTimeOffset: TimeInterval = 0
    /// 首帧真正 present 且带有文字槽位后再锁存时钟，避免 GPU 等待把起步停顿吃掉。
    private var clockLatched = false
    private var speed: CGFloat = MarqueeLayout.defaultSpeed
    private var startDelay: TimeInterval = MarqueeLayout.defaultStartDelay

    /// 从 snapshot 收集 marquee 槽位。无跑马灯时后续为空操作。
    func prepare(
        snapshot: DynamicSnapshot,
        renderer: MetalRenderer,
        speed: CGFloat,
        startDelay: TimeInterval
    ) {
        stop()
        self.renderer = renderer
        self.speed = speed > 0 ? speed : MarqueeLayout.defaultSpeed
        self.startDelay = max(0, startDelay)
        slots = snapshot.contents.compactMap { id, content in
            guard case .marquee(let slot) = content else { return nil }
            return (id, slot)
        }
    }

    /// 把已播放时间归零并保持暂停，等 timeline 真正开始后再 `start()`。
    func resetClock() {
        elapsed = 0
        paused = true
        hostTimeOffset = 0
        clockLatched = false
    }

    /// 从当前 `elapsed` 恢复推进。已在走时再调用是空操作，避免视频循环把它拨回。
    /// 时钟要等到文字槽位真正 present 成功才锁定，保证起步停顿从看见开头开始算。
    func start() {
        guard paused, !slots.isEmpty else { return }
        paused = false
        if clockLatched {
            hostTimeOffset = CACurrentMediaTime() - elapsed
        }
    }

    /// 冻结已播放时间，不释放槽位。
    func pause() {
        guard !paused else { return }
        if clockLatched {
            elapsed = currentElapsed()
        }
        paused = true
    }

    /// 停止并丢掉槽位，使后续 apply 失效。
    func stop() {
        paused = true
        elapsed = 0
        hostTimeOffset = 0
        clockLatched = false
        slots.removeAll()
        renderer = nil
    }

    /// 文字槽位已经成功上屏后再开始计时。此前 `apply()` 始终停在开头。
    func notePresented(frame: DecodedFrame, vapc: VapcDocument) {
        guard !paused, !slots.isEmpty, !clockLatched else { return }
        let attachments = vapc.frames[frame.index] ?? []
        let visible = slots.contains { slot in
            attachments.contains { $0.sourceID == slot.id }
        }
        guard visible else { return }
        hostTimeOffset = CACurrentMediaTime() - elapsed
        clockLatched = true
    }

    /// 按当前已播放时间写入各槽位 UV。应在提交视频帧之前调用，与 render 同队列串行。
    func apply() {
        guard let renderer, !paused, !slots.isEmpty else { return }
        let time = clockLatched ? currentElapsed() : 0
        for (id, slot) in slots {
            let offset = MarqueeLayout.offset(
                elapsed: time,
                startDelay: startDelay,
                speed: speed,
                cycleWidth: slot.cycleWidth
            )
            let uv = MarqueeLayout.sourceUV(
                offset: offset,
                slotWidth: slot.slotWidth,
                textureWidth: slot.textureWidth
            )
            renderer.updateSourceUV(id: id, origin: uv.origin, size: uv.size)
        }
    }

    private func currentElapsed() -> TimeInterval {
        if paused || !clockLatched { return elapsed }
        return CACurrentMediaTime() - hostTimeOffset
    }
}
