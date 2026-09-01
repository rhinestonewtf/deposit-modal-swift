import Foundation

/**
 The version header, built the way the page builds it.

 The wrapper makes backend calls of its own — the deposit watch outlives the web
 view, which is the whole point of it — and those must be attributable to the
 same pair as the page's calls, or a mobile integration shows up at the
 processor as two unrelated clients.

 **A new header would be a breaking change for a self-hosted proxy with an
 explicit CORS allow-list**, so the wrapper's identity rides inside the existing
 header's value, exactly as the page does it. The page's own version stays first
 and unchanged, so anything reading a leading semver keeps working:
 `0.13.0 (ios; Acme/2.1.0)`.
 */
public enum WrapperVersion {
    /// This package's version. SPM publishes by git tag and puts nothing in the
    /// build, so the tag and this constant are kept together by CI rather than
    /// by a generator.
    public static let current = "0.1.0"

    public static let header = "x-deposit-modal-version"

    /**
     `app` and `version` are the integrator's own strings. A newline in either
     would be header injection, so both are reduced to a conservative charset
     and capped.
     */
    public static func headerValue(modalVersion: String, host: HostIdentity) -> String {
        let base = clean(modalVersion, max: 40).isEmpty ? current : clean(modalVersion, max: 40)
        let platform = clean(host.platform.rawValue, max: 16)
        let app = clean(host.app, max: 32)
        let version = clean(host.version, max: 24)
        let named = app.isEmpty ? "" : (version.isEmpty ? app : "\(app)/\(version)")
        let platformOrUnknown = platform.isEmpty ? "unknown" : platform
        return named.isEmpty
            ? "\(base) (\(platformOrUnknown))"
            : "\(base) (\(platformOrUnknown); \(named))"
    }

    private static let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-")

    private static func clean(_ value: String?, max: Int) -> String {
        String((value ?? "").filter { allowed.contains($0) }.prefix(max))
    }
}
