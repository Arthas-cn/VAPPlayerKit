import Foundation
import UIKit

struct AnimatedDynamicSlot: @unchecked Sendable {
    let provider: UIImage
    let firstFrame: UIImage
    let source: VapcSource
}

/// Drives SDWebImage animated slot textures for the lifetime of one VAP session.
@MainActor
final class AnimatedDynamicPlayback {
    private weak var renderer: MetalRenderer?
    private var players: [SDWebImageRuntime.Player] = []
    private var generation: UInt64 = 0

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

    func start() {
        for player in players { player.start() }
    }

    func pause() {
        for player in players { player.pause() }
    }

    func stop() {
        generation &+= 1
        let stopping = players
        players.removeAll()
        for player in stopping { player.stop() }
        renderer = nil
    }

    private func apply(id: String, source: VapcSource, frame: UIImage) {
        renderer?.updateDynamicTexture(id: id, image: DynamicResolver.resized(frame, source: source))
    }
}
