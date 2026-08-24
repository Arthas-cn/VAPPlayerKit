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
        XCTAssertEqual(list.cells.count, scannedCount)

        let first = list.cells.element(boundBy: 0)
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

    func testAutomatedSmokeMatrixOnDevice() throws {
        let list = app.tables["catalog.list"]
        XCTAssertTrue(list.waitForExistence(timeout: 10))
        XCTAssertGreaterThan(list.cells.count, 0)
        list.cells.element(boundBy: 0).tap()

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
