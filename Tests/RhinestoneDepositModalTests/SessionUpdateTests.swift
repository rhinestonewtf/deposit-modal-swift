import XCTest

@testable import RhinestoneDepositModal

/// The deposit watch outlives the web view, so it has to follow the config
/// rather than the one it was born with.
final class SessionUpdateTests: XCTestCase {
    private func config(
        backendUrl: String = "https://proxy.example.com",
        recipient: String = "0x1111111111111111111111111111111111111111",
        theme: DepositModalTheme? = nil
    ) -> EmbedConfig {
        EmbedConfig(
            mode: .deposit,
            backendUrl: backendUrl,
            recipient: recipient,
            targetChain: .evm(8453),
            targetToken: "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913",
            theme: theme
        )
    }

    /**
     Switching account behind a live sheet leaves the page starting deposits for
     one address while the watcher polls another — and the completion the web
     view died through is then missed by the only thing still looking for it.
     */
    func testANewRecipientOrProxyMovesTheCorridor() {
        XCTAssertTrue(
            SessionUpdate.corridorMoved(
                from: config(),
                to: config(recipient: "0x2222222222222222222222222222222222222222")
            )
        )
        XCTAssertTrue(
            SessionUpdate.corridorMoved(
                from: config(),
                to: config(backendUrl: "https://other-proxy.example.com")
            )
        )
    }

    /// Restarting takes a fresh baseline, which suppresses everything already
    /// terminal as history — so a repaint must not trigger one.
    func testARepaintDoesNotMoveTheCorridor() {
        XCTAssertFalse(SessionUpdate.corridorMoved(from: config(), to: config()))
        XCTAssertFalse(
            SessionUpdate.corridorMoved(
                from: config(),
                to: config(theme: DepositModalTheme(mode: .dark))
            )
        )
    }
}
