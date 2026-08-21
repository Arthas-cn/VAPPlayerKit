import XCTest
@testable import VAPPlayerKit
import Metal

final class VAPPlayerKitRendererTests: XCTestCase {
    func testFrameRingBufferEnforcesCapacity() {
        let buffer = FrameRingBuffer(capacity: 2)
        XCTAssertFalse(buffer.isFull)
        XCTAssertNil(buffer.dequeue())
    }

    func testMetalRendererPrepareRequiresDevice() throws {
        let renderer = MetalRenderer()
        if MTLCreateSystemDefaultDevice() == nil {
            XCTAssertThrowsError(try renderer.prepare())
        } else {
            XCTAssertNoThrow(try renderer.prepare())
            renderer.dispose()
        }
    }
}
