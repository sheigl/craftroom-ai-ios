import XCTest
@testable import CraftRoomCore

/// Settings URL handling for the local server: what the owner types must end
/// up as exactly one canonical base (`http://host:port`, no trailing slash),
/// and a wrong value must be rejected with a readable reason, never sent.
final class ServerURLTests: XCTestCase {
    func testDefaultIsTheDeployedDesktop2Service() {
        XCTAssertEqual(ServerURL.defaultBase, "http://192.168.68.92:8124")
        XCTAssertEqual(ServerURL.default.absoluteString, ServerURL.defaultBase)
        XCTAssertTrue(ServerURL.isDefault(ServerURL.default))
        XCTAssertFalse(ServerURL.isDefault(URL(string: "http://192.168.68.92:8123")!))
    }

    func testAddsHTTPForABareHostAndPort() throws {
        let url = try ServerURL.parse("192.168.68.92:8124")
        XCTAssertEqual(url.absoluteString, "http://192.168.68.92:8124")
        let host = try ServerURL.parse("desktop2.local:8124")
        XCTAssertEqual(host.scheme, "http")
        XCTAssertEqual(host.host, "desktop2.local")
        XCTAssertEqual(host.port, 8124)
    }

    func testTrimsWhitespaceAndTrailingSlashes() throws {
        let url = try ServerURL.parse("  http://192.168.68.92:8124///  ")
        XCTAssertEqual(url.absoluteString, "http://192.168.68.92:8124")
        let root = try ServerURL.parse("http://192.168.68.92:8124/")
        XCTAssertEqual(root.absoluteString, "http://192.168.68.92:8124")
    }

    func testKeepsAnExplicitPathButDropsQueryAndFragment() throws {
        let url = try ServerURL.parse("http://desktop2:8124/api/?x=1#frag")
        XCTAssertEqual(url.absoluteString, "http://desktop2:8124/api")
    }

    func testLowercasesSchemeAndAllowsHTTPS() throws {
        XCTAssertEqual(try ServerURL.parse("HTTP://host:8124").absoluteString,
                       "http://host:8124")
        XCTAssertEqual(try ServerURL.parse("https://host").absoluteString,
                       "https://host")
    }

    func testRejectsUnusableAddresses() {
        XCTAssertNil(ServerURL.normalise("   "))
        XCTAssertNil(ServerURL.normalise("ftp://host"))
        XCTAssertNil(ServerURL.normalise("http://"))
        XCTAssertNil(ServerURL.normalise("::not a url::"))
        XCTAssertThrowsError(try ServerURL.parse("")) { error in
            XCTAssertEqual(error as? ServerURL.Invalid, .empty)
        }
        XCTAssertThrowsError(try ServerURL.parse("ftp://host")) { error in
            XCTAssertEqual(error as? ServerURL.Invalid, .unsupportedScheme("ftp"))
        }
        XCTAssertThrowsError(try ServerURL.parse("http://")) { error in
            XCTAssertEqual(error as? ServerURL.Invalid, .missingHost)
        }
    }

    func testEndpointNeverDoublesSlashes() {
        let base = ServerURL.default
        XCTAssertEqual(ServerURL.endpoint(base, "health").absoluteString,
                       "http://192.168.68.92:8124/health")
        XCTAssertEqual(ServerURL.endpoint(base, "/generate").absoluteString,
                       "http://192.168.68.92:8124/generate")
        let job = ServerURL.endpoint(base, "jobs/abc/result.png")
        XCTAssertEqual(job.absoluteString,
                       "http://192.168.68.92:8124/jobs/abc/result.png")
    }
}
