#if os(iOS)

    import SwiftUI
    import UIKit

    /**
     The deposit flow as a sheet, for a SwiftUI app.

     A thin presenter over `DepositSheetController`, which is where everything
     actually happens — an app that presents its own UIKit hierarchy should use
     the controller directly rather than reaching through this.

     ```swift
     .depositSheet(isPresented: $funding, config: config, wallet: wallet)
     ```
     */
    extension View {
        public func depositSheet(
            isPresented: Binding<Bool>,
            config: EmbedConfig,
            wallet: WalletBridge? = nil,
            sendTransaction: (
                @MainActor (SendTransactionParams) async throws -> SendTransactionResult
            )? = nil,
            signRecovery: (@MainActor (SignRecoveryParams) async throws -> SignRecoveryResult)? =
                nil,
            callbacks: DepositSheetCallbacks = DepositSheetCallbacks(),
            embedURL: String = DepositSheetDefaults.embedURL,
            app: (name: String?, version: String?)? = nil
        ) -> some View {
            background(
                DepositSheetPresenter(
                    isPresented: isPresented,
                    config: config,
                    wallet: wallet,
                    sendTransaction: sendTransaction,
                    signRecovery: signRecovery,
                    callbacks: callbacks,
                    embedURL: embedURL,
                    app: app
                )
            )
        }
    }

    struct DepositSheetPresenter: UIViewControllerRepresentable {
        @Binding var isPresented: Bool
        let config: EmbedConfig
        let wallet: WalletBridge?
        let sendTransaction:
            (@MainActor (SendTransactionParams) async throws -> SendTransactionResult)?
        let signRecovery: (@MainActor (SignRecoveryParams) async throws -> SignRecoveryResult)?
        let callbacks: DepositSheetCallbacks
        let embedURL: String
        let app: (name: String?, version: String?)?

        func makeCoordinator() -> Coordinator { Coordinator(self) }

        func makeUIViewController(context: Context) -> UIViewController {
            UIViewController()
        }

        func updateUIViewController(_ presenter: UIViewController, context: Context) {
            context.coordinator.parent = self
            context.coordinator.sync(from: presenter, isPresented: isPresented)
        }

        @MainActor
        final class Coordinator {
            var parent: DepositSheetPresenter
            private var sheet: DepositSheetController?

            init(_ parent: DepositSheetPresenter) { self.parent = parent }

            func sync(from presenter: UIViewController, isPresented: Bool) {
                if isPresented, sheet == nil {
                    present(from: presenter)
                } else if !isPresented, let sheet {
                    sheet.dismiss(animated: true)
                    self.sheet = nil
                } else if let sheet {
                    // Config and wallet are not mount-time values: appearance
                    // and the connected account both change while the sheet is
                    // open, and the page repaints in place.
                    sheet.update(config: parent.config)
                    sheet.update(wallet: parent.wallet)
                }
            }

            private func present(from presenter: UIViewController) {
                var callbacks = parent.callbacks
                let hostDismiss = callbacks.onDismiss
                callbacks.onDismiss = { [weak self] in
                    hostDismiss?()
                    self?.parent.isPresented = false
                }

                let controller = DepositSheetController(
                    config: parent.config,
                    wallet: parent.wallet,
                    sendTransaction: parent.sendTransaction,
                    signRecovery: parent.signRecovery,
                    callbacks: callbacks,
                    embedURL: parent.embedURL,
                    app: parent.app
                )
                // Until the page reports a content height, the sheet is
                // presented the way it was before the page published one:
                // large, and draggable to medium.
                if let sheet = controller.sheetPresentationController {
                    sheet.detents = [.large()]
                    sheet.prefersGrabberVisible = true
                }
                controller.presentationController?.delegate = controller
                sheet = controller

                // Presented from whatever is actually on screen, not from the
                // representable's own controller: that one is a zero-size
                // background view, and on the first update it is not in a
                // window yet — `present` on it is a silent no-op, which reads
                // as the page failing to load.
                guard let host = Self.visibleController(from: presenter) else {
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.sheet === controller else { return }
                        Self.visibleController(from: presenter)?
                            .present(controller, animated: true)
                    }
                    return
                }
                host.present(controller, animated: true)
            }

            private static func visibleController(
                from presenter: UIViewController
            ) -> UIViewController? {
                guard var candidate = presenter.view.window?.rootViewController else { return nil }
                while let presented = candidate.presentedViewController {
                    candidate = presented
                }
                return candidate
            }
        }
    }

#endif
