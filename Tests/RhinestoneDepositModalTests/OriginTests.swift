import XCTest

@testable import RhinestoneDepositModal

/// The pin that keeps another document off the web view holding the bridge.
final class OriginTests: XCTestCase {
    private let embed = "https://deposit.rhinestone.dev"

    func testAcceptsOurOwnOriginWhateverThePath() {
        XCTAssertTrue(Origin.isSameOrigin(embed, as: embed))
        XCTAssertTrue(Origin.isSameOrigin("\(embed)/", as: embed))
        XCTAssertTrue(Origin.isSameOrigin("\(embed)/deposit?x=1#y", as: embed))
        XCTAssertTrue(Origin.isSameOrigin("HTTPS://Deposit.Rhinestone.DEV/x", as: embed))
        // The default port is not part of the identity.
        XCTAssertTrue(Origin.isSameOrigin("https://deposit.rhinestone.dev:443/x", as: embed))
    }

    /// Each of these passes a `hasPrefix` check and none of them is our origin.
    func testRefusesTheLookalikesAPrefixCheckAccepts() {
        XCTAssertFalse(Origin.isSameOrigin("https://deposit.rhinestone.dev.evil.example", as: embed))
        XCTAssertFalse(Origin.isSameOrigin("https://deposit.rhinestone.dev@evil.example", as: embed))
        XCTAssertFalse(Origin.isSameOrigin("https://deposit.rhinestone.dev\\@evil.example", as: embed))
        XCTAssertFalse(Origin.isSameOrigin("https://evil.example/deposit.rhinestone.dev", as: embed))
    }

    /**
     A web view reports a frame's origin in parts, and the port is the one that
     is easy to drop. Dropping it costs a wrapper pointed at a page served
     locally every bridge message: the navigation gate passes, the page loads,
     and nothing it says is ever accepted.
     */
    func testRebuildsAnOriginFromTheePartsAWebViewReports() {
        XCTAssertEqual(Origin.origin(host: "deposit.rhinestone.dev", port: 0), embed)
        XCTAssertEqual(Origin.origin(host: "deposit.rhinestone.dev", port: 443), embed)
        XCTAssertEqual(Origin.origin(host: "localhost", port: 3000), "https://localhost:3000")

        XCTAssertTrue(
            Origin.isSameOrigin(
                Origin.origin(host: "localhost", port: 3000),
                as: "https://localhost:3000"
            )
        )
        XCTAssertFalse(
            Origin.isSameOrigin(
                Origin.origin(host: "localhost", port: 3001),
                as: "https://localhost:3000"
            )
        )
    }

    func testRefusesAnythingThatIsNotHTTPS() {
        XCTAssertNil(Origin.httpsAuthority(of: "http://deposit.rhinestone.dev"))
        XCTAssertNil(Origin.httpsAuthority(of: "javascript:alert(1)"))
        XCTAssertNil(Origin.httpsAuthority(of: "about:blank"))
        XCTAssertNil(Origin.httpsAuthority(of: "https://"))
        XCTAssertNil(Origin.httpsAuthority(of: ""))
    }
}
