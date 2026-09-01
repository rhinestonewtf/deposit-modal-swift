# deposit-modal-swift — Claude Instructions

`RhinestoneDepositModal` — the Swift wrapper around the hosted deposit embed. It
presents a native sheet holding a `WKWebView` pinned to our origin, holds the
host app's wallet, and forwards bridge traffic.

`deposit-modal-react-native` is the **reference wrapper**; this one is written
against the shape it settled on. A difference between the two is a bug in one of
them unless a comment says which platform forced it.

## Where it sits

```
host app
  └── DepositSheetController          ← this package
        └── WKWebView → deposit.rhinestone.dev   (the hosted page)
              └── the integrator's proxy → deposit-processor
```

The page is `@rhinestone/deposit-modal`'s `./embed` entry, built and hosted
separately. This package never talks to a backend itself, except for
`DepositWatch`.

## The contract, and why it is copied

`Sources/RhinestoneDepositModal/Protocol.swift` is a **hand-maintained copy** of
`src/core/bridge/protocol.ts` in `rhinestonewtf/deposit-modal`, which is the
spec. Swift cannot import it, and the React Native and Android wrappers each
re-declare the same thing anyway.

- **`Tests/…/Resources/bridge-transcript.json` is what stops the copies
  drifting.** The page records what crosses the channel and publishes it;
  `ConformanceTests` replays it against the real host. A renamed method, a
  renamed or retyped field, a changed error code or a changed envelope fails
  there.
- **Never hand-edit the vendored transcript.** Refresh it from a served origin,
  never from the `deposit-modal` checkout — `modalVersion` is stamped at page
  build, so the committed copy there carries none:
  `curl -fsS https://dev.deposit.rhinestone.dev/bridge-transcript.json -o Tests/RhinestoneDepositModalTests/Resources/bridge-transcript.json`
- **Re-vendoring alone is the wrong fix for a red conformance run.** It silences
  the check without changing the wrapper. Fix `Protocol.swift` to match first.
- **Every name is a `CaseIterable` enum, never a bare `String`.** The replay can
  only check what it can enumerate. But nothing DECODES a method or event type
  as an enum — they arrive as `String` and are matched — or a page one release
  ahead would fail to parse rather than be answered 4200.
- **The freshness check is names only**, unlike the React Native wrapper's,
  which also diffs frame shapes. A page that retypes a field inside a recorded
  frame passes here until the transcript is re-vendored.

## Gotchas

- **A `static let` on a `@MainActor` type cannot be a default argument.** That
  is why `BridgeHostDefaults`, `DepositWatchDefaults` and `DepositSheetDefaults`
  exist outside their classes; it is an error in the Swift 6 language mode, not
  a style choice.
- **The frame check is native and the nonce is the belt.** `frameInfo.isMainFrame`
  is invisible to JavaScript and cannot be forged, but the nonce is what makes
  the same logic testable without a web view — `BridgeHost` has no WebKit in it
  at all, which is why `swift test` runs the whole contract on a laptop.
- **The SwiftUI presenter must present from the visible controller**, not from
  its own `UIViewControllerRepresentable` host: that one is a zero-size
  background view and is not in a window on the first update, so `present` is a
  silent no-op that reads as the page failing to load.
- **`swift test` does not run the iOS half.** `DepositSheetController`, the
  SwiftUI presenter and their tests are behind `#if os(iOS)`, so a macOS run
  proves nothing about them —
  `xcodebuild test -scheme RhinestoneDepositModal -destination 'platform=iOS Simulator,name=<device>'`
  is what runs everything. Both are in CI, and the counts differ on purpose.
- **`DepositSheetController.postedFrames` and `receiveForTesting` are the seam
  the controller tests drive**, and they are `internal` rather than a hack
  because `WKScriptMessage` has no public initializer — nor do its `frameInfo`
  and `securityOrigin` — so the alternative tests a stub of the message handler
  instead of the controller.
- **A field the page declares `T | null` must be encoded even when nil.** Swift
  omits a nil optional, so the page reads `undefined` where the contract says
  `null` — `WalletState.chainId` writes its own `encode(to:)` for that reason,
  while `icon` and `name` are genuinely optional and are omitted.
- **`-Xswiftc -sdk` does not cross-compile this package**; SwiftPM keeps the
  macOS sysroot for the module step and the build dies in `CoreServices`. Use
  `xcodebuild`.
- **The example refuses to sign, deliberately.** A real signature needs
  secp256k1, which the package does not depend on. It answers EIP-1193 4001 —
  the same code a user rejecting in a real wallet produces — so the page takes
  the production path.
- **Driving the simulator:** `RHINESTONE_AUTO_OPEN=1` presents the sheet on
  launch, so a run needs no tap driver. Pass environment through
  `SIMCTL_CHILD_*`, and screenshot with `xcrun simctl io booted screenshot`.
