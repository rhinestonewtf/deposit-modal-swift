import Foundation

/**
 The wire contract, from the host's side.

 A hand-maintained copy of `src/core/bridge/protocol.ts` in
 `rhinestonewtf/deposit-modal`, which is the spec. It is a copy because Swift
 cannot import the page's package, and because the React Native and Android
 wrappers each re-declare the same thing anyway. Four copies is the shape of the
 problem, not a shortcut — what keeps them together is mechanical: the page
 publishes what crosses the channel and `ConformanceTests` replays that artifact
 against this host, so a renamed method, a renamed or retyped field or a changed
 error code fails in CI rather than on a device.

 That is why every name here is a `CaseIterable` enum rather than a bare
 `String`: the replay can only check what it can enumerate.

 The page's compatibility rules, restated because this side honours them too: an
 existing field never changes meaning or type, new fields are optional, an
 unknown event is dropped, and an unknown method answers 4200. So nothing here
 decodes a method or an event type *as* an enum — they arrive as `String` and are
 matched — or a page one release ahead would fail to parse rather than be
 answered.
 */
public enum BridgeProtocol {
    /// What this wrapper speaks, announced in `HelloResult.protocolVersion`.
    public static let version = 2

    /// Page→host: the page calls `window.rhinestoneBridge.postMessage(json)`.
    public static let pageToHostChannel = "rhinestoneBridge"
    /// Host→page: the host calls `window.__rhinestone_bridge(json)`.
    public static let hostToPageChannel = "__rhinestone_bridge"

    /**
     Largest frame this host will parse, in UTF-16 code units.

     Mirrors the page's cap so neither side spends a parse on something the
     other would never send. UTF-16 because that is what the page counts —
     `String.utf16.count` here, never `count`, or an emoji in a wallet's error
     message moves the boundary.
     */
    public static let maxFrameLength = 256 * 1024
}

// MARK: - Method registry

public enum BridgeMethod: String, CaseIterable, Sendable {
    /// Page→host, first frame of the session. Answers `HelloResult`.
    case hello = "hello"
    /// Page→host: a CAIP-27 wallet request.
    case walletRequest = "wallet.request"
    /// Page→host: withdraw's transfer. Gated by `Capability.sendTransaction`.
    case sendTransaction = "host.sendTransaction"
    /// Page→host: claim's signature. Gated by `Capability.signRecovery`.
    case signRecovery = "host.signRecovery"
    /// Page→host: show a payment page outside the web view.
    case openURL = "host.openUrl"
    /**
     Page→host, sent from a SUB-FRAME. The one request this host must never
     answer from anywhere but the main frame.

     The page sends it from a frame that is not the main one to find out whether
     the host acts on sub-frame traffic — if it does, anything holding a frame
     in this web view could drive the wallet the same way, and the page
     withholds it. Nothing implements a handler: `BridgeHost` drops any frame
     without the main-frame nonce, so a sub-frame's copy never reaches the
     dispatcher, and that drop is the answer.
     */
    case probeFrameScope = "bridge.probeFrameScope"
}

public enum HostMethod: String, CaseIterable, Sendable {
    /// Host→page: Android's hardware back and iOS's interactive swipe. Answers
    /// `UiBackResult`, and the host must await it before acting.
    case back = "ui.back"
}

/// A capability IS the method it gates, so the two cannot drift apart.
public enum Capability: String, CaseIterable, Sendable {
    case sendTransaction = "host.sendTransaction"
    case signRecovery = "host.signRecovery"
    case openURL = "host.openUrl"
    case probeFrameScope = "bridge.probeFrameScope"
}

public enum PageEvent: String, CaseIterable, Sendable {
    case ready = "ready"
    case lifecycle = "lifecycle"
    case analytics = "analytics"
    case error = "error"
    case uiState = "ui.state"
    case walletConnectRequested = "wallet.connectRequested"
    case walletDisconnectRequested = "wallet.disconnectRequested"
    case dismissRequested = "dismissRequested"
}

public enum HostEvent: String, CaseIterable, Sendable {
    case sessionConfigure = "session.configure"
    case walletState = "wallet.state"
}

// MARK: - Envelope

