import Foundation

/// The pairing link `mgapp://pair?v=1&base=<url-encoded base URL>&token=<token>&pc=<display name>` shown as a QR by
/// `python -m mglab pair` (ARCHITECTURE.md 5.2 step 1; app/pclab/mglab/qr.py `pairing_url` / `parse_pairing_url`).
/// `base` is whatever the PC chose: `http://<pc>:18787` (route B, the BRIEF default) or `https://<pc>.<tailnet>.ts.net`
/// (route A). The app uses it as is.
public struct PairingPayload: Equatable, Sendable {
    public var base: URL
    public var token: String
    public var pcName: String

    public init(base: URL, token: String, pcName: String) {
        self.base = base
        self.token = token
        self.pcName = pcName
    }

    /// nil unless `url` is `mgapp://pair` with `v=1`, an `http(s)` `base` that has a host (and no credentials, query or
    /// fragment) and a non-empty `token`. `pc` is optional (falls back to the host name). The query is
    /// percent-decoded by URLComponents; the first occurrence of a repeated key wins; unknown keys are ignored.
    public init?(url: URL) {
        guard url.scheme?.lowercased() == "mgapp",
              let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              comps.host?.lowercased() == "pair"
        else { return nil }
        var query: [String: String] = [:]
        for item in comps.queryItems ?? [] where query[item.name] == nil {
            query[item.name] = item.value ?? ""
        }
        guard query["v"] == "1",
              let baseText = query["base"], let token = query["token"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty
        else { return nil }
        guard let base = PairingPayload.parseBase(baseText), let host = base.host else { return nil }
        let pc = query["pc"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.init(base: base, token: token, pcName: pc.isEmpty ? host : pc)
    }

    /// For a link typed or pasted by hand (Strap & sync > Pair > enter manually).
    public init?(string: String) {
        guard let url = URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        self.init(url: url)
    }

    static func parseBase(_ text: String) -> URL? {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        guard let url = URL(string: s), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil
        else { return nil }
        return url
    }

    /// true when the base host is something only Tailscale can resolve or reach: a MagicDNS short name (no dot),
    /// `*.ts.net`, a Tailscale address (100.64.0.0/10, fd7a:115c:a1e0::/48), or the phone itself (localhost; used with
    /// the simulator). `SyncEngine.pair` refuses any other host unless told otherwise, so a bad link cannot send the
    /// day files to a server on the open internet (BRIEF privacy rule).
    public var isTailscaleHost: Bool {
        PairingPayload.isTailscaleHost(base.host ?? "")
    }

    /// true for plain `http` (route B: encrypted by WireGuard, not by TLS).
    public var isPlainHTTP: Bool { base.scheme?.lowercased() == "http" }

    static func isTailscaleHost(_ rawHost: String) -> Bool {
        let host = rawHost.lowercased()
        if host.isEmpty { return false }
        if host == "localhost" || host == "127.0.0.1" || host == "::1" { return true }
        if host.hasSuffix(".ts.net") { return true }
        if host.contains(":") {                       // IPv6 literal (URL.host has no brackets)
            return host.hasPrefix("fd7a:115c:a1e0:")
        }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        if parts.count == 1 { return true }           // MagicDNS short name, e.g. "my-pc"
        let octets = parts.compactMap { UInt8($0) }
        if parts.count == 4, octets.count == 4 {      // IPv4 literal
            return octets[0] == 100 && (64...127).contains(octets[1])
        }
        return false
    }
}
