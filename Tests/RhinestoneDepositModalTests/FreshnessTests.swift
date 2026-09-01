import Foundation
import XCTest

@testable import RhinestoneDepositModal

/**
 Whether the PAGE has moved, which is a property of time rather than of a pull
 request — so this runs on a schedule and skips itself otherwise. The PR gate is
 `ConformanceTests`, which replays the vendored copy and needs no network.

 **Names only.** The React Native wrapper's check also diffs every recorded
 frame's shape; this one compares vocabularies, so a page that retypes a field
 inside a frame passes here until the transcript is re-vendored. That gap is
 deliberate for now and worth closing — it is the half that catches a rename a
 human would not.

 **Additions are not failures.** The contract's own discipline is that an
 existing field never changes meaning or type, new fields are optional, and a
 receiver ignores what it does not know — so a page that adds a method or an
 event has not broken this wrapper, and reddening a scheduled job for it would
 train people to re-vendor without reading.
 */
final class FreshnessTests: XCTestCase {
    /// Set by the scheduled workflow. Dev tracks `main` in `deposit-modal`, so
    /// a contract change lands there first; prod moves once per release.
    private static let originKey = "RHINESTONE_EMBED_ORIGIN"

    func testTheVendoredTranscriptStillNamesWhatThePageServes() async throws {
        guard let origin = ProcessInfo.processInfo.environment[Self.originKey],
            !origin.isEmpty
        else {
            throw XCTSkip("Set \(Self.originKey) to check against a served page.")
        }
        let url = try XCTUnwrap(
            URL(string: origin.hasSuffix("/") ? "\(origin)bridge-transcript.json"
                : "\(origin)/bridge-transcript.json")
        )

        let (data, response) = try await URLSession.shared.data(from: url)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        XCTAssertTrue((200..<300).contains(status), "\(url) answered \(status)")

        let published = try JSONDecoder().decode(Transcript.self, from: data)
        let vendored = try Transcript.load()

        XCTAssertEqual(
            published.transcriptFormat,
            vendored.transcriptFormat,
            "the page publishes a transcript format this wrapper's replay cannot read"
        )

        // A protocol bump is additive by the page's own rule, so a higher
        // number is not a break. A LOWER one means the vendored copy came from
        // somewhere ahead of what is deployed.
        XCTAssertGreaterThanOrEqual(
            published.vocabulary.protocol,
            vendored.vocabulary.protocol,
            "protocol went backwards: the deploy is behind this wrapper"
        )

        var breaks: [String] = []
        func check(_ label: String, _ mine: [String], _ theirs: [String]) {
            for name in mine where !theirs.contains(name) {
                breaks.append("\(label): \"\(name)\" no longer exists")
            }
        }
        check("pageMethods", vendored.vocabulary.pageMethods, published.vocabulary.pageMethods)
        check("hostMethods", vendored.vocabulary.hostMethods, published.vocabulary.hostMethods)
        check("pageEvents", vendored.vocabulary.pageEvents, published.vocabulary.pageEvents)
        check("hostEvents", vendored.vocabulary.hostEvents, published.vocabulary.hostEvents)
        check("capabilities", vendored.vocabulary.capabilities, published.vocabulary.capabilities)
        check("walletMethods", vendored.vocabulary.walletMethods, published.vocabulary.walletMethods)
        check(
            "dismissalReasons",
            vendored.vocabulary.dismissalReasons,
            published.vocabulary.dismissalReasons
        )
        check(
            "dismissSources",
            vendored.vocabulary.dismissSources,
            published.vocabulary.dismissSources
        )

        for (name, code) in vendored.vocabulary.errorCodes {
            let now = published.vocabulary.errorCodes[name]
            if now == nil {
                breaks.append("errorCodes: \"\(name)\" no longer exists")
            } else if now != code {
                breaks.append("errorCodes: \"\(name)\" changed \(code) → \(now!)")
            }
        }

        // Values this wrapper hard-codes and must EQUAL. Lowered, it sends
        // frames the page drops; raised, it drops frames the page now considers
        // legal. Neither direction is an addition.
        if published.vocabulary.channels != vendored.vocabulary.channels {
            breaks.append("the channel names changed")
        }
        if published.vocabulary.maxFrameLength != vendored.vocabulary.maxFrameLength {
            breaks.append(
                "maxFrameLength changed \(vendored.vocabulary.maxFrameLength) → \(published.vocabulary.maxFrameLength)"
            )
        }
        if published.vocabulary.errorDomain != vendored.vocabulary.errorDomain {
            breaks.append("the error domain changed")
        }
        // No frame comparison could reach these: the fields cross the channel
        // and the struct is compiled in, so a reorder derives a different
        // separator and produces a signature the processor rejects.
        if published.vocabulary.signRecovery?.encodeType
            != vendored.vocabulary.signRecovery?.encodeType
            || published.vocabulary.signRecovery?.domainEncodeType
                != vendored.vocabulary.signRecovery?.domainEncodeType
        {
            breaks.append("the EIP-712 recovery struct changed")
        }

        XCTAssertEqual(
            breaks,
            [],
            """
            This wrapper speaks a contract \(origin) does not. Fix Protocol.swift to \
            match, re-vendor the transcript, and make ConformanceTests pass. Do not \
            re-vendor alone — that silences the check without fixing the wrapper.
            """
        )
    }
}

extension TranscriptVocabulary.Channels: Equatable {
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.pageToHost == rhs.pageToHost && lhs.hostToPage == rhs.hostToPage
    }
}