public struct BridgeError: Codable, Equatable, Error, Sendable {
    public var code: Int
    /// Rendered to the user, and wallet-controlled — a chain-switch refusal
    /// shows this text verbatim. Cap and escape it wherever it is interpolated.
    public var message: String
    /// Present only on a bridge-specific code; absent means an EIP-1193 or
    /// JSON-RPC code passed through untranslated.
    public var domain: String?
    /**
     A short, already-redacted diagnostic. Never rendered.

     **Never log a whole frame.** The obvious way to debug a new wrapper writes
     the handshake to the device log, and the handshake carries the backend URL.
     Log this field and the method, nothing else.
     */
    public var data: String?

    public init(code: Int, message: String, domain: String? = nil, data: String? = nil) {
        self.code = code
        self.message = message
        self.domain = domain
        self.data = data
    }
}

public enum BridgeErrorDomain {
    public static let bridge = "bridge"
}

/**
 EIP-1193 codes pass through unchanged: 4001 user rejected, 4100 unauthorized,
 4200 unsupported method, 4900 disconnected, 4902 unrecognized chain. So do
 JSON-RPC's -32602 and -32603.

 **Never answer a send with -32603.** viem retries that code three times on its
 own, and a retried `eth_sendTransaction` is a second broadcast of the same
 transfer. A send the host could not complete is 4001 if the user refused it,
 and `.submissionUncertain` if it cannot tell.
 */
public enum BridgeErrorCode: Int, CaseIterable, Sendable {
    /// A wallet exists but cannot be reached — app not installed, session
    /// dropped mid-request. Distinct from 4900, which means not connected.
    case walletUnavailable = 1
    /**
     The host cannot say whether the transaction reached the network.

     An app switch can be killed by the OS between wallet submission and the
     return trip. Without a code for it the host must lie in one direction or
     the other, and the safe-looking lie — reporting failure — is the one that
     double-spends.
     */
    case submissionUncertain = 2
    /// The page's own deadline expired. Raised page-side, never sent by a host.
    case requestTimeout = 3
    /// The channel went away with the request outstanding.
    case channelClosed = 4
    /// The host answered, but not with something the method can return.
    case malformedResult = 5
}

public func bridgeError(
    _ code: BridgeErrorCode,
    _ message: String,
    data: String? = nil
) -> BridgeError {
    BridgeError(
        code: code.rawValue,
        message: message,
        domain: BridgeErrorDomain.bridge,
        data: data
    )
}

/// EIP-1193 4200. The answer to every method this host does not implement.
public func unsupportedMethod(_ method: String) -> BridgeError {
    BridgeError(code: 4200, message: "Unsupported method: \(method)")
}

/**
 One frame.

 Decoding is deliberately lenient about everything except `kind`: a frame whose
 `method` or `type` this build does not know still decodes, and is answered or
 dropped by the rules above rather than failing to parse.
 */
public enum Envelope: Sendable {
    case event(type: String, payload: JSONValue?)
    case request(id: String, method: String, params: JSONValue?)
    case response(id: String, outcome: Result<JSONValue, BridgeError>)
}

extension Envelope: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind, type, payload, id, method, params, ok, result, error
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        switch kind {
        case "event":
            self = .event(
                type: try container.decode(String.self, forKey: .type),
                payload: try container.decodeIfPresent(JSONValue.self, forKey: .payload)
            )
        case "request":
            self = .request(
                id: try container.decode(String.self, forKey: .id),
                method: try container.decode(String.self, forKey: .method),
                params: try container.decodeIfPresent(JSONValue.self, forKey: .params)
            )
        case "response":
            let id = try container.decode(String.self, forKey: .id)
            let ok = try container.decodeIfPresent(Bool.self, forKey: .ok) ?? false
            if ok {
                let result =
                    try container.decodeIfPresent(JSONValue.self, forKey: .result) ?? .null
                self = .response(id: id, outcome: .success(result))
            } else {
                let error =
                    try container.decodeIfPresent(BridgeError.self, forKey: .error)
                    ?? BridgeError(code: -32603, message: "The page reported a failure.")
                self = .response(id: id, outcome: .failure(error))
            }
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .kind,
                in: container,
                debugDescription: "Unknown envelope kind: \(kind)"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .event(let type, let payload):
            try container.encode("event", forKey: .kind)
            try container.encode(type, forKey: .type)
            try container.encodeIfPresent(payload, forKey: .payload)
        case .request(let id, let method, let params):
            try container.encode("request", forKey: .kind)
            try container.encode(id, forKey: .id)
            try container.encode(method, forKey: .method)
            try container.encodeIfPresent(params, forKey: .params)
        case .response(let id, let outcome):
            try container.encode("response", forKey: .kind)
            try container.encode(id, forKey: .id)
            switch outcome {
            case .success(let result):
                try container.encode(true, forKey: .ok)
                try container.encode(result, forKey: .result)
            case .failure(let error):
                try container.encode(false, forKey: .ok)
                try container.encode(error, forKey: .error)
            }
        }
    }
}

