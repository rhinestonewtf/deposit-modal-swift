#if os(iOS)

    import Foundation
    import SafariServices
    import UIKit
    import WebKit

    /// The wallet the page drives. Omit for a deposit flow that offers QR and
    /// manual transfer only — the page renders no wallet row rather than one
    /// that fails when tapped.
    public struct WalletBridge {
        /// The full snapshot. Assign a new one and call
        /// `DepositSheetController.update(wallet:)` to push it.
        public var state: WalletState
        /// CAIP-27. The `chainId` is authoritative — execute on that chain, do
        /// not report where the wallet happens to be.
        public var request: @MainActor (Caip27Params) async throws -> JSONValue
        /// The page's connect row was tapped. Present your own wallet picker.
        public var onConnectRequested: (() -> Void)?
        public var onDisconnectRequested: (() -> Void)?

        public init(
            state: WalletState,
            request: @escaping @MainActor (Caip27Params) async throws -> JSONValue,
            onConnectRequested: (() -> Void)? = nil,
            onDisconnectRequested: (() -> Void)? = nil
        ) {
            self.state = state
            self.request = request
            self.onConnectRequested = onConnectRequested
            self.onDisconnectRequested = onDisconnectRequested
        }
    }

    /// What the sheet reports back. Every one is optional; a deposit completes
    /// without any of them.
    public struct DepositSheetCallbacks {
        public var onReady: (() -> Void)?
        public var onLifecycle: ((JSONValue?) -> Void)?
        public var onAnalytics: ((JSONValue?) -> Void)?
        public var onError: ((JSONValue?) -> Void)?
        /// A deposit reached a terminal status while this controller was alive,
        /// including one that started and finished while the page was dead.
        public var onDepositSettled: ((DepositRow) -> Void)?
        /// The page could not be reached, or never completed its handshake.
        public var onFatal: ((Error) -> Void)?
        /// The sheet asked to close. Dismiss it.
        public var onDismiss: (() -> Void)?

        public init(
            onReady: (() -> Void)? = nil,
            onLifecycle: ((JSONValue?) -> Void)? = nil,
            onAnalytics: ((JSONValue?) -> Void)? = nil,
            onError: ((JSONValue?) -> Void)? = nil,
            onDepositSettled: ((DepositRow) -> Void)? = nil,
            onFatal: ((Error) -> Void)? = nil,
            onDismiss: (() -> Void)? = nil
        ) {
            self.onReady = onReady
            self.onLifecycle = onLifecycle
            self.onAnalytics = onAnalytics
            self.onError = onError
            self.onDepositSettled = onDepositSettled
            self.onFatal = onFatal
            self.onDismiss = onDismiss
        }
    }

    public enum DepositSheetError: LocalizedError {
        case handshakeFailed
        case pageUnreachable(underlying: Error)

        public var errorDescription: String? {
            switch self {
            case .handshakeFailed: return "The deposit page did not complete its handshake."
            case .pageUnreachable: return "The deposit page could not be loaded."
            }
        }
    }

    /**
     The deposit flow in a web view the host app owns.

     Everything that makes this different from a web integration is the seam,
     not the flow: configuration arrives over the bridge instead of as a URL, the
     wallet lives in this app rather than in the document, dismissal belongs to
     the sheet outside, and every lifecycle, analytics and error event leaves as
     a frame. The flow underneath is the same one a web integrator renders.
     */
    /// Outside the controller so a default argument can reach them without
    /// crossing an actor boundary.
    public enum DepositSheetDefaults {
        /// The production page. Dev builds point at `embedURLDev`.
        public static let embedURL = "https://deposit.rhinestone.dev"
        public static let embedURLDev = "https://dev.deposit.rhinestone.dev"

        /**
         How long to wait for the page to say `hello`.

         The user script runs at document start, so the channel is there before
         the page's own scripts — but a failed load, a captive portal or a
         content blocker all look the same from here. One reload costs a second
         and fixes a transient; a second would only loop, so the failure is
         surfaced instead.
         */
        public static let handshakeTimeout: TimeInterval = 8
    }

    @MainActor
    public final class DepositSheetController: UIViewController {
        private let embedURL: String
        private let identity: HostIdentity
        private let handshakeTimeout: TimeInterval
        private let pollInterval: TimeInterval

        private var config: EmbedConfig
        private var wallet: WalletBridge?
        private var callbacks: DepositSheetCallbacks
        private let sendTransaction:
            (@MainActor (SendTransactionParams) async throws -> SendTransactionResult)?
        private let signRecovery:
            (@MainActor (SignRecoveryParams) async throws -> SignRecoveryResult)?

        private var webView: WKWebView!
        private var host: BridgeHost!
        private var watch: DepositWatch?
        private let nonce = Injection.makeSessionNonce()
        private var handshakeTimer: Task<Void, Never>?
        private var hasReloaded = false
        private var settled = false
        /// The page's own version, learned at hello. Also what says there is a
        /// session to poll alongside.
        private var modalVersion: String?
        /// A dismissal the page asked for while it was locked, honoured when
        /// the lock lifts.
        private var dismissWhenUnlocked = false
        private let spinner = UIActivityIndicatorView(style: .medium)

        public init(
            config: EmbedConfig,
            wallet: WalletBridge? = nil,
            sendTransaction: (
                @MainActor (SendTransactionParams) async throws -> SendTransactionResult
            )? = nil,
            signRecovery: (@MainActor (SignRecoveryParams) async throws -> SignRecoveryResult)? =
                nil,
            callbacks: DepositSheetCallbacks = DepositSheetCallbacks(),
            embedURL: String = DepositSheetDefaults.embedURL,
            app: (name: String?, version: String?)? = nil,
            handshakeTimeout: TimeInterval = DepositSheetDefaults.handshakeTimeout,
            pollInterval: TimeInterval = DepositWatchDefaults.pollInterval
        ) {
            self.config = config
            self.wallet = wallet
            self.sendTransaction = sendTransaction
            self.signRecovery = signRecovery
            self.callbacks = callbacks
            self.embedURL = embedURL
            self.identity = HostIdentity(
                platform: .ios,
                app: app?.name ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName")
                    as? String,
                version: app?.version
                    ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
                    as? String
            )
            self.handshakeTimeout = handshakeTimeout
            self.pollInterval = pollInterval
            super.init(nibName: nil, bundle: nil)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("Not available from a nib.") }

        // MARK: - Lifecycle

        public override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .systemBackground
            buildWebView()
            buildHost()
            armHandshakeDeadline()
            load()
            observeForeground()
        }

        private func buildWebView() {
            let configuration = WKWebViewConfiguration()
            configuration.allowsInlineMediaPlayback = true
            // Only the main frame learns the nonce. On iOS the frame is also
            // checked natively when a message arrives; this is the half a
            // sub-frame can see.
            configuration.userContentController.addUserScript(
                WKUserScript(
                    source: Injection.channelScript(nonce: nonce),
                    injectionTime: .atDocumentStart,
                    forMainFrameOnly: true
                )
            )
            configuration.userContentController.add(
                WeakScriptMessageHandler(self),
                name: Injection.nativeHandlerName
            )

            webView = WKWebView(frame: .zero, configuration: configuration)
            webView.navigationDelegate = self
            webView.uiDelegate = self
            webView.allowsBackForwardNavigationGestures = false
            // The page sizes itself to the visual viewport and draws its own
            // safe-area padding; a second inset here would double it.
            webView.scrollView.contentInsetAdjustmentBehavior = .never
            webView.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(webView)

            spinner.translatesAutoresizingMaskIntoConstraints = false
            spinner.startAnimating()
            view.addSubview(spinner)

            NSLayoutConstraint.activate([
                webView.topAnchor.constraint(equalTo: view.topAnchor),
                webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
                webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
                spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            ])
        }

        private func buildHost() {
            host = BridgeHost(
                post: { [weak self] script in
                    self?.webView.evaluateJavaScript(script, completionHandler: nil)
                },
                nonce: nonce,
                identity: identity,
                config: { [weak self] in self?.config ?? Self.emptyConfig },
                wallet: { [weak self] in self?.wallet?.state ?? .none },
                handlers: { [weak self] in self?.currentHandlers() ?? BridgeHost.Handlers() },
                onEvent: { [weak self] type, payload in self?.handle(event: type, payload: payload) },
                onHello: { [weak self] params in self?.handleHello(params) }
            )
        }

        /**
         Rebuilt on demand and never held.

         Nothing about a handler may rebuild the host — not its identity and not
         its presence. A host rebuilt because a wallet arrived late is a host
         rebuilt underneath a page that has already handshaken with the old one,
         and the page has no reason to handshake again.
         */
        private func currentHandlers() -> BridgeHost.Handlers {
            var handlers = BridgeHost.Handlers()
            if let wallet {
                handlers.walletRequest = { params in try await wallet.request(params) }
            }
            if let sendTransaction {
                handlers.sendTransaction = { params in try await sendTransaction(params) }
            }
            if let signRecovery {
                handlers.signRecovery = { params in try await signRecovery(params) }
            }
            // Always present: the browser hand-off is what makes the card and
            // exchange rows work at all, and this wrapper can always do it.
            handlers.openURL = { [weak self] params in self?.present(browserFor: params.url) }
            return handlers
        }

        private func load() {
            guard let url = URL(string: embedURL) else {
                callbacks.onFatal?(DepositSheetError.handshakeFailed)
                return
            }
            webView.load(URLRequest(url: url))
        }

        // MARK: - The handshake deadline

        private func armHandshakeDeadline() {
            handshakeTimer?.cancel()
            handshakeTimer = Task { [weak self, handshakeTimeout] in
                try? await Task.sleep(nanoseconds: UInt64(handshakeTimeout * 1_000_000_000))
                guard !Task.isCancelled, let self, !self.settled else { return }
                if !self.hasReloaded {
                    self.hasReloaded = true
                    self.webView.reload()
                    self.armHandshakeDeadline()
                    return
                }
                self.callbacks.onFatal?(DepositSheetError.handshakeFailed)
            }
        }

        private func handleHello(_ params: HelloParams) {
            settled = true
            handshakeTimer?.cancel()
            modalVersion = params.modalVersion
            startWatch(modalVersion: params.modalVersion)
        }

        /**
         The watch cannot start before hello: its requests carry the same
         version header the page's do, so the pair is one client at the
         processor rather than two, and only the page can name its half.
         */
        private func startWatch(modalVersion: String) {
            watch?.stop()
            guard !config.recipient.isEmpty else { return }
            let watch = DepositWatch(
                backendURL: config.backendUrl,
                recipient: config.recipient,
                versionHeader: WrapperVersion.headerValue(
                    modalVersion: modalVersion,
                    host: identity
                ),
                interval: pollInterval,
                onSettled: { [weak self] deposit in self?.callbacks.onDepositSettled?(deposit) },
                onError: { _ in
                    // A poll failure is not the flow's failure — the page runs
                    // its own tracker against the same backend and reports what
                    // it sees. Surfacing this too would double every outage.
                }
            )
            self.watch = watch
            watch.start()
        }

        /// Returning from the payment browser is the one moment a poll is worth
        /// more than the interval it would otherwise wait for.
        private func observeForeground() {
            NotificationCenter.default.addObserver(
                forName: UIApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in await self?.watch?.poll() }
            }
        }

        // MARK: - Updates from the app

        /// Config is not a mount-time value: appearance can change while the
        /// sheet is open, and the page repaints in place without disturbing the
        /// flow.
        public func update(config: EmbedConfig) {
            let moved = SessionUpdate.corridorMoved(from: self.config, to: config)
            self.config = config
            if host.connected { host.configure(config) }
            /**
             The watch follows the config rather than the one it was born with.

             An app that switches account behind a live sheet would otherwise
             leave the page starting deposits for one address while the watcher
             polled another — and the completion the web view died through is
             then missed by the only thing still looking for it. Restarting
             takes a fresh baseline, which is right: what was already finished
             for a different account is not this account's news.
             */
            if moved, let modalVersion { startWatch(modalVersion: modalVersion) }
        }

        /**
         `nil` is a disconnect, and it has to be SAID.

         Capabilities are settled once at hello, but wallet availability rides
         `wallet.state` — so a host that drops its wallet and pushes nothing
         leaves the page rendering the old connected account, and the next
         wallet action answers 4200 instead of the page falling back to the
         funding paths that need no wallet.
         */
        public func update(wallet: WalletBridge?) {
            self.wallet = wallet
            if host.connected { host.pushWalletState(wallet?.state ?? .none) }
        }

        // MARK: - Events

        private func handle(event type: String, payload: JSONValue?) {
            switch PageEvent(rawValue: type) {
            case .ready:
                spinner.stopAnimating()
                spinner.isHidden = true
                callbacks.onReady?()
            case .lifecycle:
                callbacks.onLifecycle?(payload)
            case .analytics:
                callbacks.onAnalytics?(payload)
            case .error:
                callbacks.onError?(payload)
            case .walletConnectRequested:
                wallet?.onConnectRequested?()
            case .walletDisconnectRequested:
                wallet?.onDisconnectRequested?()
            case .uiState:
                applyUiState()
            case .dismissRequested:
                let source = try? payload?.decoded(as: DismissRequestedPayload.self)
                // A completed flow closes itself even while the lock is on: the
                // lock exists for what is in flight, and nothing is.
                if source?.source != .flowComplete, host.uiState?.dismissal.isBlocked == true {
                    dismissWhenUnlocked = true
                    return
                }
                dismissNow()
            case .none:
                // An unknown event is dropped. The page may be one release
                // ahead of this build.
                return
            }
        }

        /**
         The lock and the sheet's height, both derived from the same snapshot.

         `isModalInPresentation` is what makes the dismissal lock enforceable on
         iOS: without it the interactive swipe closes the sheet mid-signature
         and the page — the only thing tracking that deposit — is destroyed.
         */
        private func applyUiState() {
            guard let state = host.uiState else { return }
            isModalInPresentation = state.dismissal.isBlocked
            if dismissWhenUnlocked, !state.dismissal.isBlocked {
                dismissWhenUnlocked = false
                dismissNow()
            }
            apply(contentHeight: state.contentHeight)
        }

        /**
         Size the sheet to what the flow is showing.

         Absent means the page has nothing laid out to measure — never zero — so
         the presentation stays whatever it already was rather than collapsing.
         A custom detent needs iOS 16; below that the sheet keeps the detents it
         was given, which is the presentation this wrapper had before the page
         published a height at all.
         */
        private func apply(contentHeight: Double?) {
            guard let contentHeight, contentHeight > 0,
                let sheet = sheetPresentationController
            else { return }
            if #available(iOS 16.0, *) {
                let detent = UISheetPresentationController.Detent.custom(
                    identifier: .depositContent
                ) { context in
                    min(CGFloat(contentHeight), context.maximumDetentValue)
                }
                sheet.animateChanges {
                    sheet.detents = [detent, .large()]
                    sheet.selectedDetentIdentifier = .depositContent
                }
            }
        }

        private func dismissNow() {
            dismissWhenUnlocked = false
            watch?.stop()
            host.close()
            callbacks.onDismiss?()
        }

        /**
         A dismissal the page did not ask for: the close affordance the host
         owns.

         The page gets first refusal — back is a navigation before it is an exit
         — and the lock is checked separately, because a page that has stopped
         answering has also stopped telling us it is locked.
         */
        public func requestDismiss() {
            Task { @MainActor in
                let answer = await host.back()
                if answer.handled { return }
                if host.uiState?.dismissal.isBlocked == true {
                    dismissWhenUnlocked = true
                    return
                }
                dismissNow()
            }
        }

        // MARK: - The system browser

        /**
         A browser container, never the web view itself and never another app.

         `SFSafariViewController` presents over this app, so the user returns
         with one tap and lands where a redirect would. `openURL:` would hand
         them to a different app entirely.
         */
        private func present(browserFor url: String) {
            guard let parsed = URL(string: url), parsed.scheme?.lowercased() == "https" else {
                return
            }
            let browser = SFSafariViewController(url: parsed)
            browser.dismissButtonStyle = .close
            present(browser, animated: true)
        }

        private static let emptyConfig = EmbedConfig(
            mode: .deposit,
            backendUrl: "",
            recipient: "",
            targetChain: .evm(0),
            targetToken: ""
        )
    }

    @available(iOS 16.0, *)
    extension UISheetPresentationController.Detent.Identifier {
        static let depositContent = UISheetPresentationController.Detent.Identifier(
            "rhinestone.deposit.content"
        )
    }

    // MARK: - The channel

    extension DepositSheetController: WKScriptMessageHandler {
        /**
         The frame check the React Native wrapper cannot make.

         `frameInfo` is native and invisible to JavaScript, so a sub-frame
         cannot forge it. The nonce carried in the body is the second half: it
         is what makes the same logic testable without a web view, and what
         keeps this correct if the platform ever stops reporting the frame.
         */
        public func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard message.frameInfo.isMainFrame else { return }
            // A page that navigated away is not our page, and the injected
            // script would have run there too.
            let origin = message.frameInfo.securityOrigin
            let sender = "\(origin.protocol)://\(origin.host)"
            guard Origin.isSameOrigin(sender, as: embedURL) else { return }
            host.receive(message.body)
        }
    }

    /// The content controller retains its handlers, and a controller that
    /// retains the web view would then never deinit.
    private final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
        private weak var target: (any WKScriptMessageHandler)?

        init(_ target: any WKScriptMessageHandler) { self.target = target }

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            target?.userContentController(userContentController, didReceive: message)
        }
    }

    // MARK: - Navigation

    extension DepositSheetController: WKNavigationDelegate {
        /**
         The web view is pinned to our origin.

         A redirect inside the container would otherwise put another document on
         the same web view as the bridge — and the main-frame injection would
         hand it the nonce. Compared by parsing rather than by prefix, because
         `https://deposit.rhinestone.dev.evil.example` passes a `hasPrefix` and
         is not our origin.

         Anything else is a link the page meant to open outside — a block
         explorer, a provider's terms — and handing it to the browser is what
         keeps it from being a dead tap.
         */
        public func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            let url = navigationAction.request.url?.absoluteString ?? ""
            // Sub-frames are not this gate's business, and treating them as one
            // breaks the page: a frame load is neither a navigation away from
            // our origin nor a link the user tapped. The wallet seam is
            // protected from a frame by the frame check and the nonce, not by
            // this.
            if navigationAction.targetFrame?.isMainFrame == false {
                return decisionHandler(.allow)
            }
            if url == "about:blank" || Origin.isSameOrigin(url, as: embedURL) {
                return decisionHandler(.allow)
            }
            if Origin.httpsAuthority(of: url) != nil { present(browserFor: url) }
            decisionHandler(.cancel)
        }

        public func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) {
            callbacks.onFatal?(DepositSheetError.pageUnreachable(underlying: error))
        }
    }

    extension DepositSheetController: WKUIDelegate {
        /**
         The other way a link leaves the page, and the one a navigation gate
         never sees.

         `target="_blank"` and `window.open` ask WebKit to create a second web
         view rather than to navigate this one. Left unhandled they are dead
         taps — or worse, a child web view holding a provider page outside the
         origin gate.

         Our own origin is ignored rather than forwarded: the page has no reason
         to pop itself, and answering by opening a second, bridge-less copy of
         the deposit page in the browser is worse than the dead tap.
         */
        public func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            let url = navigationAction.request.url?.absoluteString ?? ""
            if !Origin.isSameOrigin(url, as: embedURL), Origin.httpsAuthority(of: url) != nil {
                present(browserFor: url)
            }
            return nil
        }
    }

    // MARK: - Dismissal

    extension DepositSheetController: UIAdaptivePresentationControllerDelegate {
        /// Reached only while `isModalInPresentation` is true — the user swiped
        /// at a moment the page said it must not be closed. Asking the page
        /// keeps the two sides in agreement about why.
        public func presentationControllerDidAttemptToDismiss(
            _ presentationController: UIPresentationController
        ) {
            requestDismiss()
        }

        public func presentationControllerDidDismiss(
            _ presentationController: UIPresentationController
        ) {
            dismissNow()
        }
    }

#endif
