import Foundation

enum SessionState: Equatable {
    case idle
    case preparing
    case ready
    case playing
    case paused
    case suspended
    case finished
    case stopping
    case failed
}

final class PlaybackSession {
    let token: SessionToken
    let url: URL
    let options: PlaybackOptions

    private(set) var state: SessionState = .idle
    private let inspector = AssetInspector()
    private let frameSource: FrameSource
    private let ringBuffer = FrameRingBuffer()
    private let clock = MediaClock()
    private let renderer = MetalRenderer()
    private let dynamicResolver = DynamicResolver()
    private let audioCoordinator = AudioCoordinator()

    init(url: URL, options: PlaybackOptions, frameSource: FrameSource = VideoToolboxFrameSource()) {
        self.token = .make()
        self.url = url
        self.options = options
        self.frameSource = frameSource
    }

    func pause() {
        guard state == .playing else { return }
        state = .paused
        frameSource.pause()
        clock.pause()
        audioCoordinator.pause()
    }

    func resume() {
        guard state == .paused || state == .suspended else { return }
        state = .playing
        clock.resume()
        audioCoordinator.resume()
    }

    func stop() {
        state = .stopping
        frameSource.cancel()
        audioCoordinator.stop()
        ringBuffer.removeAll()
        renderer.dispose()
        state = .finished
    }
}