// MARK: - Handshake

public struct HelloParams: Codable, Equatable, Sendable {
    public var protocolVersion: Int
    /// The page's own version. Reused verbatim as the version header on any
    /// request this wrapper makes on the session's behalf, so the two are
    /// attributed as one thing at the processor.
    public var modalVersion: String

    private enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol"
        case modalVersion
    }
}

public struct HostIdentity: Codable, Equatable, Sendable {
    public enum Platform: String, Codable, Sendable {
        case ios, android, other
    }

    public var platform: Platform
    public var app: String?
    public var version: String?

    public init(platform: Platform = .ios, app: String? = nil, version: String? = nil) {
        self.platform = platform
        self.app = app
        self.version = version
    }
}

public struct HelloResult: Codable, Equatable, Sendable {
    public var protocolVersion: Int
    public var host: HostIdentity
    /// The optional vocabulary this host implements. Unlisted means the page
    /// must not send it; a host that receives one anyway answers 4200.
    public var capabilities: [String]
    public var config: EmbedConfig
    /// Initial snapshot, so wallet state is not a separate race after hello.
    public var wallet: WalletState

    private enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol"
        case host, capabilities, config, wallet
    }
}

// MARK: - Config

public enum EmbedMode: String, Codable, CaseIterable, Sendable {
    case deposit, withdraw, claim
}

/**
 EVM chain id, or a CAIP-2 string for a non-EVM target.

 Loosely typed on purpose: the page hashes this value into the account salt, so
 its *spelling* is a deposit address. An enum of the chains we happen to know
 today would either reject one the backend has since added or need a wrapper
 release for each.
 */
public enum TargetChain: Codable, Equatable, Sendable {
    case evm(Int)
    case caip2(String)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let id = try? container.decode(Int.self) {
            self = .evm(id)
        } else {
            self = .caip2(try container.decode(String.self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .evm(let id): try container.encode(id)
        case .caip2(let value): try container.encode(value)
        }
    }
}

public struct OutputTokenRule: Codable, Equatable, Sendable {
    public struct Match: Codable, Equatable, Sendable {
        public var chain: String?
        public var token: String?
        public var symbol: String?

        public init(chain: String? = nil, token: String? = nil, symbol: String? = nil) {
            self.chain = chain
            self.token = token
            self.symbol = symbol
        }
    }

    public var match: Match
    public var outputToken: String

    public init(match: Match, outputToken: String) {
        self.match = match
        self.outputToken = outputToken
    }
}

/// Which Swapped payment groups the fiat on-ramp offers; omit to offer all.
public struct FiatMethodsConfig: Codable, Equatable, Sendable {
    public var creditcard: Bool?
    public var bankTransfer: Bool?
    public var applePay: Bool?

    private enum CodingKeys: String, CodingKey {
        case creditcard
        case bankTransfer = "bank-transfer"
        case applePay = "apple-pay"
    }

    public init(creditcard: Bool? = nil, bankTransfer: Bool? = nil, applePay: Bool? = nil) {
        self.creditcard = creditcard
        self.bankTransfer = bankTransfer
        self.applePay = applePay
    }
}

public struct DepositModalTheme: Codable, Equatable, Sendable {
    /**
     Absent means light, unconditionally — never "follow the OS". `.system`
     asks the page to read `prefers-color-scheme`, which inside a web view is
     not the same question on both platforms: iOS reports the app's effective
     appearance, and Android reports the WebView theme's `isLightTheme`, which
     is light whenever the app never declared one. An app that knows its own
     appearance should send `.light` or `.dark` and re-send on change.
     */
    public enum Mode: String, Codable, Sendable {
        case light, dark, system
    }

