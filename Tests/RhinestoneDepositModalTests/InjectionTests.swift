import XCTest

@testable import RhinestoneDepositModal

/// The two halves of the channel that have to be written as source text.
final class InjectionTests: XCTestCase {
    func testTheChannelScriptInstallsTheNameThePageCallsAndForwardsTheNonce() {
        let script = Injection.channelScript(nonce: "abc123")
        XCTAssertTrue(script.contains("'\(BridgeProtocol.pageToHostChannel)'"))
        XCTAssertTrue(script.contains(Injection.nativeHandlerName))
        XCTAssertTrue(script.contains("\"abc123\""))
        // Frozen and non-configurable: the page's own document should not be
        // able to have the channel replaced underneath it.
        XCTAssertTrue(script.contains("Object.freeze"))
        XCTAssertTrue(script.contains("configurable: false"))
    }

    func testSplitsTheNonceFromTheFrame() {
        let parsed = Injection.parseInboundFrame("nonce|{\"kind\":\"event\"}")
        XCTAssertEqual(parsed?.nonce, "nonce")
        XCTAssertEqual(parsed?.json, "{\"kind\":\"event\"}")

        // A frame that carries no prefix at all is what something posting to
        // the native handler directly produces.
        XCTAssertNil(Injection.parseInboundFrame("{\"kind\":\"event\"}"))
        XCTAssertNil(Injection.parseInboundFrame("|no-nonce"))
        XCTAssertNil(Injection.parseInboundFrame(42))
        XCTAssertNil(Injection.parseInboundFrame(nil))
    }

    /// A JSON payload keeps its own quoting inside a JS string literal.
    func testEncodesAFrameAsOneEvaluableStatement() {
        let script = Injection.encodeFrameForEvaluation("{\"a\":\"b \\\" c\"}")
        XCTAssertTrue(script.hasPrefix("window.\(BridgeProtocol.hostToPageChannel) &&"))
        XCTAssertTrue(script.hasSuffix("); true;"))
        XCTAssertTrue(script.contains("\\\"a\\\""))
    }

    /**
     U+2028 and U+2029 were line terminators in JS before ES2019, so an
     unescaped one truncates the statement on an older engine. This boundary
     carries wallet-controlled text by design — a `BridgeError.message` is the
     wallet's own copy — so it is not theoretical.
     */
    func testEscapesWhatIsLegalInJSONAndUnsafeInScriptSource() {
        let script = Injection.encodeFrameForEvaluation("a\u{2028}b\u{2029}c<d")
        XCTAssertFalse(script.contains("\u{2028}"))
        XCTAssertFalse(script.contains("\u{2029}"))
        XCTAssertTrue(script.contains("\\u2028"))
        XCTAssertTrue(script.contains("\\u2029"))
        XCTAssertTrue(script.contains("\\u003c"))
    }

    func testMintsADistinctNoncePerSession() {
        let first = Injection.makeSessionNonce()
        let second = Injection.makeSessionNonce()
        XCTAssertEqual(first.count, 32)
        XCTAssertNotEqual(first, second)
        XCTAssertFalse(first.contains(Injection.nonceSeparator))
    }
}
