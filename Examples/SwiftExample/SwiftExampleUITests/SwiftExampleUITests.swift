import XCTest

final class SwiftExampleUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--vap-ui-testing"]
        app.launch()
    }

    func testCatalogCountMatchesRowsAndPlaybackLifecycle() throws {
        let list = app.tables["catalog.list"]
        XCTAssertTrue(list.waitForExistence(timeout: 10))
        let manifest = try XCTUnwrap(list.value as? String)
        let identifiers = manifest.split(separator: ",").map(String.init)
        XCTAssertEqual(identifiers, (1...21).map { String($0) })
        let scannedCount = identifiers.count
        XCTAssertEqual(list.cells.count, scannedCount + 1)
        XCTAssertTrue(list.cells["catalog.item.animated"].waitForExistence(timeout: 5))

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

    func testAnimatedSlotScenePlaysOneMP4() throws {
        let list = app.tables["catalog.list"]
        XCTAssertTrue(list.waitForExistence(timeout: 10))
        let scene = list.cells["catalog.item.animated"]
        XCTAssertTrue(scene.waitForExistence(timeout: 5))
        XCTAssertTrue(app.otherElements["catalog.preview.animated"].waitForExistence(timeout: 5))
        scene.tap()
        XCTAssertTrue(app.otherElements["detail.player"].waitForExistence(timeout: 5))
        XCTAssertTrue(
            waitForState(["PLAYING"], timeout: 12),
            "Animated slot lab did not auto-play 1.mp4. \(detailDiagnostics())"
        )
        XCTAssertTrue(app.segmentedControls["detail.dynamicImagePlayback"].waitForExistence(timeout: 3))
    }

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

    func testEveryBundledFixtureOnDevice() throws {
        let batchButton = app.buttons["catalog.batchTest"]
        XCTAssertTrue(batchButton.waitForExistence(timeout: 10))
        batchButton.tap()
        XCTAssertTrue(
            waitForLabel(app.staticTexts["batch.state"], accepted: ["BATCH PASSED"], timeout: 90),
            "At least one bundled fixture failed real-device prepare/play validation."
        )
    }

    private func tapControl(_ identifier: String) {
        let button = app.buttons[identifier]
        for _ in 0..<8 where !button.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(button.waitForExistence(timeout: 5), "Missing control \(identifier)")
        button.tap()
    }

    private func waitForState(_ accepted: [String], timeout: TimeInterval) -> Bool {
        let state = app.staticTexts["detail.state"]
        return waitForLabel(state, accepted: accepted, timeout: timeout)
    }

    private func waitForLabel(_ element: XCUIElement, accepted: [String], timeout: TimeInterval) -> Bool {
        let state = element
        guard state.waitForExistence(timeout: 5) else { return false }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if accepted.contains(state.label) { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return accepted.contains(state.label)
    }

    private func waitForValue(_ element: XCUIElement, accepted: [String], timeout: TimeInterval) -> Bool {
        guard element.waitForExistence(timeout: 5) else { return false }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let value = element.value as? String, accepted.contains(value) { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return (element.value as? String).map(accepted.contains) ?? false
    }

    private func detailDiagnostics() -> String {
        let state = app.staticTexts["detail.state"].label
        let console = (app.textViews["detail.console"].value as? String) ?? "<no console>"
        return "state=\(state), console=\(console)"
    }
}

final class MetalBenchmarkUITests: XCTestCase {
    func testSharedCommandQueueOnDevice() throws {
        try runBenchmark(policy: "shared")
    }

    func testPerRendererCommandQueueOnDevice() throws {
        try runBenchmark(policy: "perRenderer")
    }

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
            let deadline = Date().addingTimeInterval(60)
            while Date() < deadline, result.label.contains("RUNNING") {
                RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            }
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

    private func metric(label: String, key: String) -> String? {
        guard let range = label.range(of: "\(key)=") else { return nil }
        return label[range.upperBound...]
            .split(whereSeparator: { $0 == " " || $0 == "\n" })
            .first
            .map(String.init)
    }

    private func assertPerPlayerFloor(in label: String) {
        let perPlayer: String
        if let range = label.range(of: "per_player=") {
            perPlayer = String(label[range.upperBound...]).components(separatedBy: " status=").first ?? ""
        } else {
            perPlayer = ""
        }
        let entries = perPlayer.split(separator: ";")
        XCTAssertEqual(entries.count, 12, label)
        for entry in entries {
            let fields = entry.split(separator: ":", maxSplits: 1).last ?? entry
            let values = fields.split(separator: ",").reduce(into: [String: String]()) { result, field in
                let pair = field.split(separator: "=", maxSplits: 1)
                if pair.count == 2 { result[String(pair[0])] = String(pair[1]) }
            }
            XCTAssertGreaterThanOrEqual(Int(values["rendered"] ?? "0") ?? 0, 5, String(entry))
            XCTAssertGreaterThan(Int(values["second_half"] ?? "0") ?? 0, 0, String(entry))
            XCTAssertEqual(Int(values["failures"] ?? "-1"), 0, String(entry))
            XCTAssertEqual(Int(values["drawable_failures"] ?? "-1"), 0, String(entry))
        }
    }
}
