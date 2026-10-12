import XCTest
import CoreVideo
@testable import VAPPlayerKit

final class LegacyPackedVAPDetectorTests: XCTestCase {
    func testCorrelatedPackedLayoutWinsOverPerpendicularPadding() throws {
        for padding: UInt8 in [16, 40] {
            for mode: AlphaMode in [.left, .right, .top, .bottom] {
                let buffer = try makeBuffer { x, y in
                    let horizontal = mode == .left || mode == .right
                    let localX = horizontal ? x % 64 : x
                    let localY = horizontal ? y : y % 64
                    // Gray padding remains a weaker candidate on the other axis;
                    // black padding exercises the transparent-region rejection.
                    let active = horizontal ? localY >= 64 : localX >= 64
                    let alpha = mode == .left ? x < 64
                        : mode == .right ? x >= 64
                        : mode == .top ? y < 64 : y >= 64
                    let luma = active ? UInt8(70 + (localX / 8 + localY / 8) % 2 * 140) : padding
                    return (luma, active && !alpha ? 170 : 128, 128)
                }
                let layout = LegacyPackedVAPDetector.detect(pixelBuffer: buffer)
                XCTAssertEqual(layout?.alphaMode, mode)
                XCTAssertEqual(layout?.alphaOffset, 0)
            }
        }
    }

    func testOrdinaryColorAndBlankFramesRemainOrdinary() throws {
        for chroma: UInt8 in [128, 170] {
            let buffer = try makeBuffer { _, _ in (16, chroma, 128) }
            XCTAssertNil(LegacyPackedVAPDetector.detect(pixelBuffer: buffer))
        }
        let colorful = try makeBuffer { x, y in
            (UInt8(30 + (x + y) % 180), 160, 150)
        }
        XCTAssertNil(LegacyPackedVAPDetector.detect(pixelBuffer: colorful))
    }

    func testOrdinaryVideoWithBlackHalfIsNotCropped() throws {
        let buffer = try makeBuffer { x, y in
            y < 64 ? (16, 128, 128) : (UInt8(70 + (x + y) % 140), 170, 128)
        }
        XCTAssertNil(LegacyPackedVAPDetector.detect(pixelBuffer: buffer))
    }

    func testRepeatedGrayscaleDetailRemainsOrdinary() throws {
        let buffer = try makeBuffer { _, y in
            (UInt8(30 + y), 128, 128)
        }
        XCTAssertNil(LegacyPackedVAPDetector.detect(pixelBuffer: buffer))
    }

    func testMultipleWeakLayoutsRemainAmbiguous() throws {
        let buffer = try makeBuffer { x, y in
            x >= 64 && y >= 64 ? (180, 180, 128) : (40, 128, 128)
        }
        XCTAssertNil(LegacyPackedVAPDetector.detect(pixelBuffer: buffer))
    }

    func testVerticallyOffsetRightAlphaIsDetected() throws {
        let buffer = try makeBuffer { x, y in
            let alpha = x >= 64
            let contentY = alpha ? y + 16 : y
            let active = contentY >= 40 && contentY < 56
            let luma: UInt8 = active ? 180 : 16
            let chroma: UInt8 = !alpha && active ? 170 : 128
            return (luma, chroma, 128)
        }
        let layout = LegacyPackedVAPDetector.detect(pixelBuffer: buffer)
        XCTAssertEqual(layout?.alphaMode, .right)
        XCTAssertEqual(layout?.alphaOffset, -16)
    }

    func testShiftedLayoutWithMismatchedCrossSectionStaysOrdinary() throws {
        let buffer = try makeBuffer { x, y in
            let alpha = x >= 64
            let localX = alpha ? x - 64 : x
            let contentY = alpha ? y + 16 : y
            let inBand = contentY >= 30 && contentY < 90
            let inStripe = alpha ? (localX >= 40 && localX < 52) : (localX >= 8 && localX < 20)
            let active = inBand && inStripe
            let luma: UInt8 = active ? 180 : 16
            let chroma: UInt8 = !alpha && active ? 170 : 128
            return (luma, chroma, 128)
        }
        XCTAssertNil(LegacyPackedVAPDetector.detect(pixelBuffer: buffer))
    }

    func testColoredPixelsInCandidateAlphaAreRejected() throws {
        let buffer = try makeBuffer { x, y in
            (UInt8(40 + (x % 64 + y) % 160), x < 64 ? 136 : 170, 128)
        }
        XCTAssertNil(LegacyPackedVAPDetector.detect(pixelBuffer: buffer))
    }

    private func makeBuffer(
        pixel: (Int, Int) -> (UInt8, UInt8, UInt8)
    ) throws -> CVPixelBuffer {
        var result: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(
            kCFAllocatorDefault, 128, 128,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, nil, &result
        ), kCVReturnSuccess)
        let buffer = try XCTUnwrap(result)
        XCTAssertEqual(CVPixelBufferLockBaseAddress(buffer, []), kCVReturnSuccess)
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let luma = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(buffer, 0))
            .assumingMemoryBound(to: UInt8.self)
        let chroma = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(buffer, 1))
            .assumingMemoryBound(to: UInt8.self)
        for y in 0..<128 {
            for x in 0..<128 {
                let value = pixel(x, y)
                luma[y * CVPixelBufferGetBytesPerRowOfPlane(buffer, 0) + x] = value.0
                if x % 2 == 0, y % 2 == 0 {
                    let offset = y / 2 * CVPixelBufferGetBytesPerRowOfPlane(buffer, 1) + x
                    chroma[offset] = value.1
                    chroma[offset + 1] = value.2
                }
            }
        }
        return buffer
    }
}
