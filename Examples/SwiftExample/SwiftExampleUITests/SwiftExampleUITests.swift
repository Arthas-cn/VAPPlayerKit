import XCTest

/// 真实 App 的目录、播放生命周期和动态槽位回归，所有 UI 操作隔离到主线程。
@MainActor
final class SwiftExampleUITests: XCTestCase {
    /// 使用测试 target 的应用绑定，兼容临时签名 App ID；每个用例重新启动。
    private var app: XCUIApplication!

    /// 在主线程初始化每个用例的 App；XCTestCase 的空默认实现无额外准备工作。
    override func setUp() async throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--vap-ui-testing"]
        app.launch()
    }

    /// 验证目录清单、行预览、详情自动播放及暂停、恢复、停止，并要求真实渲染帧。
    func testCatalogCountMatchesRowsAndPlaybackLifecycle() throws {
        let list = app.tables["catalog.list"]
        XCTAssertTrue(list.waitForExistence(timeout: 10))
        let manifest = try XCTUnwrap(list.value as? String)
        let identifiers = manifest.split(separator: ",").map(String.init)
        let requiredIdentifiers = Set((1...21).map { String($0) } + ["movie", "home", "nationalDayEffect", "nation", "movie01", "movie02", "alpha_left_moive", "7878"])
        XCTAssertTrue(requiredIdentifiers.isSubset(of: Set(identifiers)))
        let scannedCount = identifiers.count
        XCTAssertEqual(list.cells.count, scannedCount)

        let first = list.cells["catalog.item.0"]
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        let rowPreview = app.otherElements["catalog.preview.0"]
        XCTAssertTrue(rowPreview.waitForExistence(timeout: 5))
        XCTAssertTrue(
            waitForValue(rowPreview, accepted: ["playing"], timeout: 12),
            "The first catalog row did not start its embedded player preview."
        )
        first.tap()

        XCTAssertTrue(app.otherElements["detail.player"].waitForExistence(timeout: 5))
        XCTAssertTrue(
            waitForState(["PLAYING"], timeout: 12),
            "Detail page did not auto-play. \(detailDiagnostics())"
        )
        tapControl("detail.pause")
        XCTAssertTrue(waitForState(["PAUSED"], timeout: 3))
        tapControl("detail.resume")
        XCTAssertTrue(waitForState(["PLAYING"], timeout: 3))
        tapControl("detail.stop")
        XCTAssertTrue(waitForState(["STOPPED", "FINISHED"], timeout: 3))
        let metrics = app.staticTexts["detail.metrics"]
        XCTAssertTrue(metrics.exists)
        let metricsText = metrics.label
        let rendered = metricsText
            .split(separator: " ")
            .drop(while: { $0 != "Rendered" })
            .dropFirst()
            .first
            .flatMap { Int($0) } ?? 0
        XCTAssertGreaterThan(rendered, 0, "Lifecycle test did not submit a successful rendered frame.")
    }

    /// 连续三次进入后台再返回，要求每轮恢复播放并继续产生新帧。
    func testPlaybackRecoversAfterRepeatedBackgroundForeground() throws {
        try openDefaultPlayback()
        tapSegment("detail.loopCount", title: "∞")
        tapControl("detail.play")
        XCTAssertTrue(waitForState(["PLAYING"], timeout: 12), detailDiagnostics())

        for cycle in 1...3 {
            let renderedBeforeBackground = renderedFrameCount()
            XCUIDevice.shared.press(.home)
            XCTAssertTrue(waitForBackground(timeout: 5), "The app did not enter background.")
            app.activate()

            XCTAssertTrue(
                waitForState(["PLAYING"], timeout: 8),
                "Cycle \(cycle) did not resume playback. \(detailDiagnostics())"
            )
            XCTAssertTrue(
                waitForRenderedFrame(after: renderedBeforeBackground, timeout: 8),
                "Cycle \(cycle) did not render after foreground. \(detailDiagnostics())"
            )
            XCTAssertFalse(
                detailDiagnostics().contains("FAILED") || detailDiagnostics().contains(" ERROR "),
                "Background/foreground recovery reported a playback error. \(detailDiagnostics())"
            )
        }

        XCTAssertTrue(
            waitForConsole(containing: "decoder rebuilt", timeout: 5),
            "The foreground path did not rebuild the decoder. \(detailDiagnostics())"
        )
    }

    /// 后台策略选择停止时，返回前台仍保持终态且没有解码错误。
    func testBackgroundStopPolicyFinishesWithoutDecoderFailure() throws {
        try openDefaultPlayback()
        tapSegment("detail.loopCount", title: "∞")
        tapSegment("detail.backgroundPolicy", title: "停止")
        tapControl("detail.play")
        XCTAssertTrue(waitForState(["PLAYING"], timeout: 12), detailDiagnostics())

        XCUIDevice.shared.press(.home)
        XCTAssertTrue(waitForBackground(timeout: 5), "The app did not enter background.")
        app.activate()

        XCTAssertTrue(
            waitForState(["FINISHED"], timeout: 8),
            "Stop background policy did not finish the session. \(detailDiagnostics())"
        )
        XCTAssertFalse(detailDiagnostics().contains("FAILED"), detailDiagnostics())
        XCTAssertFalse(detailDiagnostics().contains(" ERROR "), detailDiagnostics())
    }

    /// 动态图片和文字控制都应出现在同一素材的详情页中。
    func testAnimatedSlotScenePlaysOneMP4() throws {
        try openDefaultPlayback()
        XCTAssertTrue(app.segmentedControls["detail.dynamicImagePlayback"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["detail.animated.previous"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.segmentedControls["detail.textOverflow"].waitForExistence(timeout: 3))
    }

    /// 触发真实设备冒烟矩阵，要求 Fit、Fill、Stretch 及生命周期全部通过。
    func testAutomatedSmokeMatrixOnDevice() throws {
        let list = app.tables["catalog.list"]
        XCTAssertTrue(list.waitForExistence(timeout: 10))
        XCTAssertGreaterThan(list.cells.count, 0)
        list.cells["catalog.item.0"].tap()

        tapControl("detail.autoTest")
        XCTAssertTrue(
            waitForState(["TEST PASSED"], timeout: 30),
            "Automated Fit/Fill/Stretch and pause/resume/stop matrix did not finish. \(detailDiagnostics())"
        )
        let console = try XCTUnwrap(app.textViews["detail.console"].value as? String)
        XCTAssertFalse(console.isEmpty)
    }

    /// 串行验证全部 Bundle 样本，并确认已知左 Alpha 视频实际通过播放。
    func testEveryBundledFixtureOnDevice() throws {
        let batchButton = app.buttons["catalog.batchTest"]
        XCTAssertTrue(batchButton.waitForExistence(timeout: 10))
        batchButton.tap()
        XCTAssertTrue(
            waitForLabel(app.staticTexts["batch.state"], accepted: ["BATCH PASSED"], timeout: 90),
            "At least one bundled fixture failed real-device prepare/play validation."
        )
        let log = try XCTUnwrap(app.textViews["batch.log"].value as? String)
        XCTAssertTrue(log.contains("alpha_left_moive: h264, 72f"), log)
    }

    /// 用真实左 Alpha 素材验证 SwiftUI 播放、用户暂停恢复、静音、原片对照及退出。
    func testSwiftUIPackedAlphaPlaybackControls() throws {
        XCTAssertTrue(app.tables["catalog.list"].waitForExistence(timeout: 10))
        let entry = app.navigationBars.buttons["SwiftUI"]
        XCTAssertTrue(entry.waitForExistence(timeout: 5))
        entry.tap()
        let status = app.staticTexts["swiftui.status"]
        XCTAssertTrue(waitForLabel(status, accepted: ["播放中"], timeout: 15), status.label)
        attachScreenshot(named: "显式 Alpha 合成")

        tapControl("swiftui.pause")
        XCTAssertTrue(waitForLabel(status, accepted: ["已暂停：user"], timeout: 5), status.label)
        tapControl("swiftui.resume")
        XCTAssertTrue(waitForLabel(status, accepted: ["已恢复"], timeout: 5), status.label)

        let mute = app.switches["swiftui.mute"]
        XCTAssertTrue(waitForValue(mute, accepted: ["1"], timeout: 5))
        tapVisible(mute)
        XCTAssertTrue(waitForValue(mute, accepted: ["0"], timeout: 5))
        tapVisible(mute)
        XCTAssertTrue(waitForValue(mute, accepted: ["1"], timeout: 5))

        let packedAlpha = app.switches["swiftui.packedAlpha"]
        XCTAssertTrue(waitForValue(packedAlpha, accepted: ["1"], timeout: 5))
        // 先停在明确的暂停状态，切换后必须出现新请求的 started，不能复用旧播放文案。
        tapControl("swiftui.pause")
        XCTAssertTrue(waitForLabel(status, accepted: ["已暂停：user"], timeout: 5), status.label)
        tapVisible(packedAlpha)
        XCTAssertTrue(waitForValue(packedAlpha, accepted: ["0"], timeout: 5))
        XCTAssertTrue(waitForLabel(status, accepted: ["播放中"], timeout: 15), status.label)
        attachScreenshot(named: "原始编码帧对照")

        tapControl("swiftui.pause")
        XCTAssertTrue(waitForLabel(status, accepted: ["已暂停：user"], timeout: 5), status.label)
        tapVisible(packedAlpha)
        XCTAssertTrue(waitForValue(packedAlpha, accepted: ["1"], timeout: 5))
        XCTAssertTrue(waitForLabel(status, accepted: ["播放中"], timeout: 15), status.label)

        tapControl("swiftui.stop")
        XCTAssertTrue(waitForLabel(status, accepted: ["已结束：stopped，可点重播"], timeout: 5), status.label)
        tapControl("swiftui.replay")
        XCTAssertTrue(waitForLabel(status, accepted: ["播放中"], timeout: 15), status.label)
        let back = app.navigationBars["SwiftUI 播放"].buttons.element(boundBy: 0)
        XCTAssertTrue(back.waitForExistence(timeout: 5))
        back.tap()
        XCTAssertTrue(app.tables["catalog.list"].waitForExistence(timeout: 5))
        XCTAssertTrue(waitForPredicate(NSPredicate(format: "exists == false"), object: status, timeout: 5))
    }

    /// 滚动到指定按钮并点击；沿用现有详情页的定位标识。
    private func tapControl(_ identifier: String) {
        let button = app.buttons[identifier]
        XCTAssertTrue(button.waitForExistence(timeout: 5), "Missing control \(identifier)")
        tapVisible(button)
    }

    /// 在有限次数滚动内找到可点区域，避免把离屏元素的 exists 当作可交互。
    private func tapVisible(_ element: XCUIElement) {
        for _ in 0..<8 where !element.isHittable {
            // 先按屏幕几何选择方向，允许从底部控制区回到上方开关。
            if !element.frame.isEmpty, element.frame.midY < app.frame.midY {
                app.swipeDown()
            } else {
                // 下方控件需要向上滚动，保留既有长详情页的行为。
                app.swipeUp()
            }
        }
        XCTAssertTrue(waitForPredicate(NSPredicate(format: "hittable == true"), object: element, timeout: 5))
        element.tap()
    }

    /// 点击现有分段控件中指定名称的选项。
    private func tapSegment(_ identifier: String, title: String) {
        let control = app.segmentedControls[identifier]
        XCTAssertTrue(control.waitForExistence(timeout: 5), "Missing segmented control \(identifier)")
        let segment = control.buttons[title]
        XCTAssertTrue(segment.waitForExistence(timeout: 3), "Missing segment \(title) in \(identifier)")
        segment.tap()
    }

    /// 打开第一项并等待真实播放回调，不以页面出现替代播放完成准备。
    private func openDefaultPlayback() throws {
        let list = app.tables["catalog.list"]
        XCTAssertTrue(list.waitForExistence(timeout: 10))
        let first = list.cells["catalog.item.0"]
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        first.tap()
        XCTAssertTrue(app.otherElements["detail.player"].waitForExistence(timeout: 5))
        XCTAssertTrue(
            waitForState(["PLAYING"], timeout: 12),
            "Detail page did not auto-play. \(detailDiagnostics())"
        )
    }

    /// 等待 UIKit 详情页进入任意一个允许的状态。
    private func waitForState(_ accepted: [String], timeout: TimeInterval) -> Bool {
        let state = app.staticTexts["detail.state"]
        return waitForLabel(state, accepted: accepted, timeout: timeout)
    }

    /// 使用 XCTest 条件等待标签文本，超时返回 false，不做固定睡眠。
    private func waitForLabel(_ element: XCUIElement, accepted: [String], timeout: TimeInterval) -> Bool {
        waitForPredicate(NSPredicate(format: "exists == true AND label IN %@", accepted), object: element, timeout: timeout)
    }

    /// 等待预览或开关值进入允许集合，保持主线程 API 访问隔离。
    private func waitForValue(_ element: XCUIElement, accepted: [String], timeout: TimeInterval) -> Bool {
        waitForPredicate(NSPredicate(format: "exists == true AND value IN %@", accepted), object: element, timeout: timeout)
    }

    /// 从既有指标摘要读取累计渲染帧数；尚无计数时返回零。
    private func renderedFrameCount() -> Int {
        let summary = app.staticTexts["detail.metrics"].label
        // 没有摘要时按零处理，让等待继续而不是误判已有渲染。
        guard let range = summary.range(of: "Rendered ") else { return 0 }
        let value = summary[range.upperBound...].split(separator: " ").first.map(String.init) ?? "0"
        return Int(value) ?? 0
    }

    /// 同一诊断对象的帧数只增不减，先等计数字段变化，再校验确实增加。
    private func waitForRenderedFrame(after count: Int, timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(
            format: "exists == true AND label CONTAINS 'Rendered ' AND NOT label CONTAINS %@",
            "Rendered \(count) "
        )
        return waitForPredicate(predicate, object: app.staticTexts["detail.metrics"], timeout: timeout)
            && renderedFrameCount() > count
    }

    /// 等待诊断时间线包含指定证据，不要求日志行的固定序号。
    private func waitForConsole(containing text: String, timeout: TimeInterval) -> Bool {
        let console = app.textViews["detail.console"]
        return waitForPredicate(NSPredicate(format: "exists == true AND value CONTAINS %@", text), object: console, timeout: timeout)
    }

    /// 等待应用真正离开前台；后台运行和已挂起都满足本用例前置条件。
    private func waitForBackground(timeout: TimeInterval) -> Bool {
        // setUp 未成功时明确失败，不把 Optional 包装交给 KVC 谓词查询。
        guard let app else { return false }
        let predicate = NSPredicate(
            format: "state == %d OR state == %d",
            XCUIApplication.State.runningBackground.rawValue,
            XCUIApplication.State.runningBackgroundSuspended.rawValue
        )
        return waitForPredicate(predicate, object: app, timeout: timeout)
    }

    /// 以格式化谓词交给 XCTest 等待，不用捕获 UI 对象的非隔离闭包。
    private func waitForPredicate(_ predicate: NSPredicate, object: Any, timeout: TimeInterval) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: object)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    /// 保存真实设备画面，供透明合成和原始编码对照检查。
    private func attachScreenshot(named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// 汇集状态和时间线，用于失败信息定位内核行为。
    private func detailDiagnostics() -> String {
        let state = app.staticTexts["detail.state"].label
        let console = (app.textViews["detail.console"].value as? String) ?? "<no console>"
        return "state=\(state), console=\(console)"
    }
}

/// 真机命令队列策略的重复测量，不把单次耗时当作稳定结论。
@MainActor
final class MetalBenchmarkUITests: XCTestCase {
    /// 用共享命令队列重复测量十二个播放器的准备耗时与持续渲染。
    func testSharedCommandQueueOnDevice() throws {
        try runBenchmark(policy: "shared")
    }

    /// 用每 renderer 独立队列执行相同基准，保留策略对照。
    func testPerRendererCommandQueueOnDevice() throws {
        try runBenchmark(policy: "perRenderer")
    }

    /// 每轮启动新进程，按条件等待最终结果，再汇总中位数和范围。
    private func runBenchmark(policy: String) throws {
        let runCount = 3
        var concurrentDurations: [Double] = []
        var renderedTotals: [Int] = []
        var droppedTotals: [Int] = []
        for run in 1...runCount {
            let app = XCUIApplication()
            app.launchArguments = [
                "--vap-ui-testing",
                "--vap-metal-benchmark",
                "-vap-metal-command-queue-policy=\(policy)"
            ]
            app.launch()
            let result = app.staticTexts["metal.benchmark"]
            XCTAssertTrue(result.waitForExistence(timeout: 30))
            let completed = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "NOT label CONTAINS 'RUNNING'"), object: result
            )
            XCTAssertEqual(XCTWaiter.wait(for: [completed], timeout: 60), .completed)
            let label = result.label
            print("METAL_DEVICE_BENCHMARK_UI policy=\(policy) run=\(run) result=\(label.replacingOccurrences(of: "\n", with: " "))")
            XCTAssertFalse(label.contains("FAILED"), label)
            XCTAssertTrue(label.contains("status=PASS"), label)
            XCTAssertTrue(label.contains("sequential_ms="), label)
            XCTAssertTrue(label.contains("concurrent_ms="), label)

            let concurrent = metric(label: label, key: "concurrent_ms").flatMap(Double.init)
            let rendered = metric(label: label, key: "rendered").flatMap(Int.init)
            let dropped = metric(label: label, key: "dropped").flatMap(Int.init)
            concurrentDurations.append(try XCTUnwrap(concurrent, label))
            renderedTotals.append(try XCTUnwrap(rendered, label))
            droppedTotals.append(try XCTUnwrap(dropped, label))
            assertPerPlayerFloor(in: label)
            app.terminate()
        }

        let sorted = concurrentDurations.sorted()
        let median = sorted[sorted.count / 2]
        let range = (sorted.first ?? 0)...(sorted.last ?? 0)
        let summary = String(
            format: "METAL_DEVICE_BENCHMARK_SUMMARY policy=%@ runs=%d concurrent_ms_median=%.2f concurrent_ms_range=%.2f-%.2f rendered_range=%d-%d dropped_range=%d-%d",
            policy,
            runCount,
            median,
            range.lowerBound,
            range.upperBound,
            renderedTotals.min() ?? 0,
            renderedTotals.max() ?? 0,
            droppedTotals.min() ?? 0,
            droppedTotals.max() ?? 0
        )
        print(summary)
        XCTContext.runActivity(named: "Metal benchmark summary") { activity in
            activity.add(XCTAttachment(string: summary))
        }
    }

    /// 从以空格或换行分隔的 key=value 摘要中读取单项指标。
    private func metric(label: String, key: String) -> String? {
        // 缺少字段交给调用者 XCTUnwrap 明确报错，不生成零值伪装成功。
        guard let range = label.range(of: "\(key)=") else { return nil }
        return label[range.upperBound...]
            .split(whereSeparator: { $0 == " " || $0 == "\n" })
            .first
            .map(String.init)
    }

    /// 每个播放器都必须持续渲染并且没有会话或 drawable 错误。
    private func assertPerPlayerFloor(in label: String) {
        let perPlayer: String
        // 先截取逐播放器字段，汇总总帧数不能替代个体通过。
        if let range = label.range(of: "per_player=") {
            perPlayer = String(label[range.upperBound...]).components(separatedBy: " status=").first ?? ""
        } else {
            // 缺字段得到空集合，下面数量断言会报告失败。
            perPlayer = ""
        }
        let entries = perPlayer.split(separator: ";")
        XCTAssertEqual(entries.count, 12, label)
        for entry in entries {
            let fields = entry.split(separator: ":", maxSplits: 1).last ?? entry
            let values = fields.split(separator: ",").reduce(into: [String: String]()) { result, field in
                let pair = field.split(separator: "=", maxSplits: 1)
                // 只解析完整键值对，格式损坏由后续缺项断言报告。
                if pair.count == 2 { result[String(pair[0])] = String(pair[1]) }
            }
            XCTAssertGreaterThanOrEqual(Int(values["rendered"] ?? "0") ?? 0, 5, String(entry))
            XCTAssertGreaterThan(Int(values["second_half"] ?? "0") ?? 0, 0, String(entry))
            XCTAssertEqual(Int(values["failures"] ?? "-1"), 0, String(entry))
            XCTAssertEqual(Int(values["drawable_failures"] ?? "-1"), 0, String(entry))
        }
    }
}
