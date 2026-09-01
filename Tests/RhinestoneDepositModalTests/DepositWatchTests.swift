import Foundation
import XCTest

@testable import RhinestoneDepositModal

/// Answers the watch is given, on a schedule the test controls.
final class StubProtocol: URLProtocol {
    struct Reply {
        var status = 200
        var body = #"{"deposits":[]}"#
        /// Held before answering, so a test can stop the watch mid-request.
        var delay: TimeInterval = 0
    }

    nonisolated(unsafe) static var reply = Reply()
    nonisolated(unsafe) static var requests: [URLRequest] = []

    static func reset() {
        reply = Reply()
        requests = []
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requests.append(request)
        let reply = Self.reply
        let deliver = { [weak self] in
            guard let self, let url = self.request.url else { return }
            let response = HTTPURLResponse(
                url: url,
                statusCode: reply.status,
                httpVersion: nil,
                headerFields: nil
            )!
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: Data(reply.body.utf8))
            self.client?.urlProtocolDidFinishLoading(self)
        }
        if reply.delay > 0 {
            DispatchQueue.global().asyncAfter(deadline: .now() + reply.delay, execute: deliver)
        } else {
            deliver()
        }
    }

    override func stopLoading() {}
}

@MainActor
final class DepositWatchTests: XCTestCase {
    private var settled: [DepositRow] = []

    private static let terminal = #"""
        {"deposits":[{"txHash":"0xabc","status":"completed","completedAt":"2999-01-01T00:00:00Z"}]}
        """#

    override func setUp() {
        super.setUp()
        settled = []
        StubProtocol.reset()
    }

    private func makeWatch() -> DepositWatch {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return DepositWatch(
            backendURL: "https://proxy.example.com",
            recipient: "0x1111111111111111111111111111111111111111",
            versionHeader: "0.0.0 (ios)",
            session: URLSession(configuration: configuration),
            onSettled: { [weak self] deposit in self?.settled.append(deposit) }
        )
    }

    /// The baseline suppresses what was already finished when the watch
    /// started — a user's deposit history, which would otherwise announce
    /// itself as a fresh settlement the moment the sheet opened.
    func testTheFirstPassIsABaselineAndReportsNothing() async {
        StubProtocol.reply.body = Self.terminal
        let watch = makeWatch()
        await watch.poll()
        XCTAssertEqual(settled.count, 0)
    }

    func testAnewTerminalRowAfterTheBaselineIsReportedOnce() async {
        let watch = makeWatch()
        await watch.poll()

        StubProtocol.reply.body = Self.terminal
        await watch.poll()
        await watch.poll()
        XCTAssertEqual(settled.map(\.txHash), ["0xabc"])
    }

    /**
     A watch is stopped when the sheet closes or the corridor moves, and both
     are cases where a late answer is worse than none: it reports a settlement
     after dismissal, or one belonging to the recipient the app just switched
     away from.

     This is the case a cancel that cancels nothing passes: the request runs to
     completion regardless, and the only thing standing between it and the
     integrator's callback is the delivery guard.
     */
    func testAStoppedWatchDoesNotDeliverAnAnswerThatLandsLate() async {
        let watch = makeWatch()
        await watch.poll()

        StubProtocol.reply.body = Self.terminal
        StubProtocol.reply.delay = 0.2
        let asked = StubProtocol.requests.count
        let polling = Task { await watch.poll() }

        // The stop has to land while the request is genuinely out. Both this
        // test and `poll()` run on the main actor, so stopping without waiting
        // would run FIRST and be refused at the entry guard — passing without
        // exercising anything.
        var waited = 0
        while StubProtocol.requests.count == asked, waited < 200 {
            try? await Task.sleep(nanoseconds: 1_000_000)
            waited += 1
        }
        XCTAssertGreaterThan(StubProtocol.requests.count, asked, "the poll never left")

        watch.stop()
        await polling.value

        XCTAssertEqual(settled.count, 0, "a stopped watch reported a settlement")
    }

    func testAStoppedWatchDoesNotPollAgain() async {
        let watch = makeWatch()
        await watch.poll()
        let asked = StubProtocol.requests.count

        watch.stop()
        await watch.poll()
        XCTAssertEqual(StubProtocol.requests.count, asked)
    }

    /// The wrapper's own calls carry the same header the page's do, or a mobile
    /// integration shows up at the processor as two unrelated clients.
    func testItCarriesTheVersionHeader() async {
        let watch = makeWatch()
        await watch.poll()
        XCTAssertEqual(
            StubProtocol.requests.first?.value(forHTTPHeaderField: WrapperVersion.header),
            "0.0.0 (ios)"
        )
    }
}
