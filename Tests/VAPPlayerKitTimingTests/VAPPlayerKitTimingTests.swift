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

    @MainActor
    func testLoopWaitsUntilLastFrameDurationHasElapsed() {
        XCTAssertFalse(PlaybackSession.shouldCompleteLoop(
            sourceEnded: true,
            bufferedFrameCount: 0,
            hasPendingFrame: false,
            renderPending: false,
            lastFrameEndTime: 1.04,
            mediaTime: 1.03
        ))
        XCTAssertTrue(PlaybackSession.shouldCompleteLoop(
            sourceEnded: true,
            bufferedFrameCount: 0,
            hasPendingFrame: false,
            renderPending: false,
            lastFrameEndTime: 1.04,
            mediaTime: 1.04
        ))
    }
}
