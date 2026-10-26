import AVFoundation
import Foundation

/// 系统驱动与音频状态机交换的纯值事件，不跨线程传 AVPlayerItem。
enum AudioDriverEvent: Sendable {
    /// item 已能播放；仍须同时通过 asset 可播放检查。
    case ready
    /// item 状态失败或未能播放到末尾；原因不包含用户文件路径。
    case failed(PlaybackError)
    /// asset 异步属性加载已经成功完成。
    case assetPlayable
    /// 调用方取消当前准备，仅结束这一运行。
    case cancelled
    /// 当前准备时间预算耗尽，不代表底层操作已结束。
    case timedOut
}

/// 系统驱动工厂；事件闭包可以从 KVO 或通知线程调用。
typealias AudioDriverFactory = @MainActor (URL, @escaping @Sendable (AudioDriverEvent) -> Void) -> any AudioPlaybackDriver

/// 准备超时依赖；必须响应协作取消，非合作实现会延长真实收尾。
typealias AudioPreparationSleep = @MainActor @Sendable (Duration) async throws -> Void

/// 音频系统边界；状态机拥有其异步调用任务，测试实现可手动完成这些调用。
@MainActor
protocol AudioPlaybackDriver: AnyObject {
    /// 当前实例是否静音，不修改其他播放器或全局 AVAudioSession。
    var isMuted: Bool { get set }
    /// 完成 asset 可播放性检查；取消也必须在底层 load 实际返回之后退出。
    func loadPlayable() async throws
    /// 启动已经 ready 的音频。
    func play()
    /// 保留当前位置暂停音频。
    func pause()
    /// 等待系统定位完成；false 表示被打断或未成功定位。
    func seek(to seconds: TimeInterval) async -> Bool
    /// 同步关门、取消属性加载/定位并解除 item；异步调用仍由上层等待。
    func stop()
}

/// AVFoundation 实现；所有对象访问隔离到 MainActor，观察者只投递 Sendable 事件。
@MainActor
final class AVFoundationAudioDriver: AudioPlaybackDriver {
    /// 使用本地 URL 创建的资产，停止时取消其仍在途的属性加载。
    private let asset: AVURLAsset
    /// 与此运行绑定的唯一 item，直到真实异步工作收尾才释放。
    private let item: AVPlayerItem
    /// 只服务本次内嵌音轨的播放器，不拥有 App 的音频会话策略。
    private let player: AVPlayer
    /// 持有系统观察与清理闭包；非隔离析构只移交，不跨执行器操作播放器。
    private nonisolated let lifetimeOwner = PlaybackLifetimeOwner()
    /// stop 幂等门，防止清理时重复操作系统对象。
    private var isStopped = false
    /// 音频实例静音状态；准备前设置不会触发播放。
    var isMuted: Bool {
        get { player.isMuted }
        set { player.isMuted = newValue }
    }

    /// 创建暂停的 item/player 并观察 readiness；不在初始化中启动播放。
    init(url: URL, events: @escaping @Sendable (AudioDriverEvent) -> Void) {
        asset = AVURLAsset(url: url)
        item = AVPlayerItem(asset: asset)
        player = AVPlayer()
        player.actionAtItemEnd = .pause
        let statusObservation = item.observe(\.status, options: [.initial, .new]) { _, change in
            switch change.newValue {
            // ready 事件只是一个门，异步 asset 检查仍由上层合并。
            case .readyToPlay?:
                events(.ready)
            // 不跨线程转交 item.error，错误描述保持稳定且不泄露文件路径。
            case .failed?:
                events(.failed(.audioFailed(reason: "Embedded audio item failed.")))
            // unknown 不是失败，继续等待 ready 或准备超时。
            default:
                break
            }
        }
        let failureObservation = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: item,
            queue: nil
        ) { _ in
            events(.failed(.audioFailed(reason: "Embedded audio failed before reaching its end.")))
        }
        lifetimeOwner.retainObservation(failureObservation)
        // 闭包独立持有系统对象，不捕获 driver；正常 stop 同步执行，遗漏停止才由主队列接管。
        lifetimeOwner.replaceCleanup { [asset, item, player, statusObservation] in
            player.pause()
            statusObservation.invalidate()
            asset.cancelLoading()
            item.cancelPendingSeeks()
            player.replaceCurrentItem(with: nil)
        }
        player.replaceCurrentItem(with: item)
    }

    /// 显式非隔离析构不触发旧系统 executor-hop；系统对象保留到主队列清理执行完毕。
    nonisolated deinit { lifetimeOwner.cancelAndScheduleCleanup() }

    /// 使用系统 async 属性加载；失败交由状态机统一归类和排空。
    func loadPlayable() async throws {
        // 停止先于此 Task 真正执行时，不再向 AVFoundation 发起新的加载。
        guard !isStopped else { throw PlaybackError.cancelled }
        let playable = try await asset.load(.isPlayable)
        // await 期间可能已经停止，迟到成功不能让准备屏障通过。
        guard !isStopped else { throw PlaybackError.cancelled }
        guard playable else {
            // 不可播放是准备失败，不能只靠 item 的初始 unknown 无限等待。
            throw PlaybackError.audioFailed(reason: "Embedded audio asset is not playable.")
        }
    }

    /// 仅对未停止的实例开始出声。
    func play() {
        // stop 后即使上层重复调用也不能重新发声。
        guard !isStopped else { return }
        player.play()
    }

    /// 同步停声，保留当前 item。
    func pause() { player.pause() }

    /// 等待 AVPlayer 原生异步定位，保留系统 finished 标志。
    func seek(to seconds: TimeInterval) async -> Bool {
        // 已关门的旧任务不应重新发起系统定位。
        guard !isStopped else { return false }
        player.pause()
        let time = CMTime(seconds: seconds, preferredTimescale: 600)
        return await player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    /// 撤销观察并取消真实系统操作；上层仍须等待 load 和 seek 的 async 返回。
    func stop() {
        // 重复停止不再次替换 item，也不会制造新的系统回调。
        guard !isStopped else { return }
        isStopped = true
        lifetimeOwner.cleanupNow()
    }
}
