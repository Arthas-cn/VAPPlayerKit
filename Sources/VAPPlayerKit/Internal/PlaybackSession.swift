import Foundation

/// 一次播放的状态机。终态（finished / failed / stopping 完成后）不能回到 playing。
enum SessionState: Equatable {
    /// 刚创建，尚未开始解析。
    case idle
    /// 正在解析 vapc / 创建 decoder / 等待动态内容。
    case preparing
    /// metadata 与 pipeline 就绪，尚未出第一帧。
    case ready
    /// 正在按媒体时钟消费帧。
    case playing
    /// 宿主 pause，时钟冻结。
    case paused
    /// 离屏、后台或 drawable 暂不可用。不是完成。
    case suspended
    /// 正常播完。
    case finished
    /// 正在取消 decoder / GPU / audio，随后进入 finished 或释放。
    case stopping
    /// 不可恢复错误。
    case failed
}

/// 一次 play 对应一个全新 session，不复用上一次的 decoder、clock、buffer 或动态资源。
///
/// 对照 `vap-master` 把解码、缓冲、渲染散落在 UIView category 中的做法，这里所有权收口到 session。
final class PlaybackSession {
    /// 所有异步回调都必须核对的令牌。不匹配则丢弃。
    let token: SessionToken
    /// 本次播放的本地文件。
    let url: URL
    /// session 持有的 options 副本。
    let options: PlaybackOptions

    private(set) var state: SessionState = .idle
    private let inspector = AssetInspector()
    private let frameSource: FrameSource
    private let ringBuffer = FrameRingBuffer()
    private let clock = MediaClock()
    private let renderer = MetalRenderer()
    private let dynamicResolver = DynamicResolver()
    private let audioCoordinator = AudioCoordinator()

    /// 默认生产后端是 VideoToolbox。测试可注入对照后端。
    init(url: URL, options: PlaybackOptions, frameSource: FrameSource = VideoToolboxFrameSource()) {
        self.token = .make()
        self.url = url
        self.options = options
        self.frameSource = frameSource
    }

    /// 仅 playing 可进入 paused。
    func pause() {
        guard state == .playing else { return }
        state = .paused
        frameSource.pause()
        clock.pause()
        audioCoordinator.pause()
    }

    /// paused 或 suspended 才可恢复。
    func resume() {
        guard state == .paused || state == .suspended else { return }
        state = .playing
        clock.resume()
        audioCoordinator.resume()
    }

    /// 停止生产、回收 GPU、清空 buffer。Phase 2 会补齐 VT teardown 等待。
    func stop() {
        state = .stopping
        frameSource.cancel()
        audioCoordinator.stop()
        ringBuffer.removeAll()
        renderer.dispose()
        state = .finished
    }
}
