import UIKit
import VAPPlayerKit

/// 真机冒烟流程与条件等待；失败路径保留原报告和 UI 测试行为。
extension PlaybackDetailViewController {
    /// 验证元数据、三种缩放与暂停恢复，结果写入页面报告。
    func runAutomatedSmokeTest() async {
        defer {
            isAutomatedRun = false
            _ = diagnostics.persist(fixture: fixture)
        }
        diagnostics.append("TEST", "automated smoke test started")
        await playerView.clearAndWait()
        do {
            // 清理保证资源回收，但取消由页面流程自行检查。
            try Task.checkCancellation()
            let initialMetadata = try await playerView.prepare(url: fixture.url, options: currentOptions())
            try Task.checkCancellation()
            display(initialMetadata)
            // 可播放元数据必须同时拥有有效帧数、时长与画布。
            guard initialMetadata.frameCount > 0, initialMetadata.duration > 0,
                  initialMetadata.canvasSize.width > 0, initialMetadata.canvasSize.height > 0 else {
                throw SmokeTestError.invalidMetadata
            }
            diagnostics.append("PASS", "metadata invariants")
        } catch is CancellationError {
            // 页面退出或人工控制取消时，不把它算作负向素材验证成功。
            return
        } catch {
            // 负向 fixture 必须失败，不能把它记成合法素材回归失败。
            if !fixture.looksLikeMedia {
                stateLabel.text = "EXPECTED FAIL"
                diagnostics.append("PASS", "negative fixture rejected: \(error.localizedDescription)")
            } else {
                // 正常素材无法准备才是此用例的失败。
                stateLabel.text = "TEST FAILED"
                diagnostics.append("ERROR", "prepare: \(error.localizedDescription)")
            }
            return
        }

        let modes: [(String, UIView.ContentMode)] = [
            ("AspectFit", .scaleAspectFit),
            ("AspectFill", .scaleAspectFill),
            ("ScaleToFill", .scaleToFill)
        ]
        for (index, mode) in modes.enumerated() {
            // 人工操作取得控制权后，不再开始下一个缩放模式。
            guard !Task.isCancelled else { return }
            diagnostics.append("TEST", "case \(index + 1): \(mode.0)")
            currentDidStart = false
            currentFailure = nil
            currentFinishReason = nil
            let audio: AudioMode = index == modes.count - 1 && currentMetadata?.containsAudio == true ? .embedded : .muted
            var options = currentOptions(contentMode: mode.1, audioMode: audio)
            options.loopCount = 0
            options.clearsAfterFinish = false
            do {
                _ = try await playerView.prepare(url: fixture.url, options: options)
                let initialRenderedCount = diagnostics.renderedFrameCount
                playerView.play(url: fixture.url, options: options)
                try await waitForPlaybackEvidence(after: initialRenderedCount, timeout: 3)
                playerView.pause()
                stateLabel.text = "PAUSED"
                diagnostics.append("TEST", "pause")
                try await Task.sleep(nanoseconds: 250_000_000)
                let pausedRenderedCount = diagnostics.renderedFrameCount
                playerView.resume()
                stateLabel.text = "PLAYING"
                diagnostics.append("TEST", "resume")
                try await waitForRenderedFrame(after: pausedRenderedCount, timeout: 3)
                playerView.stop()
                // stop 的终态通知必须同步到达，不靠延时等待掩盖丢回调。
                guard currentFinishReason == .stopped else { throw SmokeTestError.missingStoppedCallback }
                diagnostics.append("PASS", "\(mode.0) lifecycle")
            } catch is CancellationError {
                // 取消只终止冒烟流程，新操作继续负责当前播放器。
                return
            } catch {
                // 某一模式失败立即结束，避免后续结果覆盖首个错误。
                diagnostics.append("ERROR", "\(mode.0): \(error.localizedDescription)")
                stateLabel.text = "TEST FAILED"
                return
            }
        }
        await playerView.clearAndWait()
        // 清理期间可能收到新人工动作，此时不覆盖它的 UI 状态。
        guard !Task.isCancelled else { return }
        stateLabel.text = "TEST PASSED"
        diagnostics.append("PASS", "all smoke cases completed")
    }

    /// 等待 started 和新增渲染帧，截止或错误时抛出。
    func waitForPlaybackEvidence(after renderedCount: Int, timeout: TimeInterval) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while ProcessInfo.processInfo.systemUptime < deadline {
            // 内核明确失败优先于等待超时。
            if let currentFailure { throw currentFailure }
            // 首次播放要求回调和真实帧共同成立。
            if currentDidStart, diagnostics.renderedFrameCount > renderedCount { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw SmokeTestError.playbackEvidenceTimeout
    }

    /// 等待恢复后的新增渲染帧，截止或错误时抛出。
    func waitForRenderedFrame(after renderedCount: Int, timeout: TimeInterval) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while ProcessInfo.processInfo.systemUptime < deadline {
            // 恢复后的解码错误不应被隐藏成一般超时。
            if let currentFailure { throw currentFailure }
            // 恢复不重新发 started，因此只等待新的帧证据。
            if diagnostics.renderedFrameCount > renderedCount { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw SmokeTestError.renderTimeout
    }

}
/// 页面内冒烟流程的可诊断失败，不替代播放器正式错误类型。
enum SmokeTestError: LocalizedError {
    /// 元数据缺少正数帧数、时长或画布。
    case invalidMetadata
    /// 截止前没有同时获得运行态与渲染帧。
    case playbackEvidenceTimeout
    /// 恢复后截止前没有新增渲染帧。
    case renderTimeout
    /// 主动停止后未收到 stopped 终态。
    case missingStoppedCallback

    /// 为页面报告提供稳定的测试失败说明。
    var errorDescription: String? {
        switch self {
        // 每种失败保持独立信息，便于报告定位具体证据缺失。
        case .invalidMetadata: return "Metadata invariants failed."
        // 首次启动需要运行态与帧双重证据。
        case .playbackEvidenceTimeout: return "Playback did not start and render a frame before timeout."
        // 恢复验证只等待新增帧，不要求重复 started。
        case .renderTimeout: return "Playback did not render a frame after resume before timeout."
        // 主动停止不能被自然完成回调替代。
        case .missingStoppedCallback: return "Stop did not emit the stopped terminal callback."
        }
    }
}