    public enum Radius: String, Codable, Sendable {
        case none, sm, md, lg, full
    }

    public var mode: Mode?
    public var radius: Radius?
    public var fontColor: String?
    public var iconColor: String?
    public var ctaColor: String?
    public var ctaHoverColor: String?
    public var borderColor: String?
    public var backgroundColor: String?

    public init(
        mode: Mode? = nil,
        radius: Radius? = nil,
        fontColor: String? = nil,
        iconColor: String? = nil,
        ctaColor: String? = nil,
        ctaHoverColor: String? = nil,
        borderColor: String? = nil,
        backgroundColor: String? = nil
    ) {
        self.mode = mode
        self.radius = radius
        self.fontColor = fontColor
        self.iconColor = iconColor
        self.ctaColor = ctaColor
        self.ctaHoverColor = ctaHoverColor
        self.borderColor = borderColor
        self.backgroundColor = backgroundColor
    }
}

public struct DepositModalUIConfig: Codable, Equatable, Sendable {
    public var showBackButton: Bool?
    public var maxDepositUsd: Double?
    public var minDepositUsd: Double?
    public var feeSponsored: Bool?
    public var feeTooltip: String?

    public init(
        showBackButton: Bool? = nil,
        maxDepositUsd: Double? = nil,
        minDepositUsd: Double? = nil,
        feeSponsored: Bool? = nil,
        feeTooltip: String? = nil
    ) {
        self.showBackButton = showBackButton
        self.maxDepositUsd = maxDepositUsd
        self.minDepositUsd = minDepositUsd
        self.feeSponsored = feeSponsored
        self.feeTooltip = feeTooltip
    }
}

/**
 Every prop that survives a JSON hop. Names match the web modal's React props
 1:1 — this is a transport, not a redesign.

 Config crosses the bridge and never the URL: a public URL taking a recipient
 and a backend URL is a phishing surface, and it would put keyed endpoints into
 URL bars and device logs.
 */
public struct EmbedConfig: Codable, Equatable, Sendable {
    public var mode: EmbedMode

    public var backendUrl: String
    public var recipient: String
    public var targetChain: TargetChain
    /// An ADDRESS on an EVM target, never a symbol: the processor answers
    /// `EVM target requires a valid EVM token address (0x...)` and registration
    /// fails on every chain.
    public var targetToken: String

    public var sourceChain: Int?
    public var sourceToken: String?
    /// USD amount, or the case-insensitive sentinel `"max"`.
    public var defaultAmount: String?
    public var appBalanceUsd: Double?

    public var outputTokenRules: [OutputTokenRule]?
    public var rejectUnmapped: Bool?
    public var forceRegister: Bool?

    public var enableWallet: Bool?
    public var enableFiatOnramp: Bool?
    public var enableQrTransfer: Bool?
    public var enableGaslessDeposit: Bool?
    public var enableExchangeConnect: Bool?
    public var fiatMethods: FiatMethodsConfig?
    public var assetMigrations: [String: JSONValue]?
    public var initialAssetMigration: String?

    /// Not a mount-time value: appearance can change while the sheet is open,
    /// and a host that tracks it re-sends its config.
    public var theme: DepositModalTheme?
    public var uiConfig: DepositModalUIConfig?
    public var debug: Bool?

    /// Withdraw only.
    public var accountAddress: String?

    /// Claim only: prefills the lookup form.
    public var defaultTxHash: String?
    /// Claim only: seeds the refund destination, which the user can still edit.
    public var defaultDestination: String?

