import RhinestoneDepositModal
import SwiftUI

/**
 A wallet that reports an account and refuses to sign.

 Enough to exercise the seam this example is for — the page renders its wallet
 row, asks for accounts and the chain, and drives the flow — and deliberately
 not enough to move money: signing an EVM transaction needs secp256k1, which
 this package does not depend on and an example should not smuggle in.

 **A refusal is a real answer, not a stub.** It comes back as EIP-1193 4001, the
 same code a user tapping "reject" in a real wallet produces, so the page takes
 the path it would take in production rather than an error path nothing else
 reaches. Swapping this for a real signer is what proving a Swift deposit end to
 end needs, and it is the only thing missing.
 */
@MainActor
final class DemoWallet: ObservableObject {
    /// A well-known address, so nothing here looks like a key.
    private let address = "0x1111111111111111111111111111111111111111"
    private let chain = "eip155:8453"

    var bridge: WalletBridge {
        WalletBridge(
            state: WalletState(
                isReady: true,
                isConnected: true,
                accounts: [WalletAccount(caip10: "\(chain):\(address)")],
                chainId: chain,
                name: "Demo Wallet"
            ),
            request: { [address] params in
                switch AllowedWalletMethod(rawValue: params.request.method) {
                case .ethAccounts:
                    return .array([.string(address)])
                case .ethChainId:
                    // Hex, per EIP-1193 — the page reads it with a hex parser
                    // and a decimal string reads as chain 0.
                    return .string("0x2105")
                case .ethSendTransaction, .walletSendTransaction, .ethSignTypedDataV4:
                    throw BridgeHost.Failure.userRejected(
                        "This example cannot sign. Wire a real wallet to complete a deposit."
                    )
                case .walletSwitchEthereumChain:
                    // The demo wallet is on one chain, and saying so is better
                    // than pretending to switch: the page waits to be told the
                    // wallet moved, and it never would.
                    throw BridgeHost.Failure.userRejected("This example stays on Base.")
                case .none:
                    throw BridgeHost.Failure.userRejected("Unsupported.")
                }
            },
            onConnectRequested: {
                // A real app opens its own picker here. This one is always
                // connected, so the page should never ask.
            }
        )
    }
}
