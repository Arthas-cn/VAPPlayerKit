import CoreMedia
import Foundation
import QuartzCore

/// session 的解码生产与逐帧提交；只在播放时驱动，终态通过主状态机收口。
extension PlaybackSession {
    /// 启动或重启解码生产。每个循环都会新建一次 reader，旧回调靠 generation 丢弃。
    func startSource(startTime: CMTime = .zero, frameIndexOffset: Int = 0) {
        sourceGeneration &+= 1
        let currentSourceGeneration = sourceGeneration
        ringBuffer.reset()
        sourceEnded = false
        pendingFrame = nil
        lastFrameEndTime = nil
        let sink = metricsSink
        let peak = RingBufferPeakRecorder(sink: sink)
        let buffer = ringBuffer
        frameSource.startProducing(
            to: buffer,
            token: token,
            startTime: startTime,
            frameIndexOffset: frameIndexOffset,
            didProduce: { [weak self, token] count in
                sink?.record(.decodedFrame)
                peak.recordIfNeeded(count)
                Task { @MainActor in
                    guard
                        let self,
                        self.token == token,
                        self.sourceGeneration == currentSourceGeneration,
                        !self.terminalDelivered
                    else { return }
                    self.startTimelineIfReady()
                }
            },
            completion: { [weak self, token] result in
                Task { @MainActor in
                    guard
                        let self,
                        self.token == token,
                        self.sourceGeneration == currentSourceGeneration,
                        !self.terminalDelivered
                    else { return }
                    switch result {
                    // 生产结束不等于呈现结束；保留缓冲帧让媒体时钟继续消费。
                    case .success:
                        self.sourceEnded = true
                        // 从未有可播帧的空输出不能作为一次成功播放完成。
                        if !self.timelineStarted, self.ringBuffer.count == 0 {
                            self.fail(PlaybackError.decoderFailed(osStatus: -1))
                        } else {
                            // 已有帧仍需通过音频与运行态门，不能在暂停时强行启动。
                            self.startTimelineIfReady()
                        }
                    // 挂起引发的 reader 退出可恢复，真实运行故障才终结当前会话。
                    case .failure(let error):
                        // 系统挂起后保留重建意图，不让旧 reader 的错误覆盖安全暂停。
                        if self.state == .suspended || self.decoderNeedsRestart {
                            self.decoderNeedsRestart = true
                        // 主动取消已由所属控制路径结算；只有非取消错误另行报告失败。
                        } else if error.code != .cancelled {
                            self.fail(error)
                        }
                    }
                }
            }
        )
    }

    /// 以 vapc fps 把恢复位置映射到动态 attachment 的原始 frame index。
    func frameIndex(for mediaSeconds: TimeInterval) -> Int {
        guard let inspection else { return 0 }
        let fps = Double(max(1, inspection.vapc.framesPerSecond))
        let index = Int((mediaSeconds * fps).rounded(.down))
        return min(max(0, index), max(0, inspection.vapc.frameCount - 1))
    }

    /// 在主 run loop 上订阅 VSYNC，每次只询问当前 media time。
    func startPacer() {
        pacer.start { [weak self] in
            self?.tick()
        }
    }

    /// 缓冲里已有帧、音频就绪且仍在 playing 时启动媒体时钟并回调 start。
    func startTimelineIfReady() {
        guard state == .playing, !timelineStarted, audioReady, ringBuffer.count > 0 else { return }
        timelineStarted = true
        clock.resume()
        audioCoordinator.start()
        marqueePlayback.start()
        startPacer()
        if !startDelivered {
            startDelivered = true
            onStart?()
        }
    }

