import Foundation
import XCTest

@testable import RhinestoneDepositModal

/**
 The page's published contract, replayed against this host.

 `Protocol.swift` is a hand-maintained copy of the page's, and discipline is not
 a plan for four copies. This is what keeps them together mechanically: a
 renamed method, a renamed or retyped field, a changed error code or a changed
 envelope fails here rather than on a device.

 Two halves, and both are needed. The vocabulary checks pin every NAME against
 the enums in `Protocol.swift`. The replay drives every recorded page→host
 request through the real host and compares the answer's shape against what the
 page recorded reading — a name can be right while the answer is a shape the
 page cannot read.
 */
@MainActor
final class ConformanceTests: XCTestCase {
    private var transcript: Transcript!

    override func setUpWithError() throws {
        transcript = try Transcript.load()
    }

    // MARK: - The artifact

    func testIsAFormatThisWrapperCanRead() {
        XCTAssertEqual(transcript.transcriptFormat, Transcript.supportedFormat)
    }

    // MARK: - The vocabulary this wrapper declares

    func testSpeaksTheSameProtocolVersion() {
        XCTAssertEqual(transcript.vocabulary.protocol, BridgeProtocol.version)
    }

    func testInstallsTheChannelsUnderTheNamesThePageUses() {
        XCTAssertEqual(
            transcript.vocabulary.channels.pageToHost,
            BridgeProtocol.pageToHostChannel
        )
        XCTAssertEqual(
            transcript.vocabulary.channels.hostToPage,
            BridgeProtocol.hostToPageChannel
        )
        // Lowered, this host sends frames the page drops; raised, it drops
        // frames the page considers legal. Neither direction is an addition.
        XCTAssertEqual(transcript.vocabulary.maxFrameLength, BridgeProtocol.maxFrameLength)
    }

    func testNamesEveryMethodTheSameWay() {
        XCTAssertEqual(
            Set(transcript.vocabulary.pageMethods),
            Set(BridgeMethod.allCases.map(\.rawValue))
        )
        XCTAssertEqual(
            Set(transcript.vocabulary.hostMethods),
            Set(HostMethod.allCases.map(\.rawValue))
        )
        XCTAssertEqual(
            Set(transcript.vocabulary.capabilities),
            Set(Capability.allCases.map(\.rawValue))
        )
    }

    func testNamesEveryEventTheSameWay() {
        XCTAssertEqual(
            Set(transcript.vocabulary.pageEvents),
            Set(PageEvent.allCases.map(\.rawValue))
        )
        XCTAssertEqual(
            Set(transcript.vocabulary.hostEvents),
            Set(HostEvent.allCases.map(\.rawValue))
        )
    }

    /// The signing surface this wrapper exposes. An extra name here is a method
    /// the page never sends being forwarded to a wallet; a missing one refuses
    /// the page's own deposit.
    func testAllowsExactlyTheWalletMethodsThePageSends() {
        XCTAssertEqual(
            Set(transcript.vocabulary.walletMethods),
            Set(AllowedWalletMethod.allCases.map(\.rawValue))
        )
    }

    /// Both are fields this host READS out of a payload, not prose: the sheet
    /// stays open on a reason it does not recognise, and a dismissal source
    /// decides whether a completed flow closes itself.
    func testNamesEveryDismissalReasonAndSourceTheSameWay() {
        XCTAssertEqual(
            Set(transcript.vocabulary.dismissalReasons),
            Set(BlockedReason.allCases.map(\.rawValue))
        )
        XCTAssertEqual(
            Set(transcript.vocabulary.dismissSources),
            Set(DismissSource.allCases.map(\.rawValue))
        )
    }

    /**
     The EIP-712 struct, compared verbatim.

     No frame comparison could reach it: `host.signRecovery` sends the FIELDS
     and the host compiles the struct in, so these cross the channel only as
     their consequence. The field array is hashed in declared order, so a
     reorder derives a different separator and produces a signature that is well
     formed, passes locally, and is rejected by the processor.
     */
    func testCompilesTheSameEIP712StructThePagePublishes() throws {
        let recovery = try XCTUnwrap(transcript.vocabulary.signRecovery)
        XCTAssertEqual(recovery.domain["name"], SignRecovery.domainName)
        XCTAssertEqual(recovery.domain["version"], SignRecovery.domainVersion)
        XCTAssertEqual(recovery.primaryType, SignRecovery.primaryType)
        XCTAssertEqual(recovery.encodeType, SignRecovery.encodeType)
        XCTAssertEqual(recovery.domainEncodeType, SignRecovery.domainEncodeType)
    }

