import Foundation

/// Nov 5 2026: is the stored PC address a NAME (MagicDNS: needs DNS and the tunnel) or an IP address (needs only the tunnel)?
/// Shown in the debug channel's `health_sync` block, because "hostname could not be found" is a question about the name.
public enum PCAddressKind: String, Sendable {
    case name
    case ip

    /// `host` is `URL.host` (no brackets around an IPv6 literal).
    public static func of(host: String?) -> PCAddressKind? {
        guard let host = host?.lowercased(), !host.isEmpty else { return nil }
        if host.contains(":") { return .ip }                                  // IPv6 literal
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        if parts.count == 4, parts.allSatisfy({ UInt8($0) != nil }) { return .ip }
        return .name
    }
}
