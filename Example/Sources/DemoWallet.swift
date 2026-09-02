import BigInt
import Foundation
import RhinestoneDepositModal
import SwiftUI
import web3

/**
 A wallet that really signs, from a throwaway key.

 Deliberately whole rather than minimal, for the same reason the React Native
 example is: proving the contract needs a deposit that reaches the chain, and a
 wallet that stubs its answers proves the sheet renders and nothing else.

 `web3.swift` is the EXAMPLE's dependency and never the package's. That is not a
 layering nicety — it is the shape a real integration is in, where `request` is
 handed to the app's own wallet SDK and the wrapper never learns which one.

 With no `RHINESTONE_DEMO_PRIVATE_KEY` there is no wallet at all, and the page
 offers QR and manual transfer. That is a real configuration rather than a
 degraded one — CI builds this app without a key — and it is not the same as a
 wallet that refuses every request, which renders a row that fails when tapped.
 */
@MainActor
final class DemoWallet: ObservableObject {
    private let signer: Signer?

    init() {
        signer = Signer(
            privateKey: Demo.privateKey,
            chainId: Demo.walletChain,
            rpcURL: Demo.rpcURL
        )
    }

    /// The account funds leave from, and this example's default recipient.
    var address: String? { signer?.address }

    var bridge: WalletBridge? {
        guard let signer else { return nil }
        let caip2 = "eip155:\(signer.chainId)"
        return WalletBridge(
            state: WalletState(
                isReady: true,
                isConnected: true,
                accounts: [WalletAccount(caip10: "\(caip2):\(signer.address)")],
                chainId: caip2,
                name: "Demo Key"
            ),
            request: { params in
                // The CAIP-2 chain on the request is authoritative — execute
                // there, rather than wherever this wallet happens to be
                // pointed.
                guard params.chainId == caip2 else {
                    throw BridgeHost.Failure.userRejected(
                        "This demo wallet only holds an \(caip2) account."
                    )
                }
                return try await signer.answer(params.request)
            },
            onConnectRequested: {
                // A real app opens its own picker here. This one is always
                // connected, so the page should never ask.
            }
        )
    }
}

/// Everything the demo reads from the scheme's environment, in one place.
enum Demo {
    static let backendURL =
        env("RHINESTONE_BACKEND_URL") ?? "https://your-proxy.example/deposit"
    static let recipient = env("RHINESTONE_RECIPIENT")
    static let targetChain = Int(env("RHINESTONE_TARGET_CHAIN") ?? "") ?? 8453
    static let targetToken =
        env("RHINESTONE_TARGET_TOKEN") ?? "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913"

    /// A demo key, and only ever that. A real integration never sees one.
    static let privateKey = env("RHINESTONE_DEMO_PRIVATE_KEY")

    /**
     Where the wallet holds funds, which is not where the deposit lands. The
     chain belongs to the wallet as much as to the deposit — pointing only the
     target at a testnet leaves the wallet refusing every request as off-chain.
     */
    static let walletChain = Int(env("RHINESTONE_CHAIN") ?? "") ?? 8453

    static let rpcURL = env("RHINESTONE_RPC_URL") ?? publicRPC[walletChain]

    /// Enough to drive the corridors this example is pointed at. Override with
    /// `RHINESTONE_RPC_URL` for anything else, or for a key'd endpoint.
    private static let publicRPC: [Int: String] = [
        8453: "https://mainnet.base.org",
        42161: "https://arb1.arbitrum.io/rpc",
        84532: "https://sepolia.base.org",
        11_155_420: "https://sepolia.optimism.io",
    ]

    static func env(_ key: String) -> String? {
        guard let value = ProcessInfo.processInfo.environment[key], !value.isEmpty else {
            return nil
        }
        return value
    }
}

/**
 The four EIP-1193 methods the page sends, answered against a real chain.

 `wallet_sendTransaction` is here for the same reason it is on
 `AllowedWalletMethod`: viem calls it itself while sending, and a wallet that
 answers only `eth_sendTransaction` refuses the page's own deposit.
 */
private struct Signer {
    let account: EthereumAccount
    let client: EthereumHttpClient
    let chainId: Int

    var address: String { account.address.toChecksumAddress() }

