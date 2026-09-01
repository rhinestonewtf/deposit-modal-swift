import RhinestoneDepositModal
import SwiftUI

/**
 The smallest app that presents the deposit sheet.

 It points at the DEV page, because that is where a contract change lands first
 and an example built against prod would be testing a release behind.

 Configuration comes from the environment so the corridor can be changed without
 editing this file:

     RHINESTONE_BACKEND_URL   the proxy this app talks to
     RHINESTONE_RECIPIENT     the account the deposit lands in
     RHINESTONE_TARGET_CHAIN  EVM chain id, default 8453 (Base)
     RHINESTONE_TARGET_TOKEN  an ADDRESS, never a symbol — the processor
                              rejects `USDC` on an EVM target and registration
                              fails on every chain
 */
@main
struct ExampleApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}

private enum Demo {
    static let backendURL =
        env("RHINESTONE_BACKEND_URL") ?? "https://your-proxy.example/deposit"
    static let recipient = env("RHINESTONE_RECIPIENT") ?? ""
    static let targetChain = Int(env("RHINESTONE_TARGET_CHAIN") ?? "") ?? 8453
    static let targetToken =
        env("RHINESTONE_TARGET_TOKEN") ?? "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913"

    private static func env(_ key: String) -> String? {
        guard let value = ProcessInfo.processInfo.environment[key], !value.isEmpty else {
            return nil
        }
        return value
    }
}

struct ContentView: View {
    /// `RHINESTONE_AUTO_OPEN=1` presents the sheet on launch, so a simulator
    /// run needs no tap driver to reach the page.
    @State private var funding =
        ProcessInfo.processInfo.environment["RHINESTONE_AUTO_OPEN"] == "1"
    @State private var log: [String] = []
    @StateObject private var wallet = DemoWallet()

    private var config: EmbedConfig {
        EmbedConfig(
            mode: .deposit,
            backendUrl: Demo.backendURL,
            recipient: Demo.recipient,
            targetChain: .evm(Demo.targetChain),
            targetToken: Demo.targetToken
        )
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Account") {
                    LabeledContent("Recipient", value: short(Demo.recipient))
                    LabeledContent("Chain", value: String(Demo.targetChain))
                }
                Section {
                    Button("Add funds") { funding = true }
                        .disabled(Demo.recipient.isEmpty)
                    if Demo.recipient.isEmpty {
                        Text("Set RHINESTONE_RECIPIENT in the scheme's environment.")
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
            config: config,
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
