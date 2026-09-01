import Foundation
import XCTest

@testable import RhinestoneDepositModal

/**
 What the host does with frames that do not fit, and with handlers that fail.

 The rule throughout: a misfit frame is dropped and counted, never turned into a
 user-visible failure. The page is another process with its own bugs; this
 side's job is to remain a host.
 */
@MainActor
final class BridgeHostTests: XCTestCase {
    private var sent: [Envelope] = []
    private var handlers = BridgeHost.Handlers()
    private var host: BridgeHost!

    private static let nonce = "test-nonce"

    override func setUp() {
        super.setUp()
        sent = []
        handlers = BridgeHost.Handlers()
        host = makeHost()
    }

    private func makeHost(backTimeoutMilliseconds: Int = 40) -> BridgeHost {
        BridgeHost(
            post: { [weak self] script in
                guard let envelope = RecordingHost.decodeFrame(fromScript: script) else { return }
                self?.sent.append(envelope)
            },
            nonce: Self.nonce,
            identity: HostIdentity(platform: .ios, app: "Tests"),
            config: { RecordingHost.config },
            wallet: { RecordingHost.wallet },
            handlers: { [weak self] in self?.handlers ?? BridgeHost.Handlers() },
            backTimeoutMilliseconds: backTimeoutMilliseconds
        )
    }

    private func deliver(_ envelope: Envelope, nonce: String = BridgeHostTests.nonce) {
        let data = try! JSONEncoder().encode(envelope)
        host.receive("\(nonce)\(Injection.nonceSeparator)\(String(data: data, encoding: .utf8)!)")
    }

