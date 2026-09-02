import RhinestoneDepositModal
import SwiftUI

/**
 The smallest app that presents the deposit sheet.

 It points at the DEV page, because that is where a contract change lands first
 and an example built against prod would be testing a release behind.

 Configuration comes from the environment so the corridor can be changed without
 editing this file; `Demo` in `DemoWallet.swift` reads all of it:

     RHINESTONE_BACKEND_URL       the proxy this app talks to
     RHINESTONE_RECIPIENT         the account the deposit lands in, defaulting
                                  to the demo wallet's own address
     RHINESTONE_TARGET_CHAIN      EVM chain id, default 8453 (Base)
     RHINESTONE_TARGET_TOKEN      an ADDRESS, never a symbol — the processor
                                  rejects `USDC` on an EVM target and
                                  registration fails on every chain
     RHINESTONE_DEMO_PRIVATE_KEY  a throwaway key. Without it there is no
                                  wallet, and the page offers QR and manual
                                  transfer only
     RHINESTONE_CHAIN             where that key holds funds, default 8453
     RHINESTONE_RPC_URL           overrides the public endpoint for that chain
 */
@main
struct ExampleApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}

struct ContentView: View {
    /// `RHINESTONE_AUTO_OPEN=1` presents the sheet on launch, so a simulator
    /// run needs no tap driver to reach the page.
    @State private var funding =
        ProcessInfo.processInfo.environment["RHINESTONE_AUTO_OPEN"] == "1"
    @State private var log: [String] = []
    @StateObject private var wallet = DemoWallet()

    /**
     The demo wallet's address unless one is given explicitly, which is what
     makes a wallet-only run need no second variable.

     Never a placeholder: registration fails for an address nobody holds, and
     the modal reports that 400 as the deposit service being unavailable — so a
     made-up recipient reads as a backend outage rather than as a misconfigured
     example.
     */
    private var recipient: String? { Demo.recipient ?? wallet.address }

    private func config(for recipient: String) -> EmbedConfig {
        EmbedConfig(
            mode: .deposit,
            backendUrl: Demo.backendURL,
            recipient: recipient,
            targetChain: .evm(Demo.targetChain),
            targetToken: Demo.targetToken
        )
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Account") {
                    LabeledContent("Recipient", value: short(recipient ?? ""))
                    LabeledContent("Chain", value: String(Demo.targetChain))
                    LabeledContent(
                        "Wallet",
                        value: wallet.address.map(short) ?? "none — QR only"
                    )
                }
                Section {
                    Button("Add funds") { funding = true }
                        .disabled(recipient == nil)
                    if recipient == nil {
                        Text(
                            "Set RHINESTONE_DEMO_PRIVATE_KEY or RHINESTONE_RECIPIENT "
                                + "in the scheme's environment."
                        )
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    }
                }
                if !log.isEmpty {
                    Section("From the sheet") {
                        ForEach(log.indices, id: \.self) { index in
                            Text(log[index]).font(.system(.footnote, design: .monospaced))
                        }
                    }
                }
            }
            .navigationTitle("Deposit example")
        }
        .depositSheet(
            isPresented: $funding,
            config: config(for: recipient ?? ""),
            wallet: wallet.bridge,
            callbacks: DepositSheetCallbacks(
                onReady: { note("ready") },
                onLifecycle: { event in
                    note("lifecycle \(event?["type"]?.stringValue ?? "?")")
                },
                onError: { event in note("error \(event?["code"]?.stringValue ?? "?")") },
                onDepositSettled: { deposit in note("settled \(deposit.status)") },
                onFatal: { error in note("fatal \(error.localizedDescription)") }
            ),
            embedURL: DepositSheetDefaults.embedURLDev,
            app: (name: "DepositModalExample", version: "0.1.0")
        )
    }

    private func note(_ line: String) {
        log.append(line)
    }

    private func short(_ address: String) -> String {
        guard address.count > 12 else { return address.isEmpty ? "unset" : address }
        return "\(address.prefix(6))…\(address.suffix(4))"
    }
}
