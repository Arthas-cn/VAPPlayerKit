import Foundation
import Testing
import UIKit
@testable import VAPPlayerKit

/// SwiftUI 入口的身份、展示门、暂停与排空回归；不依赖网络、Metal 或设备时间。
@Suite(.timeLimit(.minutes(1)))
@MainActor
struct VAPPlayerViewTests {
    /// 无尺寸不开始准备；有尺寸后首次 prepare/play 各一次，同 ID 重绘保持稳定。
    @Test
    func waitsForPresentationAndDoesNotRestartOnRedraw() async throws {
        let harness = VAPSwiftUITestHarness(presentationAvailable: false)
        let request = harness.request()
        harness.submit(request)
        await harness.controller.waitForPendingWork()
        #expect(harness.factory.transports.isEmpty)
        #expect(harness.events(for: request) == [.waitingForPresentation])

        harness.controller.setPresentationAvailable(true)
        await harness.controller.waitForPendingWork()
        let transport = try #require(harness.factory.transports.first)
        for _ in 0..<10 { harness.submit(request) }
        await harness.controller.waitForPendingWork()
        #expect(harness.factory.transports.count == 1)
        #expect(transport.preparedRequests.count == 1)
        #expect(transport.playCount == 1)
        #expect(transport.resumeCount == 0)
        #expect(harness.events(for: request) == [.waitingForPresentation, .preparing, .ready, .started])
        await harness.close()
    }

    /// 初始暂停允许准备但不播放；首次播放走 play，之后恢复只调用 resume。
    @Test
    func initialPauseUsesPlayOnlyAfterExplicitStart() async throws {
        let harness = VAPSwiftUITestHarness()
        let request = harness.request()
        harness.submit(request, intent: .paused, muted: true)
        await harness.controller.waitForPendingWork()
        let transport = try #require(harness.factory.transports.first)
        #expect(transport.isMuted)
        #expect(transport.playCount == 0)

        harness.submit(request, revision: 1)
        harness.submit(request, intent: .paused, revision: 2)
        harness.submit(request, revision: 3)
        await harness.controller.waitForPendingWork()
        #expect(transport.playCount == 1)
        #expect(transport.resumeCount == 1)
        #expect(!transport.isMuted)
        #expect(harness.events(for: request).filter { $0 == .started }.count == 1)
        #expect(harness.events(for: request).contains(.resumed))
        await harness.close()
    }

    /// 首次 play 已发出但 started 延后时暂停并恢复，只恢复原会话且首次事件顺序正确。
    @Test
    func resumesPendingFirstStartWithoutIssuingAnotherPlay() async throws {
        let harness = VAPSwiftUITestHarness()
        harness.factory.configureNext = { $0.startsImmediately = false }
        let request = harness.request()
        harness.submit(request)
        await harness.controller.waitForPendingWork()
        let transport = try #require(harness.factory.transports.first)
        harness.submit(request, intent: .paused, revision: 1)
        harness.submit(request, revision: 2)
        await harness.controller.waitForPendingWork()
        #expect(transport.playCount == 1)
        #expect(transport.resumeCount == 1)
        #expect(!harness.events(for: request).contains(.resumed))
        #expect(!harness.events(for: request).contains(.started))

        transport.send(.started)
        await harness.controller.waitForPendingWork()
        #expect(harness.events(for: request).filter { $0 == .started }.count == 1)
        await harness.close()
    }

