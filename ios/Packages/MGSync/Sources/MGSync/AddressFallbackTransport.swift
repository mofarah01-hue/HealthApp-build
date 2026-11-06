import Foundation

/// 2026-11-05: Apple Health stopped reaching the PC at 5:58 PM with "PC not reachable (hostname could not be found)". The
/// pairing QR carries a MagicDNS NAME; a background wake can ask for it before the Tailscale tunnel is up, and the name
/// does not resolve. The PC's own Tailscale 100.x address needs no DNS.
///
/// Wraps any transport. On `TransportError.dnsFailure` (and only then) it retries ONCE against the PC's stored
/// Tailscale address, waits `tunnelWait` seconds if that fails too (the tunnel may be seconds away) and tries the address
/// once more, then gives up with that attempt's error.
/// - The address is `PCCredentials.tailscaleIP`, learned from any successful `GET /v1/health` (the PC reports
///   `tailscale_ip`). Only an IPv4 address in 100.64.0.0/10 is stored or used, so the device key never goes anywhere else.
/// - Only for plain `http` (route B: WireGuard encrypts). For `https` the certificate names the host, not the address.
/// - TLS, auth headers, redirects and body are the inner transport's, unchanged.
public struct AddressFallbackTransport: PCLabTransport {
    private let inner: any PCLabTransport
    private let credentials: any CredentialStore
    private let tunnelWait: TimeInterval
    private let sleep: @Sendable (TimeInterval) async -> Void

    public init(inner: any PCLabTransport, credentials: any CredentialStore, tunnelWait: TimeInterval = 4,
                sleep: @escaping @Sendable (TimeInterval) async -> Void = { s in
                    try? await Task.sleep(nanoseconds: UInt64(max(0, s) * 1_000_000_000))
                }) {
        self.inner = inner
        self.credentials = credentials
        self.tunnelWait = tunnelWait
        self.sleep = sleep
    }

    public func send(_ request: PCRequest, baseURL: URL) async throws -> PCResponse {
        do {
            let response = try await inner.send(request, baseURL: baseURL)
            if request.method == "GET", request.path == "/v1/health", response.status == 200 { learn(from: response.body) }
            return response
        } catch let first as TransportError {
            guard case .dnsFailure = first, let alt = alternateBase(for: baseURL) else { throw first }
            do {
                return try await inner.send(request, baseURL: alt)
            } catch let second as TransportError {
                _ = second
                await sleep(tunnelWait)
                if Task.isCancelled { throw CancellationError() }
                return try await inner.send(request, baseURL: alt)
            }
        }
    }

    /// `baseURL` with its host replaced by the stored Tailscale address (same scheme and port), or nil when there is none
    /// to use: no address, not a Tailscale one, the base is already an address, or the base is https.
    func alternateBase(for baseURL: URL) -> URL? {
        guard baseURL.scheme?.lowercased() == "http", let host = baseURL.host,
              !AddressFallbackTransport.looksLikeIPv4(host),
              let ip = (try? credentials.load())?.tailscaleIP, AddressFallbackTransport.tailscaleIPv4(ip),
              var comps = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        else { return nil }
        comps.host = ip
        return comps.url
    }

    private func learn(from body: Data) {
        guard let obj = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let ip = obj["tailscale_ip"] as? String, AddressFallbackTransport.tailscaleIPv4(ip),
              var creds = try? credentials.load(), creds.tailscaleIP != ip else { return }
        creds.tailscaleIP = ip
        try? credentials.save(creds)
    }

    static func looksLikeIPv4(_ s: String) -> Bool {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { UInt8($0) != nil }
    }

    /// true for a dotted IPv4 address inside 100.64.0.0/10 (Tailscale's range).
    static func tailscaleIPv4(_ s: String) -> Bool {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        let octets = parts.compactMap { UInt8($0) }
        return parts.count == 4 && octets.count == 4 && octets[0] == 100 && (64...127).contains(octets[1])
    }
}
