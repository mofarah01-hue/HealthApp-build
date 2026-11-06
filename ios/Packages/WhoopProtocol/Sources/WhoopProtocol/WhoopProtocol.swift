// Copied from ryanbr/noop @ e580175 Packages/WhoopProtocol/Sources/WhoopProtocol/WhoopProtocol.swift. PolyForm Noncommercial 1.0.0. Required Notice: Copyright 2026 NoopApp.
import Foundation

/// OpenWhoop protocol library — schema-driven WHOOP 4.0 frame decoder.
/// Implemented across Framing.swift / Values.swift / Schema.swift / Interpreter.swift (Phase B).
public enum WhoopProtocolInfo {
    /// URL of the bundled canonical decode schema (a resource of this package target).
    public static func schemaResourceURL() -> URL? {
        Bundle.module.url(forResource: "whoop_protocol", withExtension: "json")
    }
}
