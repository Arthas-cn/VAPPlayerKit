import Foundation
import AVFoundation

/// 按 `AudioMode` 执行音频策略，不反向控制视频状态机。
@MainActor
final class AudioCoordinator {
    private var player: AVPlayer?
    private var mode: AudioMode = .muted

    func prepare(url: URL, mode: AudioMode, containsAudio: Bool) async throws {
        stop()
        self.mode = mode
        guard mode == .embedded, containsAudio else { return }
        let item = AVPlayerItem(url: url)
        do {
            guard try await item.asset.load(.isPlayable) else {
                throw PlaybackError.audioFailed(reason: "Embedded asset is not playable.")
            }
        } catch let error as PlaybackError {
            throw error
        } catch {
            throw PlaybackError.audioFailed(reason: "Embedded audio track cannot be prepared.")
        }
        let player = AVPlayer(playerItem: item)
        player.actionAtItemEnd = .pause
        player.isMuted = false
        self.player = player
    }

    func start() {
        guard mode == .embedded else { return }
        player?.play()
    }

    func pause() {
        player?.pause()
    }

    func resume() {
        guard mode == .embedded else { return }
        player?.play()
    }

    func rewind(completion: @MainActor @escaping () -> Void) {
        guard mode == .embedded, let player else {
            completion()
            return
        }
        player.pause()
        player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
            Task { @MainActor in completion() }
        }
    }

    func stop() {
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
    }
}