    init?(privateKey: String?, chainId: Int, rpcURL: String?) {
        guard let privateKey, let rpcURL, let url = URL(string: rpcURL),
            let storage = InMemoryKey(hex: privateKey),
            let account = try? EthereumAccount(keyStorage: storage)
        else { return nil }
        self.account = account
        self.chainId = chainId
        // `.custom` takes the chain id as a string; `intValue` reads it back,
        // and it is what gets folded into the EIP-155 signature.
        client = EthereumHttpClient(url: url, network: .custom(String(chainId)))
    }

    func answer(_ request: Caip27Params.Request) async throws -> JSONValue {
        switch AllowedWalletMethod(rawValue: request.method) {
        case .ethAccounts:
            return .array([.string(address)])
        case .ethChainId:
            // Hex, per EIP-1193 — the page reads it with a hex parser and a
            // decimal string reads as chain 0.
            return .string("0x\(String(chainId, radix: 16))")
        case .ethSendTransaction, .walletSendTransaction:
            let hash = try await send(request.params)
            return .string(hash)
        case .ethSignTypedDataV4:
            let signature = try signTypedData(request.params)
            return .string(signature)
        case .walletSwitchEthereumChain:
            // Already the selected chain, since `request` refused anything
            // else before reaching here.
            return .null
        case .none:
            throw BridgeHost.Failure.userRejected("\(request.method) is not supported here.")
        }
    }

    private func send(_ params: JSONValue?) async throws -> String {
        guard let call = params?.arrayValue?.first,
            let transaction = try? call.decoded(as: TransactionRequest.self)
        else {
            throw BridgeHost.Failure.userRejected("Malformed transaction.")
        }

        let to = EthereumAddress(transaction.to)
        let value = transaction.value.flatMap { BigUInt(hex: $0) } ?? 0
        let data = transaction.data.flatMap { Data(hex: $0) } ?? Data()

        // Fees are the wallet's to choose, which is why the page does not send
        // them. web3.swift signs type-0 transactions only; Base and the other
        // corridors here accept them, and an EIP-1559 wallet would differ only
        // in what it pays.
        //
        // The estimate carries zeroed fees because `eth_estimateGas` sends only
        // from/to/value/data — the ones that matter go on the transaction that
        // is actually signed.
        let probe = EthereumTransaction(
            from: account.address,
            to: to,
            value: value,
            data: data,
            gasPrice: 0,
            gasLimit: 0
        )
        let gasLimit = try await client.eth_estimateGas(probe)
        let gasPrice = try await client.eth_gasPrice()

        let priced = EthereumTransaction(
            from: account.address,
            to: to,
            value: value,
            data: data,
            nonce: nil,
            gasPrice: gasPrice,
            gasLimit: gasLimit,
            chainId: chainId
        )

        do {
            // Nonce and chain id are injected here, and the signing is local —
            // so a throw past this point is a broadcast whose outcome nobody
            // knows, which is exactly what `submissionUncertain` is for. The
            // page has copy for it that does not invite a retry.
            return try await client.eth_sendRawTransaction(priced, withAccount: account)
        } catch {
            throw BridgeHost.Failure.submissionUncertain()
        }
    }

    private func signTypedData(_ params: JSONValue?) throws -> String {
        // `[address, typedData]`, and the typed data is a JSON *string* —
        // stringified page-side, per `eth_signTypedData_v4`.
        guard let payload = params?.arrayValue?.dropFirst().first?.stringValue,
            let encoded = payload.data(using: .utf8),
            let typed = try? JSONDecoder().decode(TypedData.self, from: encoded)
        else {
            throw BridgeHost.Failure.userRejected("Malformed typed data.")
        }
        guard let signature = try? account.signMessage(message: typed) else {
            throw BridgeHost.Failure.userRejected("Could not sign.")
        }
        return signature
    }

    private struct TransactionRequest: Decodable {
        var to: String
        var data: String?
        var value: String?
    }
}

/**
 The key, held in memory for the life of the process and never written down.

 `EthereumAccount` only loads through a key store, and the shipped one persists
 to disk — which for a key passed in on the scheme's environment would leave it
 behind after the run that used it.
 */
private struct InMemoryKey: EthereumSingleKeyStorageProtocol {
    let key: Data

    init?(hex: String) {
        guard let key = Data(hex: hex), key.count == 32 else { return nil }
        self.key = key
    }

    func storePrivateKey(key _: Data) throws {}
    func loadPrivateKey() throws -> Data { key }
}
