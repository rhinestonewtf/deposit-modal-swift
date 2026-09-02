# RhinestoneDepositModal

The Rhinestone deposit flow in a Swift app: a native sheet holding our hosted
page, with your app's wallet driving every signature.

```swift
.package(url: "https://github.com/rhinestonewtf/deposit-modal-swift.git", from: "0.1.0")
```

```swift
import RhinestoneDepositModal
import SwiftUI

struct AccountView: View {
    @State private var funding = false

    var body: some View {
        Button("Add funds") { funding = true }
            .depositSheet(
                isPresented: $funding,
                config: EmbedConfig(
                    mode: .deposit,
                    backendUrl: "https://your-proxy.example/deposit",
                    recipient: account,
                    targetChain: .evm(8453),
                    // An address, never a symbol — an EVM target rejects "USDC".
                    targetToken: "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913"
                ),
                wallet: WalletBridge(
                    state: walletState,
                    request: { params in try await yourWallet.request(params) },
                    onConnectRequested: { yourWalletPicker.open() }
                )
            )
    }
}
```

A UIKit app presents `DepositSheetController` directly; the SwiftUI modifier is
a thin presenter over it.

## Before your first build

**Your proxy must allow `https://deposit.rhinestone.dev`.** Every backend call
from a mobile integration originates from our hosted page, not from your app's
domain, so a proxy with an explicit CORS allow-list rejects all of them at
preflight — the whole sheet dead, with nothing naming the cause. A proxy using a
permissive default is unaffected. Dev builds use
`DepositSheetDefaults.embedURLDev`.

## What the host provides

| | |
|---|---|
| `wallet` | CAIP-27 requests. Omit it and the page offers QR and manual transfer only, with no wallet row — never a row that fails when tapped. |
| `sendTransaction` | Withdraw's transfer. Supplying it announces the capability; without it the page does not offer withdraw. |
| `signRecovery` | Claim's EIP-712 signature. The struct is compiled in, never taken over the wire. |
| `callbacks` | `onReady`, `onLifecycle`, `onAnalytics`, `onError`, `onDepositSettled`, `onFatal`, `onDismiss`. |

The browser hand-off is always available: the card and exchange rows open in
`SFSafariViewController` over your app, so the user returns with one tap.

## What it does for you

- **Pins the web view to our origin.** A redirect inside the container would put
  another document on the same web view as the bridge; links the page means to
  open outside — a block explorer, a provider's terms — go to the system
  browser instead of being dead taps.
- **Scopes the channel to the main frame**, twice: the injected script is
  main-frame only, and `WKScriptMessage.frameInfo` is checked natively. A
  third-party frame in the same web view cannot reach your wallet.
- **Refuses a dismissal the flow cannot survive.** While the page reports the
  lock, the sheet sets `isModalInPresentation`, so the interactive swipe cannot
  close it mid-signature; the page is asked first and the lock is checked
  separately.
- **Sizes the sheet to the flow.** The page publishes the height its content
  needs and the sheet follows it (iOS 16+); a page that publishes none is
  presented exactly as before.
- **Keeps watching after the web view dies.** iOS kills a backgrounded web view
  routinely, so a deposit that settles while the user is away still reports
  through `onDepositSettled`.

## Example

`Example/` is a SwiftUI app pointed at the dev page.

```sh
cd Example && xcodegen generate && open DepositModalExample.xcodeproj
```

Set `RHINESTONE_BACKEND_URL` in the scheme's environment, and
`RHINESTONE_DEMO_PRIVATE_KEY` to a throwaway key — the wallet really signs, and
the deposit lands in its own address unless `RHINESTONE_RECIPIENT` says
otherwise. Without a key there is no wallet and the page offers QR and manual
transfer, which is a real configuration rather than a degraded one.

`RHINESTONE_CHAIN` is where the key holds funds and `RHINESTONE_TARGET_CHAIN`
where the deposit lands; they are separate, and pointing only the target at a
testnet leaves the wallet refusing every request as off-chain.

That signing is `web3.swift`, which is the **example's** dependency and not the
package's — the shape a real integration is in, where `request` goes to whatever
wallet SDK the app already has.

## Requirements

iOS 15+, Swift 5.9+. No dependencies.
