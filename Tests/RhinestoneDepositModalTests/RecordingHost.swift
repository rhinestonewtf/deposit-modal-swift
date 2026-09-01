import Foundation
import XCTest

@testable import RhinestoneDepositModal

/**
 A `BridgeHost` with every handler supplied, and a record of what crossed it.

 Every handler answers rather than refusing, so a 4200 in a replay means this
 wrapper does not implement something the page sends — never that the fixture
 declined to. What each handler saw is kept, because the replay proves the host
 *answers* and cannot prove the answer was computed from the right fields.
 */
@MainActor
final class RecordingHost {
    static let nonce = "conformance-nonce"

    static let config = EmbedConfig(
        mode: .deposit,
        backendUrl: "https://proxy.example.com",
        recipient: "0x1111111111111111111111111111111111111111",
        targetChain: .evm(8453),
        targetToken: "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913"
    )

    static let wallet = WalletState(
        isReady: true,
        isConnected: true,
        accounts: [WalletAccount(caip10: "eip155:8453:0x1111111111111111111111111111111111111111")],
        chainId: "eip155:8453",
        icon: "https://example.com/icon.png",
        name: "Mock Wallet"
    )

    private(set) var sent: [Envelope] = []
    private(set) var events: [(type: String, payload: JSONValue?)] = []

    private(set) var walletRequests: [Caip27Params] = []
    private(set) var sendTransactionParams: SendTransactionParams?
    private(set) var signRecoveryParams: SignRecoveryParams?
    private(set) var openedURL: String?
    private(set) var helloParams: HelloParams?

    private(set) var host: BridgeHost!
    private var requestCounter = 0

    init(backTimeoutMilliseconds: Int = BridgeHostDefaults.backTimeoutMilliseconds) {
        var handlers = BridgeHost.Handlers()
        handlers.walletRequest = { [weak self] params in
            self?.walletRequests.append(params)
            // Shaped per method, because the page's own decoder refuses a
            // string where an account list belongs — one union across all six
            // would replay green and strand a transfer.
            switch AllowedWalletMethod(rawValue: params.request.method) {
            case .ethAccounts:
                return .array([.string("0x1111111111111111111111111111111111111111")])
            case .ethChainId:
                return .string("0x2105")
            case .ethSendTransaction, .walletSendTransaction:
                return .string("0x\(String(repeating: "7a", count: 32))")
            case .ethSignTypedDataV4:
                return .string("0x\(String(repeating: "5c", count: 65))")
            case .walletSwitchEthereumChain:
                return .null
            case .none:
                return .null
            }
        }
        handlers.sendTransaction = { [weak self] params in
            self?.sendTransactionParams = params
            return SendTransactionResult(txHash: "0x\(String(repeating: "7a", count: 32))")
        }
        handlers.signRecovery = { [weak self] params in
            self?.signRecoveryParams = params
            return SignRecoveryResult(signature: "0x\(String(repeating: "5c", count: 65))")
        }
        handlers.openURL = { [weak self] params in
            self?.openedURL = params.url
        }

        host = BridgeHost(
            post: { [weak self] script in self?.capture(script) },
            nonce: Self.nonce,
            identity: HostIdentity(platform: .ios, app: "ConformanceHost", version: "1.0.0"),
            config: { Self.config },
            wallet: { Self.wallet },
            handlers: { handlers },
            onEvent: { [weak self] type, payload in
                self?.events.append((type: type, payload: payload))
            },
            onHello: { [weak self] params in self?.helloParams = params },
            backTimeoutMilliseconds: backTimeoutMilliseconds
        )
    }

    /// Feed a page→host request and wait for the frame that answers it.
    @discardableResult
    func request(method: String, params: JSONValue?, id: String? = nil) async throws -> Envelope? {
        requestCounter += 1
        let requestId = id ?? "conformance.\(requestCounter)"
        deliver(.request(id: requestId, method: method, params: params))

        // The dispatcher is a `Task`, so the answer lands on a later turn of
        // the main actor rather than inside `receive`.
        for _ in 0..<200 {
            if let answer = sent.first(where: { frame in
                if case .response(let responseId, _) = frame { return responseId == requestId }
                return false
            }) {
                return answer
            }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        return nil
    }

    /// Feed any envelope, as the page would send it.
    func deliver(_ envelope: Envelope) {
        guard let data = try? JSONEncoder().encode(envelope),
            let json = String(data: data, encoding: .utf8)
        else { return XCTFail("Could not encode a frame to deliver.") }
        host.receive("\(Self.nonce)\(Injection.nonceSeparator)\(json)")
    }

    /// Feed a raw string, for the frames that are not well formed.
    func deliverRaw(_ raw: Any?) {
        host.receive(raw)
    }

    private func capture(_ script: String) {
        guard let envelope = Self.decodeFrame(fromScript: script) else {
            return XCTFail("The host posted something that is not an encoded frame.")
        }
        sent.append(envelope)
    }

    /// The inverse of `Injection.encodeFrameForEvaluation`.
    static func decodeFrame(fromScript script: String) -> Envelope? {
        let prefix =
            "window.\(BridgeProtocol.hostToPageChannel) && window.\(BridgeProtocol.hostToPageChannel)("
        let suffix = "); true;"
        guard script.hasPrefix(prefix), script.hasSuffix(suffix) else { return nil }
        let literal = String(script.dropFirst(prefix.count).dropLast(suffix.count))
        guard let literalData = literal.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(
                with: literalData,
                options: [.fragmentsAllowed]
            ) as? String,
            let frameData = json.data(using: .utf8)
        else { return nil }
        return try? JSONDecoder().decode(Envelope.self, from: frameData)
    }
}
