import Foundation

/// Settings > Export, the phone's key-value area (bug 31, 2026-10-14): the profile-type data (profile, retention
/// setting, Apple Health anchors, future sizes list) that lives in the phone's `kv` table and is in no day file.
/// Pure: the store hands over (key, bytes) rows, this makes `kv/kv.json`. Nothing is dropped silently: the one key that
/// must never leave the phone (`install_salt`, ARCHITECTURE 4.3) is listed with its size and "withheld", never its bytes.
/// Each value is shown as readable JSON when its bytes are JSON, as text when UTF-8, else as base64; `bytes` is the
/// stored size either way.
public enum KeyValueExport {
    /// Keys whose bytes stay on the phone; they still appear in the list, with a reason.
    public static let withheld: [String: String] = [
        "install_salt": "per-install secret that never leaves the phone (it derives the strap id)",
    ]

    public struct Entry: Equatable {
        public let key: String
        public let bytes: Int
        public let encoding: String   // "json", "text", "base64", "withheld"
        public let value: Any?        // nil only for withheld
        public init(key: String, bytes: Int, encoding: String, value: Any?) {
            self.key = key; self.bytes = bytes; self.encoding = encoding; self.value = value
        }
        public static func == (a: Entry, b: Entry) -> Bool { a.key == b.key && a.bytes == b.bytes && a.encoding == b.encoding }
    }

    public static func entries(_ rows: [(key: String, value: Data)]) -> [Entry] {
        rows.sorted { $0.key < $1.key }.map { row in
            if withheld[row.key] != nil {
                return Entry(key: row.key, bytes: row.value.count, encoding: "withheld", value: nil)
            }
            if let json = try? JSONSerialization.jsonObject(with: row.value, options: [.fragmentsAllowed]) {
                return Entry(key: row.key, bytes: row.value.count, encoding: "json", value: json)
            }
            if let text = String(data: row.value, encoding: .utf8) {
                return Entry(key: row.key, bytes: row.value.count, encoding: "text", value: text)
            }
            return Entry(key: row.key, bytes: row.value.count, encoding: "base64", value: row.value.base64EncodedString())
        }
    }

    /// The bytes of `kv/kv.json`: `{"total_bytes", "count", "entries":[{key, bytes, encoding, value | withheld_reason}]}`.
    public static func data(_ rows: [(key: String, value: Data)]) throws -> Data {
        let list = entries(rows)
        let items: [[String: Any]] = list.map { e in
            var d: [String: Any] = ["key": e.key, "bytes": e.bytes, "encoding": e.encoding]
            if let v = e.value { d["value"] = v } else { d["withheld_reason"] = withheld[e.key] ?? "withheld" }
            return d
        }
        let doc: [String: Any] = ["count": list.count, "total_bytes": list.reduce(0) { $0 + $1.bytes }, "entries": items]
        return try JSONSerialization.data(withJSONObject: doc, options: [.prettyPrinted, .sortedKeys])
    }
}