    public init(
        mode: EmbedMode,
        backendUrl: String,
        recipient: String,
        targetChain: TargetChain,
        targetToken: String,
        sourceChain: Int? = nil,
        sourceToken: String? = nil,
        defaultAmount: String? = nil,
        appBalanceUsd: Double? = nil,
        outputTokenRules: [OutputTokenRule]? = nil,
        rejectUnmapped: Bool? = nil,
        forceRegister: Bool? = nil,
        enableWallet: Bool? = nil,
        enableFiatOnramp: Bool? = nil,
        enableQrTransfer: Bool? = nil,
        enableGaslessDeposit: Bool? = nil,
        enableExchangeConnect: Bool? = nil,
        fiatMethods: FiatMethodsConfig? = nil,
        assetMigrations: [String: JSONValue]? = nil,
        initialAssetMigration: String? = nil,
        theme: DepositModalTheme? = nil,
        uiConfig: DepositModalUIConfig? = nil,
        debug: Bool? = nil,
        accountAddress: String? = nil,
        defaultTxHash: String? = nil,
        defaultDestination: String? = nil
    ) {
        self.mode = mode
        self.backendUrl = backendUrl
        self.recipient = recipient
        self.targetChain = targetChain
        self.targetToken = targetToken
        self.sourceChain = sourceChain
        self.sourceToken = sourceToken
        self.defaultAmount = defaultAmount
        self.appBalanceUsd = appBalanceUsd
        self.outputTokenRules = outputTokenRules
        self.rejectUnmapped = rejectUnmapped
        self.forceRegister = forceRegister
        self.enableWallet = enableWallet
        self.enableFiatOnramp = enableFiatOnramp
        self.enableQrTransfer = enableQrTransfer
        self.enableGaslessDeposit = enableGaslessDeposit
        self.enableExchangeConnect = enableExchangeConnect
        self.fiatMethods = fiatMethods
        self.assetMigrations = assetMigrations
        self.initialAssetMigration = initialAssetMigration
        self.theme = theme
        self.uiConfig = uiConfig
        self.debug = debug
        self.accountAddress = accountAddress
        self.defaultTxHash = defaultTxHash
        self.defaultDestination = defaultDestination
    }
}

// MARK: - Wallet channel

public struct WalletAccount: Codable, Equatable, Sendable {
    public var caip10: String

    public init(caip10: String) { self.caip10 = caip10 }
}

public struct WalletState: Codable, Equatable, Sendable {
    /// `false` makes the page show "connecting" rather than a connect prompt.
    public var isReady: Bool
    public var isConnected: Bool
    public var accounts: [WalletAccount]
    /**
     The wallet's selected EVM chain, CAIP-2. `nil` means no wallet, or not
     connected yet — a *connected* host must report one, or the page shows no
     wallet row rather than a degraded one.
     */
    public var chainId: String?
    public var icon: String?
    public var name: String?

    public init(
        isReady: Bool,
        isConnected: Bool,
        accounts: [WalletAccount],
        chainId: String?,
        icon: String? = nil,
        name: String? = nil
    ) {
        self.isReady = isReady
        self.isConnected = isConnected
        self.accounts = accounts
        self.chainId = chainId
        self.icon = icon
        self.name = name
    }

    /// What a host with no wallet reports: the page offers QR and manual
    /// transfer and no wallet row, rather than a row that fails when tapped.
    public static let none = WalletState(
        isReady: true,
        isConnected: false,
        accounts: [],
        chainId: nil
    )

    /**
     `chainId` is written even when it is `nil`, because the contract declares
     it `string | null` — required and nullable — where `icon` and `name` are
     genuinely optional.

     Swift's encoder omits a `nil` optional, so the default synthesis would drop
     the key entirely and a disconnected wallet would reach the page as
     `undefined` rather than `null`. The two are interchangeable to most of the
     page's reads today, which is exactly why this would rot unnoticed until one
     of them was not.
     */
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(isReady, forKey: .isReady)
        try container.encode(isConnected, forKey: .isConnected)
        try container.encode(accounts, forKey: .accounts)
        try container.encode(chainId, forKey: .chainId)
        try container.encodeIfPresent(icon, forKey: .icon)
        try container.encodeIfPresent(name, forKey: .name)
    }

    private enum CodingKeys: String, CodingKey {
        case isReady, isConnected, accounts, chainId, icon, name
    }
}

/// CAIP-27 shaped, so native wallet SDKs forward rather than translate.
public struct Caip27Params: Codable, Equatable, Sendable {
    public struct Request: Codable, Equatable, Sendable {
        public var method: String
        public var params: JSONValue?

        public init(method: String, params: JSONValue? = nil) {
            self.method = method
            self.params = params
        }
    }

    /// Authoritative for this request — the chain the host must execute it on,
    /// not a report of where the wallet currently is.
    public var chainId: String
    public var request: Request

    public init(chainId: String, request: Request) {
        self.chainId = chainId
        self.request = request
    }
}

