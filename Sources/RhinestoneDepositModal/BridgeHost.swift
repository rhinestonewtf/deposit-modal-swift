import Foundation

/**
 How long a back gesture waits for the page.

 A hardware back that hangs feels broken, and a back that dismisses a sheet
 mid-signature loses money, so neither direction is free. The deadline is short
 and its expiry resolves `handled: false` — the *permissive* answer — because
 the dismissal policy is applied separately and independently, and a page that
 has stopped answering has also stopped telling us it is locked.

 Outside the class so a default argument can reach it without crossing an actor
 boundary.
 */
public enum BridgeHostDefaults {
    public static let backTimeoutMilliseconds = 1_200
}

/**
 The host half of the bridge: correlation, dispatch, and what to do with frames
 that do not fit.

 Deliberately free of WebKit and UIKit. It takes a `post` closure and is handed
 strings; everything about presenting a web view lives in `DepositSheetView`.
 That is what lets the whole contract be tested on a laptop, and it is the same
 split the page makes on its side.

 The rule throughout mirrors the page's: a misfit frame is dropped and counted,
 never turned into a user-visible failure. The page is another process with its
 own bugs; this side's job is to remain a host.
 */
@MainActor
public final class BridgeHost {
    // MARK: - Handlers

    /// Not `Sendable`: every handler runs on the main actor, which is where the
    /// web view and the host both live.
    public struct Handlers {
        /// The wallet the page drives, CAIP-27. Omit for a deposit flow that
        /// offers QR and transfer only.
        public var walletRequest: (@MainActor (Caip27Params) async throws -> JSONValue)?
        /// Withdraw's transfer. Supplying it announces
        /// `Capability.sendTransaction`.
        public var sendTransaction:
            (@MainActor (SendTransactionParams) async throws -> SendTransactionResult)?
        /// Claim's signature. Supplying it announces `Capability.signRecovery`.
        public var signRecovery:
            (@MainActor (SignRecoveryParams) async throws -> SignRecoveryResult)?
        /// Present a browser over the app. Supplying it announces
        /// `Capability.openURL`; without it the page offers no card row at all.
        public var openURL: (@MainActor (OpenURLParams) async throws -> Void)?

        public init(
            walletRequest: (@MainActor (Caip27Params) async throws -> JSONValue)? = nil,
            sendTransaction: (
                @MainActor (SendTransactionParams) async throws -> SendTransactionResult
            )? = nil,
            signRecovery: (@MainActor (SignRecoveryParams) async throws -> SignRecoveryResult)? =
                nil,
            openURL: (@MainActor (OpenURLParams) async throws -> Void)? = nil
        ) {
            self.walletRequest = walletRequest
            self.sendTransaction = sendTransaction
            self.signRecovery = signRecovery
            self.openURL = openURL
        }
    }

    /// The three failures a host has words for. Anything else a handler throws
    /// is mapped by `toBridgeError`.
    public enum Failure {
        /// EIP-1193 4001. The user saw the request and said no.
        public static func userRejected(_ message: String = "Request rejected.") -> BridgeError {
            BridgeError(code: 4001, message: message)
        }

        /// A wallet exists but could not be reached.
        public static func walletUnavailable(
            _ message: String = "Your wallet could not be reached."
        ) -> BridgeError {
            bridgeError(.walletUnavailable, message)
        }

        /**
         The send may already be on chain.

         Throw this whenever an app switch, a process death or an SDK timeout
         leaves you unable to say. The page has copy for it that does not invite
         a retry, which no other answer does.
         */
        public static func submissionUncertain(
            _ message: String =
                "Your wallet may have submitted this. Check your activity before trying again."
        ) -> BridgeError {
            bridgeError(.submissionUncertain, message)
        }
    }

    // MARK: - Drops

