#if os(iOS)

    import UIKit
    import XCTest

    @testable import RhinestoneDepositModal

    /**
     The controller, driven without a page.

     This is where three of this package's defects lived — a watch that stayed
     on the corridor it was born with, a wallet removal nobody announced, and a
     dismissal that closed the bridge without taking the sheet down — and all
     three were caught by review rather than by anything running. `swift test`
     runs on macOS, where this file does not exist; `xcodebuild test` against a
     simulator is what runs it.
     */
    @MainActor
    final class DepositSheetControllerTests: XCTestCase {
        private var posted: [Envelope] = []
        private var dismissals = 0
        private var settled: [DepositRow] = []

        private static func config(
            recipient: String = "0x1111111111111111111111111111111111111111",
            backendUrl: String = "https://proxy.example.invalid"
        ) -> EmbedConfig {
            EmbedConfig(
                mode: .deposit,
                backendUrl: backendUrl,
                recipient: recipient,
                targetChain: .evm(8453),
                targetToken: "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913"
            )
        }

        private static let wallet = WalletState(
            isReady: true,
            isConnected: true,
            accounts: [
                WalletAccount(caip10: "eip155:8453:0x1111111111111111111111111111111111111111")
            ],
            chainId: "eip155:8453"
        )

        /// `.invalid` never resolves, so the web view fails its load instead of
        /// reaching the real page. Everything under test is driven through the
        /// seam rather than through navigation.
        private func makeController(
            wallet: WalletBridge? = nil
        ) -> DepositSheetController {
            let controller = DepositSheetController(
                config: Self.config(),
                wallet: wallet,
                callbacks: DepositSheetCallbacks(
                    onDepositSettled: { [weak self] deposit in self?.settled.append(deposit) },
                    onFatal: { _ in },
                    onDismiss: { [weak self] in self?.dismissals += 1 }
                ),
                embedURL: "https://deposit.example.invalid"
            )
            controller.postedFrames = { [weak self] script in
                guard let envelope = RecordingHost.decodeFrame(fromScript: script) else { return }
                self?.posted.append(envelope)
            }
            controller.loadViewIfNeeded()
            return controller
        }

        /// The page's first frame. Everything the host pushes is gated on it.
        private func handshake(_ controller: DepositSheetController) async {
            controller.receiveForTesting(
                .request(
                    id: "hello.1",
                    method: BridgeMethod.hello.rawValue,
                    params: .object([
                        "protocol": .number(2), "modalVersion": .string("0.0.0-test"),
                    ])
                )
            )
            for _ in 0..<100 where !posted.contains(where: { frame in
                if case .response(let id, _) = frame { return id == "hello.1" }
                return false
            }) {
                try? await Task.sleep(nanoseconds: 1_000_000)
            }
        }

        private func uiState(screen: String, blocked: Bool, height: Double? = nil) -> Envelope {
            var payload: [String: JSONValue] = [
                "screen": .string(screen),
                "dismissal": blocked
                    ? .object([
                        "state": .string("blocked"),
                        "reason": .string("submission-in-flight"),
                        "message": .string("Confirming your deposit."),
                    ])
                    : .object(["state": .string("allowed")]),
            ]
            if let height { payload["contentHeight"] = .number(height) }
            return .event(type: PageEvent.uiState.rawValue, payload: .object(payload))
        }

        private func events(ofType type: String) -> [JSONValue?] {
            posted.compactMap { frame in
                if case .event(let name, let payload) = frame, name == type { return payload }
                return nil
            }
        }

        override func setUp() {
            super.setUp()
            posted = []
            dismissals = 0
            settled = []
        }

        // MARK: - The lock

        /**
         `isModalInPresentation` is the whole enforcement of the dismissal lock
         on iOS. Without it the interactive swipe closes the sheet mid-signature
         and destroys the page that is the only thing tracking that deposit.
         */
        func testTheLockRefusesTheInteractiveSwipe() async {
            let controller = makeController()
            await handshake(controller)

            controller.receiveForTesting(uiState(screen: "confirm", blocked: true))
            XCTAssertTrue(controller.isModalInPresentation)

            controller.receiveForTesting(uiState(screen: "connect", blocked: false))
            XCTAssertFalse(controller.isModalInPresentation)
        }

        /// A dismissal the page asked for while it was locked is honoured when
        /// the lock lifts, not refused: `dismissRequested` is an event and
        /// cannot be answered, so it is a request to close, not permission.
        func testADismissalAskedForUnderTheLockWaitsForIt() async {
            let controller = makeController()
            await handshake(controller)
            controller.receiveForTesting(uiState(screen: "confirm", blocked: true))

            controller.receiveForTesting(
                .event(
                    type: PageEvent.dismissRequested.rawValue,
                    payload: .object(["source": .string("close-button")])
                )
            )
            XCTAssertEqual(dismissals, 0, "closed while the page said it must not be")

            controller.receiveForTesting(uiState(screen: "connect", blocked: false))
            XCTAssertEqual(dismissals, 1)
        }

        /// A completed flow closes itself even under the lock: the lock exists
        /// for what is in flight, and nothing is.
        func testACompletedFlowClosesThroughTheLock() async {
            let controller = makeController()
            await handshake(controller)
            controller.receiveForTesting(uiState(screen: "processing", blocked: true))

            controller.receiveForTesting(
                .event(
                    type: PageEvent.dismissRequested.rawValue,
                    payload: .object(["source": .string("flow-complete")])
                )
            )
            XCTAssertEqual(dismissals, 1)
        }

        /// One close, one callback, however many routes reach it — an
        /// integrator's teardown and their analytics run once per sheet.
        func testDismissalIsReportedOnce() async {
            let controller = makeController()
            await handshake(controller)

            for _ in 0..<3 {
                controller.receiveForTesting(
                    .event(
                        type: PageEvent.dismissRequested.rawValue,
                        payload: .object(["source": .string("close-button")])
                    )
                )
            }
            XCTAssertEqual(dismissals, 1)
        }

        // MARK: - Updates from the app

        /**
         Capabilities settle once at hello, so wallet availability is the thing
         that rides `wallet.state`. A host that drops its wallet and pushes
         nothing leaves the page rendering the account it last heard about.
         */
        func testClearingTheWalletIsAnnounced() async {
            let controller = makeController(
                wallet: WalletBridge(state: Self.wallet, request: { _ in .null })
            )
            await handshake(controller)
            posted = []

            controller.update(wallet: nil)

            let states = events(ofType: HostEvent.walletState.rawValue)
            XCTAssertEqual(states.count, 1, "the page was never told the wallet went away")
            XCTAssertEqual(states.last??["isConnected"]?.boolValue, false)
            XCTAssertEqual(states.last??["chainId"], .null)
            // Ready, not "connecting": there is no wallet coming, and the page
            // shows a spinner where it should show the paths that need none.
            XCTAssertEqual(states.last??["isReady"]?.boolValue, true)
        }

        /// Appearance changes while the sheet is open, and the page repaints in
        /// place rather than restarting the flow.
        func testAReconfigureReachesThePage() async {
            let controller = makeController()
            await handshake(controller)
            posted = []

            var next = Self.config()
            next.theme = DepositModalTheme(mode: .dark)
            controller.update(config: next)

            let configured = events(ofType: HostEvent.sessionConfigure.rawValue)
            XCTAssertEqual(configured.count, 1)
            XCTAssertEqual(configured.last??["theme"]?["mode"]?.stringValue, "dark")
        }

        /// Nothing is pushed before the handshake: the page has not asked yet,
        /// and a frame sent into a document with no receiver is dropped.
        func testNothingIsPushedBeforeTheHandshake() {
            let controller = makeController(
                wallet: WalletBridge(state: Self.wallet, request: { _ in .null })
            )
            controller.update(config: Self.config())
            controller.update(wallet: nil)

            XCTAssertTrue(posted.isEmpty)
        }

        // MARK: - Teardown

        /**
         UIKit reserves its dismissal callbacks for a user-driven dismissal, so
         a host closing the sheet its own way reaches nothing on the controller.
         Without `closeSession()` the watcher keeps polling and the bridge stays
         open behind a sheet that is already gone.
         */
        func testClosingTheSessionStopsTheBridge() async {
            let controller = makeController()
            await handshake(controller)

            controller.closeSession()
            posted = []
            controller.update(config: Self.config())
            controller.receiveForTesting(uiState(screen: "connect", blocked: false))

            XCTAssertTrue(posted.isEmpty, "a closed session still answered the page")
        }

        func testClosingTheSessionTwiceIsHarmless() async {
            let controller = makeController()
            await handshake(controller)

            controller.closeSession()
            controller.closeSession()
            XCTAssertEqual(dismissals, 0, "closeSession is not a dismissal and must not report one")
        }
    }

#endif