    func testAgreesOnTheErrorDomainAndEveryCode() {
        XCTAssertEqual(transcript.vocabulary.errorDomain, BridgeErrorDomain.bridge)

        // The artifact keys these by the page's own constant names, which are
        // SCREAMING_SNAKE where Swift is camel. Compare the SET of codes and
        // then each one by name, so a renumbering fails loudly and a rename on
        // either side does not read as one.
        XCTAssertEqual(
            Set(transcript.vocabulary.errorCodes.values),
            Set(BridgeErrorCode.allCases.map(\.rawValue))
        )
        let expected: [String: BridgeErrorCode] = [
            "WALLET_UNAVAILABLE": .walletUnavailable,
            "SUBMISSION_UNCERTAIN": .submissionUncertain,
            "REQUEST_TIMEOUT": .requestTimeout,
            "CHANNEL_CLOSED": .channelClosed,
            "MALFORMED_RESULT": .malformedResult,
        ]
        for (name, code) in expected {
            XCTAssertEqual(
                transcript.vocabulary.errorCodes[name],
                code.rawValue,
                "\(name) is not the code this wrapper answers with"
            )
        }
    }

    // MARK: - Replaying every recorded page→host request

    func testHasRequestsToReplay() {
        XCTAssertFalse(recordedRequests.isEmpty)
    }

    func testAnswersEveryRecordedRequest() async throws {
        for frame in recordedRequests {
            let name =
                frame.walletMethod.map { "\(frame.method ?? "?") (\($0))" }
                ?? (frame.method ?? "?")
            let harness = RecordingHost()
            let answer = try await harness.request(
                method: XCTUnwrap(frame.method),
                params: frame.shape.flatMap { materialize($0) }
            )

            guard case .response(_, let outcome) = try XCTUnwrap(answer, "\(name) went unanswered")
            else { return XCTFail("\(name) was not answered with a response") }

            // A 4200 here means this host does not implement a method the page
            // sends, which is the drift the whole artifact exists to catch —
            // every handler is supplied, so nothing legitimately refuses.
            if case .failure(let error) = outcome {
                XCTAssertNotEqual(error.code, 4200, "\(name) was refused as unsupported")
            }

            // Matched on the wallet method too: one union across all six
            // results accepts a string where a send's hash belongs and `null`
            // where an account list does, and the page's own decoder refuses
            // that — a wrapper could replay green while stranding a transfer
            // the page cannot read.
            let recorded = transcript.frames.first { candidate in
                candidate.dir == "host->page" && candidate.kind == "response"
                    && candidate.answers == frame.method
                    && candidate.walletMethod == frame.walletMethod && candidate.ok == true
            }
            guard let recordedShape = recorded?.shape else { continue }

            guard case .success(let result) = outcome else {
                return XCTFail("\(name) answered with an error where the page recorded a result")
            }
            XCTAssertEqual(
                mismatches(structureOf(result), recordedShape),
                [],
                "\(name) answered a shape the page does not expect"
            )
        }
    }