    public enum DropReason: String, CaseIterable, Sendable {
        case notAString = "not-a-string"
        case foreignFrame = "foreign-frame"
        case tooLarge = "too-large"
        case notJSON = "not-json"
        case notAnObject = "not-an-object"
        case unknownKind = "unknown-kind"
        /// A frame whose `kind` is known but whose required fields are not
        /// there. The page casts where this decodes, so it has no equivalent —
        /// a request with no `id` would answer into the void there.
        case malformedEnvelope = "malformed-envelope"
        case unmatchedResponse = "unmatched-response"
        case badUiState = "bad-ui-state"
        case closed = "closed"
    }

    public private(set) var drops: [DropReason: Int] = [:]

    // MARK: - State

    private let post: (String) -> Void
    private let nonce: String
    private let identity: HostIdentity
    private let currentConfig: () -> EmbedConfig
    private let currentWallet: () -> WalletState
    private let currentHandlers: () -> Handlers
    private let onEvent: ((String, JSONValue?) -> Void)?
    private let onHello: ((HelloParams) -> Void)?
    private let backTimeoutMilliseconds: Int

    private var isClosed = false
    private var backCounter = 0
    private var pendingBacks: [String: PendingBack] = [:]

    /// Latest `ui.state`, or `nil` before the first one.
    public private(set) var uiState: UiStatePayload?
    /// Whether a `hello` has been answered on the current page load.
    public private(set) var connected = false

    private final class PendingBack {
        let resume: (UiBackResult) -> Void
        var timeout: Task<Void, Never>?

        init(resume: @escaping (UiBackResult) -> Void) { self.resume = resume }
    }

    public init(
        post: @escaping (String) -> Void,
        nonce: String,
        identity: HostIdentity,
        config: @escaping () -> EmbedConfig,
        wallet: @escaping () -> WalletState,
        handlers: @escaping () -> Handlers,
        onEvent: ((String, JSONValue?) -> Void)? = nil,
        onHello: ((HelloParams) -> Void)? = nil,
        backTimeoutMilliseconds: Int = BridgeHostDefaults.backTimeoutMilliseconds
    ) {
        self.post = post
        self.nonce = nonce
        self.identity = identity
        self.currentConfig = config
        self.currentWallet = wallet
        self.currentHandlers = handlers
        self.onEvent = onEvent
        self.onHello = onHello
        self.backTimeoutMilliseconds = backTimeoutMilliseconds
    }

    // MARK: - Inbound

    /// Feed it the body of a `WKScriptMessage`, after the frame check.
    public func receive(_ raw: Any?) {
        guard !isClosed else { return drop(.closed) }
        guard let parsed = Injection.parseInboundFrame(raw) else {
            return drop(raw is String ? .foreignFrame : .notAString)
        }
        guard parsed.nonce == nonce else { return drop(.foreignFrame) }
        // UTF-16 because that is what the page counts.
        guard parsed.json.utf16.count <= BridgeProtocol.maxFrameLength else {
            return drop(.tooLarge)
        }
        guard let data = parsed.json.data(using: .utf8),
            let any = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        else { return drop(.notJSON) }
        guard let object = any as? [String: Any] else { return drop(.notAnObject) }
        guard let kind = object["kind"] as? String,
            ["event", "request", "response"].contains(kind)
        else { return drop(.unknownKind) }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else {
            return drop(.malformedEnvelope)
        }
        handle(envelope)
    }

    private func handle(_ envelope: Envelope) {
        switch envelope {
        case .event(let type, let payload):
            if type == PageEvent.uiState.rawValue {
                // Dropped rather than forwarded, so nothing downstream has to
                // wonder whether the lock it is reading is shaped like one. A
                // full snapshot arrives on every change, so the next one heals
                // this.
                guard let state = try? payload?.decoded(as: UiStatePayload.self) else {
                    return drop(.badUiState)
                }
                uiState = state
            }
            onEvent?(type, payload)

        case .request(let id, let method, let params):
            Task { await dispatch(id: id, method: method, params: params) }

        case .response(let id, let outcome):
            guard let pending = pendingBacks[id] else { return drop(.unmatchedResponse) }
            pendingBacks.removeValue(forKey: id)
            pending.timeout?.cancel()
            // `ui.back` is the only host→page request, and its failure arm
            // means the same thing to us as `handled: false`: the page is not
            // taking the gesture, so the dismissal policy decides.
            let result: UiBackResult
            if case .success(let value) = outcome,
                let decoded = try? value.decoded(as: UiBackResult.self)
            {
                result = decoded
            } else {
                result = UiBackResult(handled: false)
            }
            pending.resume(result)
        }
    }