    private func answer(to id: String) async -> Envelope? {
        for _ in 0..<200 {
            if let found = sent.first(where: {
                if case .response(let responseId, _) = $0 { return responseId == id }
                return false
            }) { return found }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        return nil
    }

    private func error(in envelope: Envelope?) -> BridgeError? {
        guard case .response(_, .failure(let error)) = envelope else { return nil }
        return error
    }

    // MARK: - Frames that do not fit

    /**
     The frame-scoping check, and the reason `bridge.probeFrameScope` needs no
     handler.

     A sub-frame never learns the nonce — the channel script is injected for the
     main frame only — so its probe is dropped here, before the dispatcher. That
     drop is the answer the page is looking for: silence means this host does
     not act on sub-frame traffic.
     */
    func testDropsAFrameThatDoesNotCarryTheNonce() {
        deliver(
            .request(id: "1", method: BridgeMethod.probeFrameScope.rawValue, params: nil),
            nonce: "not-the-nonce"
        )
        XCTAssertEqual(host.drops[.foreignFrame], 1)
        XCTAssertTrue(sent.isEmpty)
    }

    func testDropsWhatIsNotAStringAtAll() {
        host.receive(42)
        host.receive(nil)
        XCTAssertEqual(host.drops[.notAString], 2)
    }

    func testDropsAFrameWithNoNoncePrefix() {
        host.receive("{\"kind\":\"event\",\"type\":\"ready\"}")
        XCTAssertEqual(host.drops[.foreignFrame], 1)
    }

    /// Mirrors the page's own cap, so neither side spends a parse on something
    /// the other would never send.
    func testDropsAFrameLargerThanTheCap() {
        let oversized = String(repeating: "a", count: BridgeProtocol.maxFrameLength + 1)
        host.receive("\(Self.nonce)|\(oversized)")
        XCTAssertEqual(host.drops[.tooLarge], 1)
    }

    func testDropsWhatIsNotJSONAndWhatIsNotAnObject() {
        host.receive("\(Self.nonce)|not json at all")
        host.receive("\(Self.nonce)|\"a string\"")
        XCTAssertEqual(host.drops[.notJSON], 1)
        XCTAssertEqual(host.drops[.notAnObject], 1)
    }

    func testDropsAnEnvelopeKindItDoesNotKnow() {
        host.receive("\(Self.nonce)|{\"kind\":\"telemetry\"}")
        XCTAssertEqual(host.drops[.unknownKind], 1)
    }

    func testDropsAResponseItNeverAskedFor() {
        deliver(.response(id: "host.99", outcome: .success(.object([:]))))
        XCTAssertEqual(host.drops[.unmatchedResponse], 1)
    }

    /**
     The dismissal lock is the one payload this host reads a nested field out
     of, so it is the one that has to be checked rather than cast.

     The page and the wrapper ship separately and by different routes — a hosted
     page against an app-store build — so a frame from a version that spells
     this differently is a thing that will happen. A full snapshot arrives on
     every change, so the next one heals it.
     */
    func testDropsAUiStateItCannotRead() {
        deliver(.event(type: PageEvent.uiState.rawValue, payload: .object(["screen": .number(1)])))
        XCTAssertEqual(host.drops[.badUiState], 1)
        XCTAssertNil(host.uiState)

        deliver(
            .event(
                type: PageEvent.uiState.rawValue,
                payload: .object([
                    "screen": .string("connect"),
                    "dismissal": .object(["state": .string("allowed")]),
                ])
            )
        )
        XCTAssertEqual(host.uiState?.screen, "connect")
        XCTAssertEqual(host.uiState?.dismissal, .allowed)
    }

    /// A reason this build does not know still locks the sheet: the lock is the
    /// load-bearing half, and the reason is copy.
    func testKeepsTheLockWhenTheReasonIsUnfamiliar() {
        deliver(
            .event(
                type: PageEvent.uiState.rawValue,
                payload: .object([
                    "screen": .string("processing"),
                    "dismissal": .object([
                        "state": .string("blocked"),
                        "reason": .string("something-new"),
                        "message": .string("Hold on."),
                    ]),
                ])
            )
        )
        XCTAssertTrue(host.uiState?.dismissal.isBlocked == true)
    }

    /// The page publishes this now; a host that sizes a sheet to it reads it
    /// here. Absent means "nothing measured yet", never zero.
    func testCarriesTheContentHeightWhenThePagePublishesOne() {
        deliver(
            .event(
                type: PageEvent.uiState.rawValue,
                payload: .object([
                    "screen": .string("connect"),
                    "dismissal": .object(["state": .string("allowed")]),
                    "contentHeight": .number(480),
                ])
            )
        )
        XCTAssertEqual(host.uiState?.contentHeight, 480)

        deliver(
            .event(
                type: PageEvent.uiState.rawValue,
                payload: .object([
                    "screen": .string("connect"),
                    "dismissal": .object(["state": .string("allowed")]),
                ])
            )
        )
        XCTAssertNil(host.uiState?.contentHeight)
    }

    // MARK: - Methods

    func testAnswers4200ForAMethodItDoesNotImplement() async {
        deliver(.request(id: "1", method: "host.somethingNew", params: nil))
        let failure = error(in: await answer(to: "1"))
        XCTAssertEqual(failure?.code, 4200)
    }

    /**
     The signing surface, enforced here as well as page-side.

     This list is what the wrapper exposes to whatever reaches the channel, and
     a host that forwards blindly is publishing `eth_sign` to it.
     */
    func testRefusesAWalletMethodOutsideTheAllowList() async {
        var seen = false
        handlers.walletRequest = { _ in
            seen = true
            return .null
        }
        deliver(
            .request(
                id: "1",
                method: BridgeMethod.walletRequest.rawValue,
                params: .object([
                    "chainId": .string("eip155:8453"),
                    "request": .object(["method": .string("eth_sign")]),
                ])
            )
        )
        let failure = error(in: await answer(to: "1"))
        XCTAssertEqual(failure?.code, 4200)
        XCTAssertEqual(failure?.message, "Unsupported method: eth_sign")
        XCTAssertFalse(seen, "the handler must never see a method off the list")
    }

    func testAnswers4200WhenThereIsNoWalletAtAll() async {
        deliver(
            .request(
                id: "1",
                method: BridgeMethod.walletRequest.rawValue,
                params: .object([
                    "chainId": .string("eip155:8453"),
                    "request": .object(["method": .string("eth_accounts")]),
                ])
            )
        )
        let failure = error(in: await answer(to: "1"))
        XCTAssertEqual(failure?.code, 4200)
    }

    /**
     A send whose outcome is unknown must never come back as -32603.

     viem retries that code three times on its own, and a retried
     `eth_sendTransaction` is a second broadcast of the same transfer.
     */
    func testFailsASubmittingMethodSafeRatherThanRetryably() async {
        struct Boom: Error {}
        handlers.sendTransaction = { _ in throw Boom() }
        deliver(
            .request(
                id: "1",
                method: BridgeMethod.sendTransaction.rawValue,
                params: .object([
                    "chainId": .number(8453),
                    "token": .string(NativeToken.address),
                    "amount": .string("1"),
                    "to": .string("0x2222222222222222222222222222222222222222"),
                    "from": .string("0x1111111111111111111111111111111111111111"),
                ])
            )
        )
        let failure = error(in: await answer(to: "1"))
        XCTAssertEqual(failure?.code, BridgeErrorCode.submissionUncertain.rawValue)
        XCTAssertEqual(failure?.domain, BridgeErrorDomain.bridge)
    }

    func testFailsANonSubmittingMethodRetryably() async {
        struct Boom: Error {}
        handlers.signRecovery = { _ in throw Boom() }
        deliver(
            .request(
                id: "1",
                method: BridgeMethod.signRecovery.rawValue,
                params: .object([
                    "chainId": .number(8453),
                    "signer": .string("0x1111111111111111111111111111111111111111"),
                    "depositId": .string("4242"),
                    "destination": .string("0x2222222222222222222222222222222222222222"),
                ])
            )
        )
        let failure = error(in: await answer(to: "1"))
        XCTAssertEqual(failure?.code, -32603)
    }

    /// A host that knows why it failed says so, and the page renders that copy.
    func testPassesAHostsOwnRefusalThrough() async {
        handlers.sendTransaction = { _ in throw BridgeHost.Failure.userRejected("Not today.") }
        deliver(
            .request(
                id: "1",
                method: BridgeMethod.sendTransaction.rawValue,
                params: .object([
                    "chainId": .number(8453),
                    "token": .string(NativeToken.address),
                    "amount": .string("1"),
                    "to": .string("0x2222222222222222222222222222222222222222"),
                    "from": .string("0x1111111111111111111111111111111111111111"),
                ])
            )
        )
        let failure = error(in: await answer(to: "1"))
        XCTAssertEqual(failure?.code, 4001)
        XCTAssertEqual(failure?.message, "Not today.")
    }

    /**
     A host that forwards `host.openUrl` to an OS-level open without checking
     has published an app-launch primitive to whatever reaches the channel.
     */
    func testRefusesAPaymentURLThatIsNotHTTPS() async {
        var opened: String?
        handlers.openURL = { params in opened = params.url }
        deliver(
            .request(
                id: "1",
                method: BridgeMethod.openURL.rawValue,
                params: .object(["url": .string("myapp://pay")])
            )
        )
        let failure = error(in: await answer(to: "1"))
        XCTAssertEqual(failure?.code, -32602)
        XCTAssertNil(opened)
    }

    // MARK: - Capabilities

    /**
     Derived, never declared. A list an integrator passes alongside the handlers
     is a list that can disagree with them, and both directions are bad: an
     over-claim answers 4200 on a screen the page already offered, and an
     under-claim hides a payment method the app supports.
     */
    func testDerivesCapabilitiesFromTheHandlers() {
        XCTAssertEqual(host.capabilities, [Capability.probeFrameScope.rawValue])

        handlers.openURL = { _ in }
        handlers.sendTransaction = { _ in SendTransactionResult(txHash: "0x0") }
        XCTAssertEqual(
            Set(host.capabilities),
            [
                Capability.sendTransaction.rawValue,
                Capability.openURL.rawValue,
                Capability.probeFrameScope.rawValue,
            ]
        )
    }

    // MARK: - Back

    func testABackGestureBeforeTheHandshakeIsNotHandled() async {
        let result = await host.back()
        XCTAssertFalse(result.handled)
        XCTAssertTrue(sent.isEmpty, "nothing to ask: the page has not said hello")
    }

    /**
     A page that stops answering resolves permissively, because the dismissal
     policy is applied separately — and a page that has stopped answering has
     also stopped telling us it is locked.
     */
    func testABackGestureTimesOutAsNotHandled() async {
        deliver(.request(id: "1", method: BridgeMethod.hello.rawValue, params: nil))
        _ = await answer(to: "1")

        let result = await host.back()
        XCTAssertFalse(result.handled)
    }

    func testABackGestureTakesThePagesAnswer() async {
        deliver(.request(id: "1", method: BridgeMethod.hello.rawValue, params: nil))
        _ = await answer(to: "1")

        async let pending = host.back()
        // The page answers the outstanding `ui.back`, whose id the host minted.
        for _ in 0..<50 {
            if let request = sent.compactMap({ frame -> String? in
                if case .request(let id, let method, _) = frame,
                    method == HostMethod.back.rawValue
                {
                    return id
                }
                return nil
            }).first {
                deliver(.response(id: request, outcome: .success(.object(["handled": .bool(true)]))))
                break
            }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        let result = await pending
        XCTAssertTrue(result.handled)
    }

    /// A closed host answers nothing and sends nothing — the sheet is gone, and
    /// a frame arriving after it is not a failure.
    func testAClosedHostStopsAnsweringAndCountsTheDrops() async {
        host.close()
        deliver(.request(id: "1", method: BridgeMethod.hello.rawValue, params: nil))
        XCTAssertTrue(sent.isEmpty)
        XCTAssertEqual(host.drops[.closed], 1)
    }
}