    /**
     What the page SENDS, as opposed to what it reads back.

     The replay proves the host answers; it cannot prove the answer was computed
     from the right fields, because the handlers there ignore their params. A
     page that renamed `to` to `recipient` would hand the wrapper an object with
     no `to` in it, every handler would answer exactly as before, and the
     integrator's app — which reads `params.to` — would transfer nothing.

     Each field is named through this wrapper's own parameter type, so a rename
     in `Protocol.swift` fails to compile rather than failing here; and its value
     is asserted at runtime, so a rename or a retype on the PAGE's side fails
     here.
     */
    func testHandsSendTransactionTheTransferNotAnEmptyObject() async throws {
        let frame = try XCTUnwrap(recordedRequest(method: BridgeMethod.sendTransaction.rawValue))
        let harness = RecordingHost()
        _ = try await harness.request(
            method: BridgeMethod.sendTransaction.rawValue,
            params: frame.shape.flatMap { materialize($0) }
        )

        let transfer = try XCTUnwrap(harness.sendTransactionParams)
        XCTAssertEqual(transfer.to, ConstrainedLeaf.strings["to"])
        XCTAssertEqual(transfer.from, ConstrainedLeaf.strings["from"])
        XCTAssertEqual(transfer.token, ConstrainedLeaf.strings["token"])
        XCTAssertEqual(transfer.amount, ConstrainedLeaf.strings["amount"])
        XCTAssertEqual(Double(transfer.chainId), ConstrainedLeaf.numbers["chainId"])
    }

    func testHandsSignRecoveryTheDepositItIsSigningFor() async throws {
        let frame = try XCTUnwrap(recordedRequest(method: BridgeMethod.signRecovery.rawValue))
        let harness = RecordingHost()
        _ = try await harness.request(
            method: BridgeMethod.signRecovery.rawValue,
            params: frame.shape.flatMap { materialize($0) }
        )

        let request = try XCTUnwrap(harness.signRecoveryParams)
        // A decimal string, never a number: a uint256 routinely exceeds what a
        // Double holds exactly, and the wrong one here signs for another
        // deposit.
        XCTAssertEqual(request.depositId, ConstrainedLeaf.strings["depositId"])
        XCTAssertEqual(request.destination, ConstrainedLeaf.strings["destination"])
        XCTAssertEqual(request.signer, ConstrainedLeaf.strings["signer"])
    }

    func testHandsOpenURLAURL() async throws {
        let frame = try XCTUnwrap(recordedRequest(method: BridgeMethod.openURL.rawValue))
        let harness = RecordingHost()
        _ = try await harness.request(
            method: BridgeMethod.openURL.rawValue,
            params: frame.shape.flatMap { materialize($0) }
        )

        XCTAssertEqual(harness.openedURL, ConstrainedLeaf.strings["url"])
    }

    /**
     Hello is the frame every wrapper gets wrong first, and the only one whose
     answer the page cannot recover from: it configures the whole session.
     */
    func testBuildsHelloWithEveryFieldThePageReads() async throws {
        let recorded = try XCTUnwrap(
            transcript.frames.first {
                $0.dir == "host->page" && $0.kind == "response"
                    && $0.answers == BridgeMethod.hello.rawValue && $0.ok == true
            }?.shape
        )
        let harness = RecordingHost()
        let answer = try await harness.request(
            method: BridgeMethod.hello.rawValue,
            params: .object(["protocol": .number(2), "modalVersion": .string("0.0.0-test")])
        )
        guard case .response(_, .success(let result)) = try XCTUnwrap(answer) else {
            return XCTFail("hello was not answered")
        }

        XCTAssertEqual(mismatches(structureOf(result), recorded), [])
        XCTAssertEqual(harness.helloParams?.modalVersion, "0.0.0-test")
    }

    /// Both host events, under the recorded names. Nothing else this host sends
    /// is unsolicited, so these are the only two the page has to recognise.
    func testEmitsBothHostEventsUnderTheRecordedNames() async throws {
        let harness = RecordingHost()
        _ = try await harness.request(
            method: BridgeMethod.hello.rawValue,
            params: .object(["protocol": .number(2), "modalVersion": .string("0.0.0-test")])
        )
        harness.host.configure(RecordingHost.config)
        harness.host.pushWalletState(RecordingHost.wallet)

        let emitted = harness.sent.compactMap { frame -> String? in
            if case .event(let type, _) = frame { return type }
            return nil
        }
        for event in transcript.vocabulary.hostEvents {
            XCTAssertTrue(emitted.contains(event), "\(event) was never emitted")
        }
    }

    // MARK: - Helpers

    private var recordedRequests: [TranscriptFrame] {
        transcript.frames.filter { $0.dir == "page->host" && $0.kind == "request" }
    }

    private func recordedRequest(method: String) -> TranscriptFrame? {
        recordedRequests.first { $0.method == method }
    }
}