    // MARK: - Dispatch

    private func dispatch(id: String, method: String, params: JSONValue?) async {
        var submitting = false
        do {
            switch BridgeMethod(rawValue: method) {
            case .hello:
                if let hello = try? params?.decoded(as: HelloParams.self) {
                    onHello?(hello)
                }
                connected = true
                respond(
                    id,
                    try JSONValue.encoding(
                        HelloResult(
                            protocolVersion: BridgeProtocol.version,
                            host: identity,
                            capabilities: capabilities,
                            config: currentConfig(),
                            wallet: currentWallet()
                        )
                    )
                )

            case .walletRequest:
                let caip27 = try decode(params, as: Caip27Params.self) {
                    BridgeError(code: -32602, message: "Malformed wallet request.")
                }
                // Enforced here as well as page-side. This is the signing
                // surface the wrapper exposes to whatever reaches the channel,
                // and a pass-through host is one publishing `eth_sign` to it.
                guard let allowed = AllowedWalletMethod(rawValue: caip27.request.method) else {
                    throw unsupportedMethod(caip27.request.method)
                }
                guard let handler = currentHandlers().walletRequest else {
                    throw unsupportedMethod(BridgeMethod.walletRequest.rawValue)
                }
                submitting = allowed.isSubmitting
                respond(id, try await handler(caip27))

            case .sendTransaction:
                guard let handler = currentHandlers().sendTransaction else {
                    return fail(id, unsupportedMethod(method))
                }
                let transfer = try decode(params, as: SendTransactionParams.self) {
                    BridgeError(code: -32602, message: "Malformed transfer request.")
                }
                submitting = true
                respond(id, try JSONValue.encoding(try await handler(transfer)))

            case .signRecovery:
                guard let handler = currentHandlers().signRecovery else {
                    return fail(id, unsupportedMethod(method))
                }
                let request = try decode(params, as: SignRecoveryParams.self) {
                    BridgeError(code: -32602, message: "Malformed recovery request.")
                }
                respond(id, try JSONValue.encoding(try await handler(request)))

            case .probeFrameScope:
                // Reached only by a frame that carried the nonce, which on iOS
                // is only ever the main one — the message handler drops the
                // rest before this sees them, and that drop is the whole answer
                // the page is looking for. Answering here is therefore not a
                // contradiction: it says "the filter let this one through",
                // which for a main-frame probe is correct.
                respond(id, .object([:]))

            case .openURL:
                guard let handler = currentHandlers().openURL else {
                    return fail(id, unsupportedMethod(method))
                }
                // The page only sends a URL from its own provider allow-list,
                // but a host that forwards this to an OS-level open without
                // checking has published an app-launch primitive — a custom
                // scheme, a deep link — to whatever reaches the channel.
                guard let url = params?["url"]?.stringValue,
                    url.lowercased().hasPrefix("https://")
                else {
                    return fail(
                        id,
                        BridgeError(
                            code: -32602,
                            message: "The payment page address is not a secure link."
                        )
                    )
                }
                try await handler(OpenURLParams(url: url))
                // Deliberately empty: the page acts on the ack.
                respond(id, .object([:]))

            case .none:
                fail(id, unsupportedMethod(method))
            }
        } catch {
            fail(id, Self.toBridgeError(error, submitting: submitting))
        }
    }

    private func decode<T: Decodable>(
        _ params: JSONValue?,
        as type: T.Type,
        orThrow error: () -> BridgeError
    ) throws -> T {
        guard let params, let decoded = try? params.decoded(as: type) else { throw error() }
        return decoded
    }

