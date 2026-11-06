import Foundation
import WhoopProtocol

/// The protocol's CommandNumber table (whoop_protocol.json, a resource of WhoopProtocol), for Settings › Command test
/// (T87, 2026-10-13). The bundled table names 80 commands; a number it does not name can't be picked on the page.
public enum StrapCommandTable {
    /// (number, name), by number.
    public static func all() -> [(number: Int, name: String)] {
        (loadSchema().enums["CommandNumber"] ?? [:])
            .compactMap { key, name in Int(key).map { (number: $0, name: name) } }
            .sorted { $0.number < $1.number }
    }
}
