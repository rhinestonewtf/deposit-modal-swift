import Foundation

/**
 The half of the flow that has to outlive the web view.

 A deposit settles on our side, not in the page: the user funds it, and the
 backend finishes the job whether or not anything is watching. But the sheet is
 the only thing watching, and iOS kills a backgrounded web view routinely — so a
 user who backgrounds the app mid-settlement comes back to a blank sheet, with
 the deposit long since complete.

 This polls `GET /deposits` for the same recipient while the wrapper is alive,
 which is the reopen case the history panel already covers made to work while
 the app is merely backgrounded. No background scheduler and no push: the moment
 the process is gone this stops, and the history panel takes over.
 */
public struct DepositRow: Codable, Equatable, Sendable {
    public var chain: String?
    public var txHash: String
    public var token: String?
    public var amount: String?
    public var status: String
    public var targetChain: String?
    public var targetToken: String?
    public var sourceTxHash: String?
    public var destinationTxHash: String?
    public var sourceAmount: String?
    public var destinationAmount: String?
    public var createdAt: String?
    public var completedAt: String?
}

public enum DepositStatus {
    /**
     Anything else — `pending`, `processing`, a status added later — is in
     flight. Read as a closed set of *finished* states rather than a closed set
     of live ones, so a new backend status is treated as "still going" instead
     of being reported as a completion.
     */
    public static let terminal: Set<String> = ["completed", "failed", "refunded"]

    public static func isTerminal(_ status: String) -> Bool {
        terminal.contains(status.lowercased())
    }
}

/// Outside the class so a default argument can reach it without crossing an
/// actor boundary.
public enum DepositWatchDefaults {
    public static let pollInterval: TimeInterval = 8
}

@MainActor
public final class DepositWatch {
    private struct Response: Decodable {
        let deposits: [DepositRow]?
    }

    private let backendURL: String
    private let recipient: String
    private let versionHeader: String
    private let interval: TimeInterval
    private let limit: Int
    private let session: URLSession
    private let onSettled: (DepositRow) -> Void
    private let onError: ((Error) -> Void)?

    /// Every txHash reported, so a deposit settles once however many polls see
    /// it. Also seeded by the first pass.
    private var reported: Set<String> = []
    private var baselineTaken = false
    private var baselineInFlight = false
    /// Set when an attempt at the baseline fails, which changes what the
    /// eventual baseline is allowed to suppress.
    private var baselineDegraded = false
    /**
     Device time at `start()`, used only on a degraded baseline.

     Comparing it against the backend's `completedAt` means trusting two clocks
     against each other, so it is deliberately not on the normal path: a
     baseline taken first time round suppresses on status alone and no clock
     enters into it.
     */
    private var startedAt = ""
    private var ticker: Task<Void, Never>?
    private var inFlight: Task<Void, Never>?
    private var running = false

    public init(
        backendURL: String,
        recipient: String,
        versionHeader: String,
        interval: TimeInterval = DepositWatchDefaults.pollInterval,
        limit: Int = 20,
        session: URLSession = .shared,
        onSettled: @escaping (DepositRow) -> Void,
        onError: ((Error) -> Void)? = nil
    ) {
        self.backendURL = backendURL
        self.recipient = recipient
        self.versionHeader = versionHeader
        self.interval = interval
        self.limit = limit
        self.session = session
        self.onSettled = onSettled
        self.onError = onError
    }

    public func start() {
        guard !running else { return }
        running = true
        if startedAt.isEmpty { startedAt = Self.now() }
        Task { await poll() }
        ticker = Task { [weak self, interval] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard !Task.isCancelled else { return }
                await self?.poll()
            }
        }
    }

    public func stop() {
        running = false
        ticker?.cancel()
        ticker = nil
        inFlight?.cancel()
        inFlight = nil
    }

    /**
     One pass, for a nudge on return from the payment browser.

     Not gated on `running`: the interval is, but an explicit poll is something
     the caller asked for — coming back from the browser is the case, and that
     arrives as a scene-activation notice rather than as a tick.
     */
    public func poll() async {
        if startedAt.isEmpty { startedAt = Self.now() }
        // The poll that takes the baseline must be allowed to finish.
        // Cancelling it hands the baseline to a later response, and every
        // terminal row in THAT one is suppressed as history — including the
        // deposit that settled while the user was away, which is the single
        // case this whole watch exists for. Returning from the payment browser
        // is exactly when both happen at once.
        if !baselineTaken && baselineInFlight { return }

        inFlight?.cancel()
        if !baselineTaken { baselineInFlight = true }
        defer { baselineInFlight = false }

        guard var components = URLComponents(string: Self.trimmed(backendURL) + "/deposits") else {
            return
        }
        components.queryItems = [
            URLQueryItem(name: "recipient", value: recipient),
            URLQueryItem(name: "limit", value: String(limit)),
        ]
        guard let url = components.url else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(versionHeader, forHTTPHeaderField: WrapperVersion.header)

        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else {
                if !baselineTaken { baselineDegraded = true }
                onError?(DepositWatchError.pollFailed(status: status))
                return
            }
            let deposits = (try JSONDecoder().decode(Response.self, from: data).deposits) ?? []
            absorb(deposits)
        } catch {
            if Task.isCancelled { return }
            if !baselineTaken { baselineDegraded = true }
            onError?(error)
        }
    }

    private func absorb(_ deposits: [DepositRow]) {
        // The first pass suppresses what was ALREADY finished when the watch
        // started — the user's deposit history, which would otherwise announce
        // itself as a fresh settlement the moment the sheet opened. A row that
        // is in flight at baseline is deliberately left unreported, so the
        // completion it is heading for still fires.
        if !baselineTaken {
            for deposit in deposits where DepositStatus.isTerminal(deposit.status) {
                reported.insert(deposit.txHash)
                // A baseline that had to wait for a retry covers a window it
                // did not watch, and anything that settled inside it would be
                // suppressed as history — silently, and it is the one case this
                // whole watch is for. So on the degraded path a completion
                // later than the watch's own start is news, and is delivered
                // from the baseline pass. Over-reporting an old deposit is
                // visible and recoverable; missing a real one is not.
                if baselineDegraded, completedAfter(deposit, startedAt) { onSettled(deposit) }
            }
            baselineTaken = true
            return
        }

        for deposit in deposits {
            guard !reported.contains(deposit.txHash) else { continue }
            // A row that is new AND already terminal is the case this exists
            // for: the deposit both started and finished while the web view was
            // dead.
            guard DepositStatus.isTerminal(deposit.status) else { continue }
            reported.insert(deposit.txHash)
            onSettled(deposit)
        }
    }

    /// Both are ISO-8601 UTC, which compares correctly as text, and a row with
    /// no `completedAt` answers `false` — an unknown completion time is treated
    /// as old, which is the direction that does not invent news.
    private func completedAfter(_ deposit: DepositRow, _ instant: String) -> Bool {
        guard !instant.isEmpty, let completed = deposit.completedAt else { return false }
        return completed > instant
    }

    private static func trimmed(_ url: String) -> String {
        url.hasSuffix("/") ? String(url.dropLast()) : url
    }

    private static func now() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: Date())
    }
}

public enum DepositWatchError: LocalizedError {
    case pollFailed(status: Int)

    public var errorDescription: String? {
        switch self {
        case .pollFailed(let status): return "Deposit poll failed: \(status)"
        }
    }
}
