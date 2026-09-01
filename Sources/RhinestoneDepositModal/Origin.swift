import Foundation

/**
 Origin comparison, done by parsing rather than by prefix.

 The web view is pinned to our origin because a document loaded beside the
 bridge gets the main-frame injection, and with it the nonce that gates wallet
 traffic. A `hasPrefix` check does not express that:
 `https://deposit.rhinestone.dev.evil.example` and
 `https://deposit.rhinestone.dev@evil.example` both pass one and neither is our
 origin.

 `URL` is not used. Its parsing has changed across OS versions and it accepts
 shapes this must reject, and a pin that silently degrades on some release is
 worse than one written out.
 */
public enum Origin {
    /**
     The authority of an `https:` URL, lowercased, or `nil` for anything this
     must not treat as ours.

     Userinfo is rejected outright rather than parsed past: the real host of
     `https://a@b/` is `b`, we never mint such a URL, and refusing is both safer
     and shorter than being right about it. `\` goes with it — engines have
     historically read it as `/` while a naive parser does not.
     */
    public static func httpsAuthority(of url: String) -> String? {
        let scheme = "https://"
        guard url.count > scheme.count else { return nil }
        let start = url.index(url.startIndex, offsetBy: scheme.count)
        guard url[url.startIndex..<start].lowercased() == scheme else { return nil }

        var authority = ""
        for character in url[start...] {
            if character == "/" || character == "?" || character == "#" { break }
            if character == "@" || character == "\\" { return nil }
            authority.append(character)
        }
        guard !authority.isEmpty else { return nil }

        authority = authority.lowercased()
        // The default port is not part of the identity, and a page that links
        // to itself with one written out is still the same document.
        if authority.hasSuffix(":443") {
            authority.removeLast(4)
            guard !authority.isEmpty else { return nil }
        }
        return authority
    }

    /**
     Rebuild an origin from the parts a web view reports about a frame.

     The port is separate there and easy to drop, and dropping it is not a
     cosmetic loss: an embed origin like `https://localhost:3000` — a wrapper
     pointed at a page served locally — passes the navigation gate, loads, and
     then has every one of its bridge messages rejected as foreign, so it never
     handshakes at all. `0` is "the scheme's default", which is what a web view
     reports for 443.
     */
    public static func origin(host: String, port: Int) -> String {
        port == 0 || port == 443 ? "https://\(host)" : "https://\(host):\(port)"
    }

    public static func isSameOrigin(_ url: String, as origin: String) -> Bool {
        guard let target = httpsAuthority(of: url),
            let expected = httpsAuthority(of: origin)
        else { return false }
        return target == expected
    }
}
