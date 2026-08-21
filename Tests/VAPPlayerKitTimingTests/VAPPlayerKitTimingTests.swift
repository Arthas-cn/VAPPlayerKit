import XCTest
@testable import VAPPlayerKit

final class VAPPlayerKitTimingTests: XCTestCase {
    func testMediaClockPausesAndResumesWithoutJumpingBackwards() {
        let clock = MediaClock()
        clock.resume()
        let playing = clock.currentMediaTime()
        clock.pause()
        let paused = clock.currentMediaTime()
        XCTAssertGreaterThanOrEqual(paused, playing)
        clock.resume()
        XCTAssertGreaterThanOrEqual(clock.currentMediaTime(), paused)
    }
}