/**
 The complete set of methods the page will ever send.

 Enforced here as well as page-side, and that is not redundancy: this list is
 the signing surface the wrapper exposes to whatever reaches the channel, and a
 host that forwards blindly is publishing `eth_sign` to it.

 `eth_chainId`, `eth_accounts` and `wallet_sendTransaction` are on it because
 viem calls them itself while sending a transaction. Omitting one refuses the
 page's own deposit, and the refusal surfaces as "An unknown RPC error occurred"
 with the wallet's real message destroyed.
 */
public enum AllowedWalletMethod: String, CaseIterable, Sendable {
    case ethChainId = "eth_chainId"
    case ethAccounts = "eth_accounts"
    case ethSendTransaction = "eth_sendTransaction"
    case walletSendTransaction = "wallet_sendTransaction"
    case ethSignTypedDataV4 = "eth_signTypedData_v4"
    case walletSwitchEthereumChain = "wallet_switchEthereumChain"

    /// Methods whose failure may already have moved funds.
    public var isSubmitting: Bool {
        self == .ethSendTransaction || self == .walletSendTransaction
    }
}

// MARK: - Dismissal lock

public enum BlockedReason: String, CaseIterable, Codable, Sendable {
    /// A wallet request is outstanding. The app is switched away, and a
    /// dismissal here destroys the page waiting for the answer.
    case walletRequestPending = "wallet-request-pending"
    /// Signed or broadcast, hash not yet handed to the backend.
    case submissionInFlight = "submission-in-flight"
    /// The deposit is in flight and the page is tracking it.
    case settlementInProgress = "settlement-in-progress"
}

/**
 Refuse dismissal outright while `blocked`. At those moments the answer is not
 the user's to give: closing resets the flow, the page has no storage of its
 own, and a third-party payment session handle cannot be reconstructed.

 A lock is never open-ended — every request the page blocks on carries a
 deadline it enforces itself, so a host that drops a request cannot produce a
 sheet the user cannot close.
 */
public enum DismissalPolicy: Equatable, Sendable {
    case allowed
    case blocked(reason: BlockedReason, message: String)

    public var isBlocked: Bool {
        if case .blocked = self { return true }
        return false
    }
}

extension DismissalPolicy: Codable {
    private enum CodingKeys: String, CodingKey {
        case state, reason, message
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let state = try container.decode(String.self, forKey: .state)
        switch state {
        case "allowed":
            self = .allowed
        case "blocked":
            // A reason this build does not know still locks the sheet. The
            // lock is the load-bearing half; the reason is copy.
            let reason =
                (try? container.decode(BlockedReason.self, forKey: .reason))
                ?? .settlementInProgress
            let message = try container.decodeIfPresent(String.self, forKey: .message) ?? ""
            self = .blocked(reason: reason, message: message)
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .state,
                in: container,
                debugDescription: "Unknown dismissal state: \(state)"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .allowed:
            try container.encode("allowed", forKey: .state)
        case .blocked(let reason, let message):
            try container.encode("blocked", forKey: .state)
            try container.encode(reason, forKey: .reason)
            try container.encode(message, forKey: .message)
        }
    }
}

/**
 Full snapshot, emitted whenever any field changes rather than only on
 navigation, so a dropped frame self-heals on the next one. The lock is derived
 state, never a command.
 */
public struct UiStatePayload: Codable, Equatable, Sendable {
    /// Stable screen id. Usable for a sheet title or telemetry; never branch
    /// payment logic on it.
    public var screen: String
    public var dismissal: DismissalPolicy
    /**
     Points the flow currently needs, for a host sizing a sheet to its content.

     **Absent means "nothing measured yet", never zero.** A host must have an
     answer for its absence — the presentation it would have used before this
     field existed — rather than treating the first frame carrying it as the
     start of the flow. It is not a maximum and not a request: the page keeps
     filling whatever viewport it is given.
     */
    public var contentHeight: Double?

    public init(screen: String, dismissal: DismissalPolicy, contentHeight: Double? = nil) {
        self.screen = screen
        self.dismissal = dismissal
        self.contentHeight = contentHeight
    }
}

public enum DismissSource: String, CaseIterable, Codable, Sendable {
    case closeButton = "close-button"
    case flowComplete = "flow-complete"
    case backPastFirstScreen = "back-past-first-screen"
}