    /// 宿主有尺寸但未入窗仍不得准备，真实入窗之后才创建请求独占内核。
    @Test
    func hostRequiresBothAWindowAndPositiveBounds() async throws {
        let harness = VAPSwiftUITestHarness(presentationAvailable: false)
        let host = VAPSwiftUIHost()
        harness.controller.attach(to: host)
        host.frame = CGRect(x: 0, y: 0, width: 100, height: 100)
        host.refreshAvailability()
        harness.submit(harness.request())
        await harness.controller.waitForPendingWork()
        #expect(harness.factory.transports.isEmpty)

        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 200, height: 200)
        window.addSubview(host)
        host.refreshAvailability()
        await harness.controller.waitForPendingWork()
        #expect(harness.factory.transports.count == 1)
        await harness.close()
        host.removeFromSuperview()
    }

    /// 场景与音频中断恢复不能自动续播；新的控制版本才能解除系统暂停。
    @Test
    func systemPauseRequiresAnExplicitResumeCommand() async throws {
        let harness = VAPSwiftUITestHarness()
        let request = harness.request()
        harness.submit(request)
        await harness.controller.waitForPendingWork()
        let transport = try #require(harness.factory.transports.first)

        harness.submit(request, active: false)
        harness.submit(request, active: true)
        #expect(transport.resumeCount == 0)
        harness.submit(request, revision: 1)
        #expect(transport.resumeCount == 1)

        harness.controller.setAudioInterrupted(true)
        harness.submit(request, revision: 2)
        harness.controller.setAudioInterrupted(false)
        harness.submit(request, revision: 2)
        #expect(transport.resumeCount == 1)
        harness.submit(request, revision: 3)
        #expect(transport.resumeCount == 2)
        await harness.close()
    }

    /// 零尺寸恢复仅解除展示门，不能取消已经记录的用户暂停。
    @Test
    func restoringPresentationPreservesUserPause() async throws {
        let harness = VAPSwiftUITestHarness()
        let request = harness.request()
        harness.submit(request)
        await harness.controller.waitForPendingWork()
        let transport = try #require(harness.factory.transports.first)

        harness.controller.setPresentationAvailable(false)
        harness.controller.setPresentationAvailable(true)
        #expect(transport.resumeCount == 1)
        harness.submit(request, intent: .paused, revision: 1)
        harness.controller.setPresentationAvailable(false)
        harness.controller.setPresentationAvailable(true)
        #expect(transport.resumeCount == 1)
        #expect(transport.playCount == 1)
        await harness.close()
    }

    /// 同 ID 修改不可变配置只发一次 failed；旧 ID 之后恢复或再次修改都不复活。
    @Test
    func changingOptionsWithTheSameIDFailsOnlyOnce() async throws {
        let harness = VAPSwiftUITestHarness()
        let request = harness.request()
        harness.submit(request)
        await harness.controller.waitForPendingWork()
        let transport = try #require(harness.factory.transports.first)
        var options = request.options
        options.loopCount = 2
        let changed = harness.request(id: request.id, options: options)

        harness.submit(changed)
        harness.submit(request, revision: 1)
        harness.submit(changed, revision: 2)
        await harness.controller.waitForPendingWork()
        #expect(harness.events(for: request).filter { $0 == .failed(.requestChanged) }.count == 1)
        #expect(transport.cleanupCount == 1)
        #expect(transport.playCount == 1)
        #expect(harness.factory.transports.count == 1)
        await harness.close()
    }

    /// A 准备时切换 B：即使 A 忽略取消，也须等 A 清理结束后才创建 B，迟到事件无效。
    @Test
    func replacementWaitsForPhysicalCleanupAndDropsOldResults() async throws {
        let harness = VAPSwiftUITestHarness()
        let preparationGate = VAPTestGate()
        let cleanupGate = VAPTestGate()
        harness.factory.configureNext = {
            $0.preparationGate = preparationGate
            $0.cleanupGate = cleanupGate
        }
        let first = harness.request()
        let second = harness.request()
        harness.submit(first)
        let oldTransport = try #require(harness.factory.transports.first)
        await oldTransport.preparationEntered.wait()

        harness.submit(second)
        await oldTransport.cleanupEntered.wait()
        oldTransport.send(.started)
        oldTransport.send(.finished(.completed))
        #expect(harness.factory.transports.count == 1)
        preparationGate.open()
        cleanupGate.open()
        await harness.controller.waitForPendingWork()

        let newTransport = try #require(harness.factory.transports.last)
        #expect(harness.factory.transports.count == 2)
        #expect(oldTransport.playCount == 0)
        #expect(newTransport.playCount == 1)
        #expect(!harness.events(for: first).contains(.ready))
        #expect(!harness.events(for: first).contains(.started))
        #expect(harness.events(for: first).filter { $0 == .finished(.cancelled) }.count == 1)
        await harness.close()
    }

    /// 真实 prepare 同时 delegate 报错并抛出时，错误事件和排空都只执行一次。
    @Test
    func delegateAndThrownFailureShareOneTerminalEvent() async throws {
        let harness = VAPSwiftUITestHarness()
        harness.factory.configureNext = {
            $0.preparationError = .invalidURL
            $0.emitsErrorBeforeThrow = true
        }
        let request = harness.request()
        harness.submit(request)
        await harness.controller.waitForPendingWork()
        let transport = try #require(harness.factory.transports.first)
        #expect(harness.events(for: request).filter { $0 == .failed(.playback(.invalidURL)) }.count == 1)
        #expect(transport.cleanupCount == 1)
        #expect(transport.playCount == 0)
        await harness.close()
    }

    /// 新请求固定 provider 与实际挂起配置，同 ID 重绘不替换 provider 或重做准备。
    @Test
    func snapshotsProviderAndDisablesSDKAutomaticResume() async throws {
        let harness = VAPSwiftUITestHarness()
        let firstProvider = VAPTestDynamicProvider()
        let laterProvider = VAPTestDynamicProvider()
        var options = PlaybackOptions()
        options.automaticallyResumesAfterSuspension = true
        let request = harness.request(options: options)
        harness.submit(request, provider: firstProvider)
        await harness.controller.waitForPendingWork()
        harness.submit(request, provider: laterProvider)
        let transport = try #require(harness.factory.transports.first)
        let prepared = try #require(transport.preparedRequests.first)
        #expect(transport.receivedProvider === firstProvider)
        #expect(!prepared.options.automaticallyResumesAfterSuspension)
        #expect(prepared.options.backgroundPolicy == .suspend)
        #expect(request.options.automaticallyResumesAfterSuspension)
        #expect(transport.preparedRequests.count == 1)
        await harness.close()
    }

    /// 末帧保留只影响自然完成后的显示，不允许旧 ID 重播；显式停止随后释放末帧。
    @Test
    func retainedLastFrameStillHasATerminalIdentity() async throws {
        let harness = VAPSwiftUITestHarness()
        var options = PlaybackOptions()
        options.clearsAfterFinish = false
        let request = harness.request(options: options)
        harness.submit(request)
        await harness.controller.waitForPendingWork()
        let transport = try #require(harness.factory.transports.first)
        transport.send(.finished(.completed))
        harness.submit(request, revision: 1)
        await harness.controller.waitForPendingWork()
        #expect(transport.cleanupCount == 0)
        #expect(transport.playCount == 1)

        harness.submit(request, intent: .stopped, revision: 2)
        await harness.controller.waitForPendingWork()
        #expect(transport.cleanupCount == 1)
        #expect(harness.events(for: request).filter { $0 == .finished(.completed) }.count == 1)
        #expect(!harness.events(for: request).contains(.finished(.stopped)))
        await harness.close()
    }

    /// 初始隐藏请求不创建内核；恢复可见或先清空再重交旧 ID 也不会重播。
    @Test
    func hiddenRequestsDoNotStartOrReuseTheirIdentity() async {
        let harness = VAPSwiftUITestHarness()
        let request = harness.request()
        harness.submit(request, visible: false)
        harness.submit(nil)
        harness.submit(request, revision: 1)
        await harness.controller.waitForPendingWork()
        #expect(harness.factory.transports.isEmpty)
        #expect(harness.events(for: request) == [.finished(.stopped)])
        await harness.close()
    }

    /// dismantle 后即使准备和 delegate 迟到也不开播，清理屏障仍由明确所有者持有。
    @Test
    func dismantleWaitsForUncooperativePreparation() async throws {
        let harness = VAPSwiftUITestHarness()
        let preparationGate = VAPTestGate()
        let cleanupGate = VAPTestGate()
        harness.factory.configureNext = {
            $0.preparationGate = preparationGate
            $0.cleanupGate = cleanupGate
        }
        let request = harness.request()
        harness.submit(request)
        let transport = try #require(harness.factory.transports.first)
        await transport.preparationEntered.wait()
        harness.controller.dismantle()
        await transport.cleanupEntered.wait()
        harness.submit(harness.request())
        transport.send(.started)
        preparationGate.open()
        cleanupGate.open()
        await harness.controller.waitForPendingWork()
        #expect(transport.playCount == 0)
        #expect(transport.cleanupCount == 1)
        #expect(harness.factory.transports.count == 1)
        #expect(!harness.events(for: request).contains(.ready))
        #expect(!harness.events(for: request).contains(.started))
        #expect(harness.events(for: request).filter { $0 == .finished(.cancelled) }.count == 1)
    }

    /// Coordinator 真正释放后，registry 仍持有尚未完成的内核清理，直到屏障打开。
    @Test
    func retirementOutlivesTheSwiftUIController() async throws {
        let factory = VAPTestTransportFactory()
        let cleanupGate = VAPTestGate()
        let stoppedDelivered = VAPTestGate()
        factory.configureNext = { $0.cleanupGate = cleanupGate }
        var controller: VAPPlayerController? = VAPPlayerController { provider, onEvent in
            factory.make(provider: provider, onEvent: onEvent)
        }
        let request = VAPPlaybackRequest(id: UUID(), url: URL(fileURLWithPath: "/test/fixture.vap"))
        controller?.setPresentationAvailable(true)
        controller?.update(
            resource: request, intent: .playing, controlRevision: 0,
            isVisible: true, isMuted: false, isSceneActive: true,
            dynamicContentProvider: nil,
            onEvent: {
                // 以事件交付完成作为明确同步点，不靠 Task.yield 猜控制器何时释放。
                if $0.kind == .finished(.cancelled) { stoppedDelivered.open() }
            }
        )
        await controller?.waitForPendingWork()
        let transport = try #require(factory.transports.first)
        weak let weakController = controller
        controller?.dismantle()
        controller = nil
        await stoppedDelivered.wait()
        await transport.cleanupEntered.wait()
        #expect(weakController == nil)
        #expect(transport.cleanupCount == 1)

        cleanupGate.open()
        await transport.cleanupCompleted.wait()
        #expect(transport.cleanupCount == 1)
    }
}