    /// VSYNC 回调：取出到期帧、提交 GPU，并在本循环播完时进入 completeLoop。
    /// 上一帧 GPU 未完成时跳过本次 tick，避免堆积 command buffer。
    func tick() {
        guard state == .playing, timelineStarted, let inspection else { return }
        let mediaSeconds = clock.currentMediaTime()
        let mediaTime = CMTime(seconds: mediaSeconds, preferredTimescale: 600)
        guard !renderPending else { return }
        let due = ringBuffer.dequeueDue(at: mediaTime)
        var dropped = due.dropped
        var frame = pendingFrame
        if let newerFrame = due.frame {
            if frame != nil { dropped += 1 }
            frame = newerFrame
            pendingFrame = nil
        }
        if dropped > 0 {
            for _ in 0..<dropped { metricsSink?.record(.droppedFrame) }
        }
        if let frame {
            guard frame.token == token else { return }
            let frameEnd = CMTimeAdd(frame.presentationTime, frame.duration).seconds
            if frameEnd.isFinite {
                lastFrameEndTime = max(lastFrameEndTime ?? frameEnd, frameEnd)
            }
            renderPending = true
            let currentRenderGeneration = renderGeneration
            let currentPlayStart = playStartedAt
            let metricsSink = self.metricsSink
            let firstSubmissionGate = self.firstSubmissionGate
            marqueePlayback.apply()
            renderer.render(frame, vapc: inspection.vapc, didSubmit: { submittedAt in
                metricsSink?.record(.renderedFrame)
                if firstSubmissionGate.claim() {
                    metricsSink?.record(.firstFrameDuration(submittedAt - currentPlayStart))
                }
            }) { [weak self, token] result in
                Task { @MainActor in
                    guard
                        let self,
                        self.token == token,
                        self.renderGeneration == currentRenderGeneration,
                        !self.terminalDelivered
                    else { return }
                    self.renderPending = false
                    switch result {
                    // GPU 真正完成后才消费待呈现帧并确认首帧，不以提交动作冒充呈现。
                    case .success(true):
                        self.pendingFrame = nil
                        self.marqueePlayback.notePresented(frame: frame, vapc: inspection.vapc)
                        // 首帧事件只交付一次，循环与后续帧不能反复解除宿主遮挡。
                        if !self.firstFrameDelivered {
                            self.firstFrameDelivered = true
                            self.onFirstFrame?()
                        }
                    // 暂时没有 drawable 不丢掉这一帧，后续 tick 可在表面恢复时重试。
                    case .success(false):
                        self.pendingFrame = frame
                        self.metricsSink?.record(.metalDrawableFailure)
                    // 挂起或主动取消由生命周期处理；其他渲染错误才是不可恢复失败。
                    case .failure(let error):
                        if self.state != .suspended, error.code != .cancelled { self.fail(error) }
                    }
                }
            }
        }
        if Self.shouldCompleteLoop(
            sourceEnded: sourceEnded,
            bufferedFrameCount: ringBuffer.count,
            hasPendingFrame: pendingFrame != nil,
            renderPending: renderPending,
            lastFrameEndTime: lastFrameEndTime,
            mediaTime: mediaSeconds
        ) {
            completeLoop()
        }
    }

}

/// 解码回调在非主线程；在 decoder queue 上记录 ring buffer 峰值，避免每帧 hop 到 actor。
private final class RingBufferPeakRecorder: @unchecked Sendable {
    /// 保护跨解码回调更新的峰值统计。
    private let lock = NSLock()
    /// 宿主提供的线程安全接收者，统计器不延长其业务生命周期。
    private weak var sink: MetricsSink?
    /// 本次生产周期见过的最大缓冲占用。
    private var peak = 0

    /// 为一次 producer 绑定可选指标接收者，峰值从零开始。
    init(sink: MetricsSink?) {
        self.sink = sink
    }

    /// 仅在峰值升高时上报，避免每帧都打点。
    func recordIfNeeded(_ count: Int) {
        lock.lock()
        guard count > peak else {
            lock.unlock()
            return
        }
        peak = count
        let sink = sink
        lock.unlock()
        sink?.record(.ringBufferPeak(count))
    }
}
