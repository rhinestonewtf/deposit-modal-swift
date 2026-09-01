import Foundation

/**
 The two halves of the channel that have to be written as source text.

 WKWebView gives us `window.webkit.messageHandlers.<name>.postMessage` in one
 direction and `evaluateJavaScript` in the other. Neither is the shape the page
 expects, so both adaptations live here rather than inside the view — which is
 also what lets the whole contract be tested without WebKit.
 */
public enum Injection {
    /// The WKWebView message handler the injected shim forwards to. Distinct
    /// from the page-facing name so a page that reaches for the native handler
    /// directly is not what we are listening to.
    public static let nativeHandlerName = "rhinestoneBridgeNative"

    /// Separates the nonce from the frame. Not produced by `JSON.stringify`.
    public static let nonceSeparator = "|"

    private static let installedFlag = "__rhinestoneChannelInstalled"

    /**
     Installs the page→host half, and nothing else.

     **On iOS the frame boundary is enforced twice, and only one of them is
     visible to JavaScript.** `WKUserScript(forMainFrameOnly: true)` means a
     sub-frame never learns the nonce, and `WKScriptMessage.frameInfo.isMainFrame`
     is checked natively when the message arrives. The nonce alone would be the
     React Native wrapper's answer, where no frame information exists; here it
     is the belt to the platform's braces, and it is what makes this testable
     without a web view.

     The nonce is not a secret from the page — the page is us. It separates our
     own document from everything else loaded in the same web view.
     */
    public static func channelScript(nonce: String) -> String {
        // Interpolates a nonce we generated ourselves, never anything the page
        // or a provider supplied.
        """
        (function () {
          if (window.\(installedFlag)) { return; }
          window.\(installedFlag) = true;
          var handler = window.webkit
            && window.webkit.messageHandlers
            && window.webkit.messageHandlers.\(nativeHandlerName);
          if (!handler) { return; }
          var send = function (json) {
            if (typeof json !== 'string') { return; }
            handler.postMessage(\(jsonStringLiteral(nonce)) + \(jsonStringLiteral(nonceSeparator)) + json);
          };
          Object.defineProperty(window, '\(BridgeProtocol.pageToHostChannel)', {
            value: Object.freeze({ postMessage: send }),
            writable: false,
            configurable: false,
          });
        })();
        """
    }

    public struct InboundFrame: Equatable, Sendable {
        public let nonce: String
        public let json: String
    }

    /**
     Split what the message handler produced. `nil` for anything that is not
     `<nonce>|<json>` — including a frame posted by something that never saw the
     shim, which carries no prefix at all.
     */
    public static func parseInboundFrame(_ raw: Any?) -> InboundFrame? {
        guard let raw = raw as? String else { return nil }
        guard let separator = raw.firstIndex(of: Character(nonceSeparator)),
            separator != raw.startIndex
        else { return nil }
        return InboundFrame(
            nonce: String(raw[raw.startIndex..<separator]),
            json: String(raw[raw.index(after: separator)...])
        )
    }

    /// Wrap a frame as a call to the page's receiver.
    public static func encodeFrameForEvaluation(_ json: String) -> String {
        // The trailing `true;` keeps WebKit from warning about a
        // non-serializable evaluation result.
        "window.\(BridgeProtocol.hostToPageChannel) && window.\(BridgeProtocol.hostToPageChannel)(\(jsonStringLiteral(json))); true;"
    }

    /**
     A nonce for one web-view session.

     `SystemRandomNumberGenerator` is the platform CSPRNG. One session, kept
     across a reload: the page is the same document from the channel's point of
     view, and rotating it would only orphan frames in flight.
     */
    public static func makeSessionNonce() -> String {
        var generator = SystemRandomNumberGenerator()
        let high = UInt64.random(in: .min ... .max, using: &generator)
        let low = UInt64.random(in: .min ... .max, using: &generator)
        return String(format: "%016lx%016lx", high, low)
    }

    /**
     A JSON string literal, additionally escaping what is legal in JSON but not
     safe in script source.

     U+2028 and U+2029 were line terminators in JS before ES2019, so an
     unescaped one truncates the statement on an older engine. This boundary
     carries wallet-controlled text by design — `BridgeError.message` is the
     wallet's own copy — so it is not theoretical. `<` goes too, cheaply, so the
     same encoder stays correct if a frame ever reaches a `<script>` body.
     */
    static func jsonStringLiteral(_ value: String) -> String {
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "<", "\u{2028}", "\u{2029}":
                out += String(format: "\\u%04x", scalar.value)
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }
}