    /**
     What to answer when a handler throws something that is not a `BridgeError`.

     For anything the page can safely retry, -32603 is right. For a send it is
     the one code that must never be used: viem retries -32603 three times on
     its own, and a retried `eth_sendTransaction` is a second broadcast of the
     same transfer. An integrator's handler that threw after calling their
     wallet is exactly the case nobody can resolve from here, so a submitting
     method fails safe to `submissionUncertain` — the page stops and tells the
     user to check, rather than offering a button that sends again.

     The message is only taken from an error that declares one for a human.
     `localizedDescription` on an arbitrary `Error` is "The operation couldn’t be
     completed. (Foo error 1.)", and the page renders this string.
     */
    static func toBridgeError(_ error: Error, submitting: Bool) -> BridgeError {
        if let bridge = error as? BridgeError { return bridge }
        let message =
            (error as? LocalizedError)?.errorDescription
            ?? "The app could not complete this request."
        if submitting { return bridgeError(.submissionUncertain, message) }
        return BridgeError(code: -32603, message: message)
    }

    // MARK: - Outbound

    /**
     What would be announced at hello now, derived from the handlers.

     Capabilities are derived, never declared. A list the integrator passes
     alongside the handlers is a list that can disagree with them, and both
     directions of that disagreement are bad: an over-claim answers 4200 on a
     screen the page already offered, and an under-claim hides a payment method
     the app supports.
     */
    public var capabilities: [String] {
        let handlers = currentHandlers()
        var capabilities: [String] = []
        if handlers.sendTransaction != nil { capabilities.append(Capability.sendTransaction.rawValue) }
        if handlers.signRecovery != nil { capabilities.append(Capability.signRecovery.rawValue) }
        if handlers.openURL != nil { capabilities.append(Capability.openURL.rawValue) }
        // Unconditional, and the one capability with no handler behind it. It
        // says "send me the probe and I will not answer it" — the frame check
        // is what makes that true, and it is always on. Withholding it would
        // only stop the page ever finding out.
        capabilities.append(Capability.probeFrameScope.rawValue)
        return capabilities
    }

    /// Android's hardware back, iOS's interactive swipe.
    public func back() async -> UiBackResult {
        guard !isClosed, connected else { return UiBackResult(handled: false) }
        backCounter += 1
        let id = "host.\(backCounter)"
        return await withCheckedContinuation { continuation in
            let pending = PendingBack { continuation.resume(returning: $0) }
            pendingBacks[id] = pending
            let deadline = backTimeoutMilliseconds
            pending.timeout = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(deadline) * 1_000_000)
                guard !Task.isCancelled else { return }
                self?.settleBack(id, with: UiBackResult(handled: false))
            }
            send(.request(id: id, method: HostMethod.back.rawValue, params: nil))
        }
    }

    private func settleBack(_ id: String, with result: UiBackResult) {
        guard let pending = pendingBacks.removeValue(forKey: id) else { return }
        pending.timeout?.cancel()
        pending.resume(result)
    }

    /// The full snapshot, never a delta.
    public func pushWalletState(_ state: WalletState) {
        emit(.walletState, state)
    }

    public func configure(_ config: EmbedConfig) {
        emit(.sessionConfigure, config)
    }

    public func close() {
        isClosed = true
        for (id, _) in pendingBacks { settleBack(id, with: UiBackResult(handled: false)) }
        pendingBacks.removeAll()
    }

    private func emit<T: Encodable>(_ event: HostEvent, _ payload: T) {
        guard let value = try? JSONValue.encoding(payload) else { return }
        send(.event(type: event.rawValue, payload: value))
    }

    private func respond(_ id: String, _ result: JSONValue) {
        send(.response(id: id, outcome: .success(result)))
    }

    private func fail(_ id: String, _ error: BridgeError) {
        send(.response(id: id, outcome: .failure(error)))
    }

    private func send(_ envelope: Envelope) {
        guard !isClosed else { return drop(.closed) }
        guard let data = try? JSONEncoder().encode(envelope),
            let json = String(data: data, encoding: .utf8)
        else { return }
        post(Injection.encodeFrameForEvaluation(json))
    }

    private func drop(_ reason: DropReason) {
        drops[reason, default: 0] += 1
    }
}
