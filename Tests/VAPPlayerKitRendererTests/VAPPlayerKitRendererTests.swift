import XCTest
@testable import VAPPlayerKit
import Metal
import QuartzCore
import CoreVideo
import CoreMedia

final class VAPPlayerKitRendererTests: XCTestCase {
    func testFrameRingBufferEnforcesCapacity() {
        let buffer = FrameRingBuffer(capacity: 2)
        XCTAssertFalse(buffer.isFull)
        XCTAssertNil(buffer.dequeue())
        let token = SessionToken.make()
        XCTAssertTrue(buffer.enqueue(makeFrame(pts: 0, index: 0, token: token)))
        XCTAssertTrue(buffer.enqueue(makeFrame(pts: 1, index: 1, token: token)))
        XCTAssertTrue(buffer.isFull)
        XCTAssertFalse(buffer.enqueue(makeFrame(pts: 2, index: 2, token: token)))
    }

    func testFrameRingBufferSelectsLatestDueFrameAndCountsDrops() {
        let buffer = FrameRingBuffer(capacity: 4)
        let token = SessionToken.make()
        XCTAssertTrue(buffer.enqueue(makeFrame(pts: 0, index: 0, token: token)))
        XCTAssertTrue(buffer.enqueue(makeFrame(pts: 0.04, index: 1, token: token)))
        XCTAssertTrue(buffer.enqueue(makeFrame(pts: 0.08, index: 2, token: token)))

        let due = buffer.dequeueDue(at: CMTime(seconds: 0.05, preferredTimescale: 600))
        XCTAssertEqual(due.frame?.index, 1)
        XCTAssertEqual(due.dropped, 1)
        XCTAssertEqual(buffer.count, 1)
    }

    @MainActor
    func testMetalRendererPrepareRequiresDevice() async throws {
        let renderer = MetalRenderer()
        let layer = CAMetalLayer()
        if MTLCreateSystemDefaultDevice() == nil {
            do {
                try await renderer.prepare(layer: layer)
                XCTFail("Expected metalUnavailable")
            } catch {
                XCTAssertEqual((error as? PlaybackError)?.code, .metalUnavailable)
            }
        } else {
            try await renderer.prepare(layer: layer)
            renderer.dispose()
        }
    }

    @MainActor
    func testMetalRendererUploadsTextTexture() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else { return }
        let renderer = MetalRenderer()
        let layer = CAMetalLayer()
        try await renderer.prepare(layer: layer)
        let image = UIGraphicsImageRenderer(size: CGSize(width: 197, height: 52)).image { _ in
            NSAttributedString(
                string: "VAP Swift",
                attributes: [.font: UIFont.boldSystemFont(ofSize: 24), .foregroundColor: UIColor.white]
            ).draw(at: .zero)
        }
        try await renderer.prepareDynamic(DynamicSnapshot(contents: ["nickname": .image(image)]))
        renderer.dispose()
    }

    func testAspectFitViewportUsesCanvasSize() {
        let viewport = MetalRenderer.viewport(
            drawableSize: CGSize(width: 300, height: 200),
            canvasSize: CGSize(width: 100, height: 100),
            contentMode: .scaleAspectFit
        )
        XCTAssertEqual(viewport.originX, 50, accuracy: 0.001)
        XCTAssertEqual(viewport.originY, 0, accuracy: 0.001)
        XCTAssertEqual(viewport.width, 200, accuracy: 0.001)
        XCTAssertEqual(viewport.height, 200, accuracy: 0.001)
    }


    private func makeFrame(pts: Double, index: Int, token: SessionToken) -> DecodedFrame {
        var pixelBuffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 2, 2, kCVPixelFormatType_32BGRA, nil, &pixelBuffer), kCVReturnSuccess)
        return DecodedFrame(
            token: token,
            pixelBuffer: pixelBuffer!,
            presentationTime: CMTime(seconds: pts, preferredTimescale: 600),
            duration: CMTime(value: 1, timescale: 25),
            index: index
        )
    }
}