public struct DismissRequestedPayload: Codable, Equatable, Sendable {
    public var source: DismissSource

    public init(source: DismissSource) { self.source = source }
}

public struct UiBackResult: Codable, Equatable, Sendable {
    /**
     `true` — do nothing. Either the page went back a step, or it refused the
     gesture because the last dismissal policy was `blocked`.

     `false` — the page had nowhere to go; the host may dismiss, subject to the
     last dismissal policy.
     */
    public var handled: Bool

    public init(handled: Bool) { self.handled = handled }
}

// MARK: - Withdraw and claim

public struct SendTransactionParams: Codable, Equatable, Sendable {
    public var chainId: Int
    /**
     ERC-20 address, or the zero address for the chain's native asset. Spelled
     out because it is not the EIP-7528 `0xeee…eee` a host would reasonably
     guess, and a host that guesses transfers a nonexistent token rather than
     failing.
     */
    public var token: String
    /// Base units as a decimal string. No 256-bit integer crosses the wire.
    public var amount: String
    /// Authoritative destination. Never substitute your own.
    public var to: String
    /// The account the funds must leave.
    public var from: String
}

public enum NativeToken {
    public static let address = "0x0000000000000000000000000000000000000000"
}

public struct SendTransactionResult: Codable, Equatable, Sendable {
    /// On-chain transaction hash, not a user-operation hash or bundler id —
    /// progress is tracked by looking the deposit up by this value.
    public var txHash: String

    public init(txHash: String) { self.txHash = txHash }
}

/**
 The struct `host.signRecovery` authorizes, compiled in rather than taken over
 the wire.

 **This is the whole security boundary of that method.** A free-form `typedData`
 on the wire would make it mean "sign anything" — a Permit2 transfer, an
 ERC-2612 permit — to a host that opted into believing it narrow. Nothing on
 this side could tell the difference. Signing these fields bounds a page
 compromise to "refund my own failed deposit to the wrong address".

 The domain carries no `chainId` and no `verifyingContract`, so a signature is
 replayable across chains and environments for the same `depositId`. That is a
 property of the struct the page already signs, not one the bridge introduces.

 The encode strings are published because the field array is hashed in declared
 order: a host that synthesizes its own derives a different separator and
 produces a valid-looking wrong signature, one that fails at the processor
 rather than at signing time.
 */
public enum SignRecovery {
    public static let domainName = "Rhinestone Deposit Recovery"
    public static let domainVersion = "1"
    public static let primaryType = "RecoverDeposit"
    public static let encodeType = "RecoverDeposit(uint256 depositId,address destination)"
    public static let domainEncodeType = "EIP712Domain(string name,string version)"
}

public struct SignRecoveryParams: Codable, Equatable, Sendable {
    /**
     The chain the deposit is on, and therefore the chain the signature is
     verified against. **Not part of the signed domain** — folding it in derives
     a different separator and produces exactly the valid-looking wrong
     signature the field exists to prevent.
     */
    public var chainId: Int
    /// The address whose verifier must accept the result: the deposit's
    /// recipient, not necessarily the connected wallet.
    public var signer: String
    /// A DECIMAL STRING. A uint256 that routinely exceeds what a `Double` can
    /// hold exactly, so it never becomes a number on the way through.
    public var depositId: String
    public var destination: String
}

public struct SignRecoveryResult: Codable, Equatable, Sendable {
    /// `0x`-prefixed hex. May be an EOA signature, an ERC-1271 one, or an
    /// ERC-6492 wrap for an undeployed account — all three are hex to the page.
    public var signature: String

    public init(signature: String) { self.signature = signature }
}

/**
 Show a page outside the web view.

 **A browser container, never the web view itself and never another app.**
 `SFSafariViewController` presents over the host, so the user returns with one
 tap and lands where a redirect would.

 **Refuse anything but `https:`.** The page only sends a URL from its own
 provider allow-list, but a host that forwards this to an OS-level open without
 checking has published an app-launch primitive to whatever reaches the channel.

 **Answer when the browser is presented, not when it is dismissed.** A
 dismissal-tied answer has to survive the host being killed behind the browser,
 and a lost answer leaves the page waiting on a payment it can already see the
 result of.
 */
public struct OpenURLParams: Codable, Equatable, Sendable {
    public var url: String

    public init(url: String) { self.url = url }
}
