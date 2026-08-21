import XCTest
@testable import VAPPlayerKit

final class VAPPlayerKitParserTests: XCTestCase {
    func testInspectorRejectsMissingFile() async {
        let inspector = AssetInspector()
        let url = URL(fileURLWithPath: "/tmp/vapplayerkit-missing-\(UUID().uuidString).mp4")
        do {
            _ = try await inspector.inspect(url: url)
            XCTFail("Expected fileNotFound")
        } catch let error as PlaybackError {
            XCTAssertEqual(error.code, .fileNotFound)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testVapcReaderStubReturnsInvalidVapc() {
        XCTAssertThrowsError(try VapcReader().read(from: Data())) { error in
            guard let playbackError = error as? PlaybackError else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(playbackError.code, .invalidVapc)
        }
    }

    func testInvalidXMLFixtureIsNotAValidMP4Header() throws {
        let url = VAPFixture.url(VAPFixture.invalidXMLNames[0])
        let data = try Data(contentsOf: url)
        XCTAssertFalse(data.starts(with: Data("ftyp".utf8)))
        let prefix = String(data: data.prefix(32), encoding: .utf8) ?? ""
        XCTAssertTrue(prefix.contains("xml") || prefix.contains("Error"))
    }
}
