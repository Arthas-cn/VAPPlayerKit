import Foundation
import AVFoundation

/// 按 `AudioMode` 执行音频策略，不反向控制视频状态机。
@MainActor
final class AudioCoordinator {
    /// 仅 `embedded` 模式会创建。
    private var player: AVPlayer?
    private var mode: AudioMode = .muted

    /// 非 embedded 或容器无音轨时立即返回。embedded 会创建 AVPlayerItem。
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

    /// 与视频时钟启动对齐后开始出声。
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

    /// 解码器因前后台切换重建时，把内嵌音轨定位到视频冻结的媒体时间。
    func seek(to seconds: TimeInterval, completion: @MainActor @escaping () -> Void) {
        guard mode == .embedded, let player else {
            completion()
            return
        }
        player.pause()
        let safeSeconds = seconds.isFinite ? max(0, seconds) : 0
        let time = CMTime(seconds: safeSeconds, preferredTimescale: 600)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
            Task { @MainActor in completion() }
        }
    }

    /// 循环边界把内嵌音轨 seek 回零。无音频时立即 completion，不阻塞视频。
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

    /// 释放 AVPlayer，避免后台继续占用音频会话。
    func stop() {
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
    }
}
