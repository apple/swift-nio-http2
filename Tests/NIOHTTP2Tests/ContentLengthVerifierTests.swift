import NIOHPACK
@testable import NIOHTTP2
import XCTest

class ContentLengthVerifierTests: XCTestCase {
    func testDuplicatedLengthHeadersPermitted() throws {
        var headers = HPACKHeaders([("Host", "apple.com"), ("content-length", "1834"), ("User-Agent", "myCoolClient/1.0")])
        XCTAssertNoThrow(try ContentLengthVerifier(headers))

        headers.add(contentsOf: [("content-length", "1834")])
        XCTAssertNoThrow(try ContentLengthVerifier(headers))

        headers.add(contentsOf: [("content-length", "1834")])
        XCTAssertNoThrow(try ContentLengthVerifier(headers))

        headers.add(contentsOf: [("Content-Length", "1834")])
        XCTAssertNoThrow(try ContentLengthVerifier(headers))
    }

    func testDuplicatedConflictingLengthHeadersThrow() throws {
        var headers = HPACKHeaders([("Host", "apple.com"), ("content-length", "1834"), ("User-Agent", "myCoolClient/1.0")])
        XCTAssertNoThrow(try ContentLengthVerifier(headers))

        headers.add(contentsOf: [("Content-Length", "4381")])
        XCTAssertThrowsError(try ContentLengthVerifier(headers))
    }
}
