import Foundation
import UIKit

/// 一次 session 里需要按帧驱动的动图槽位。
struct AnimatedDynamicSlot: @unchecked Sendable {
    /// 宿主传入的 `SDAnimatedImage`。组件不持有解码器实现，只通过 runtime bridge 取帧。
    let provider: UIImage
    /// 已按槽位缩放的第一帧，prepare 阶段即可上传。
    let firstFrame: UIImage
    let source: VapcSource
}

/// 在单个 VAP session 生命周期内驱动 SDWebImage 动图槽位纹理。
@MainActor
final class AnimatedDynamicPlayback {
    private weak var renderer: MetalRenderer?
    private var players: [SDWebImageRuntime.Player] = []
    /// stop 后递增，使过期帧回调丢弃。
    private var generation: UInt64 = 0

    /// 为 snapshot 中的 animated 槽位创建 player。静图槽位忽略。
    func prepare(snapshot: DynamicSnapshot, renderer: MetalRenderer) {
        stop()
        self.renderer = renderer
        let currentGeneration = generation
        for (id, content) in snapshot.contents {
            guard case .animated(let slot) = content else { continue }
            guard let player = SDWebImageRuntime.makePlayer(provider: slot.provider, onFrame: { [weak self] _, frame in
                Task { @MainActor in
                    guard let self, self.generation == currentGeneration else { return }
                    self.apply(id: id, source: slot.source, frame: frame)
                }
            }) else {
                continue
            }
            players.append(player)
        }
    }

    /// 与视频时钟同时开始出帧。
    func start() {
        for player in players { player.start() }
    }

    /// 暂停动图，不释放 player。
    func pause() {
        for player in players { player.pause() }
    }

    /// 停止并释放全部 player，使后续帧回调失效。
    func stop() {
        generation &+= 1
        let stopping = players
        players.removeAll()
        for player in stopping { player.stop() }
        renderer = nil
    }

    /// 把新帧缩放到槽位后替换 Metal 纹理。
    private func apply(id: String, source: VapcSource, frame: UIImage) {
        renderer?.updateDynamicTexture(id: id, image: DynamicResolver.resized(frame, source: source))
    }
}
