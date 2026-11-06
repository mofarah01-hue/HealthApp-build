import Foundation
import MGDomain

// Older periods from the PC, on request (tracker #7, 2026-10-11; Mo: "historical on server, recentish things on phone
// … raw and processed labeled which algorithm/source"). GET /v1/history, written against app/pclab/mglab/history.py
// `range_answer` and sync-api.schema.json `historyResponse` as read on 2026-10-11. app/shared/fixtures/pclab/
// history.v1.json is the shared example: PCHistoryTests decodes it here and pclab/tests/test_history_range.py checks it
// against the live route, so a rename on either side fails a test.
//
// Nothing here writes anywhere: the fetch takes no store, and the app keeps the answer in a bounded in-memory cache only
// (MGContext PCHistoryCache). The phone's own window (the published 12 months) stays the only stored history.

/// GET /v1/history → 200.
public struct PCHistoryReply: Decodable, Equatable, Sendable {
    public struct Item: Decodable, Equatable, Sendable {
        public var date: LocalDay
        /// "pc.history@1" (Apple's / WHOOP's own value, raw) or "pc.history-derived@1" (ours on it, processed).
        public var model: String
        /// A contract metric without method / citation / note (`methods` has them once per name|variant).
        public var metric: Metric
    }

    public struct MethodText: Decodable, Equatable, Sendable {
        public var method: String?
        public var citation: String?
        public var model: String?
    }

    public struct Model: Decodable, Equatable, Sendable {
        public var model: String
        /// "raw" · "processed".
        public var kind: String
        public var how: String
    }

    public var from: LocalDay
    public var to: LocalDay
    public var latest: Bool
    /// The dates the PC's imports cover as a whole; nil = no import.
    public var oldest: LocalDay?
    public var newest: LocalDay?
    public var days: Int
    public var count: Int
    public var items: [Item]
    public var methods: [String: MethodText]
    public var truncated: Bool
    /// When `truncated`: dates before this were left out (the newest are kept).
    public var cutBefore: LocalDay?
    public var limit: Int
    public var models: [Model]
    public var imports: [String]
    public var generatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case from, to, latest, oldest, newest, days, count, items, methods, truncated, limit, models, imports
        case cutBefore = "cut_before"
        case generatedAt = "generated_at"
    }

    /// The items as (day, metric) with `method` and `citation` filled back in from `methods`, so the receipt and About
    /// name the algorithm and the import. Rows without a value are dropped (the PC never sends them; a guard).
    public func rows() -> [(day: LocalDay, metric: Metric)] {
        items.compactMap { item in
            guard item.metric.value?.isFinite == true else { return nil }
            var m = item.metric
            if let t = methods["\(m.name)|\(m.variant ?? "")"] {
                if m.method == nil { m.method = t.method }
                if m.citation == nil { m.citation = t.citation }
            }
            return (item.date, m)
        }
    }
}

public enum PCHistoryResult: Equatable, Sendable {
    case history(PCHistoryReply)
    /// No PC paired on this phone.
    case notPaired
    /// No HTTP answer: Tailscale off, PC asleep or PC Lab not running.
    case unreachable(String)
    /// An HTTP answer that is not a history answer (an older PC Lab, a bad request), with the PC's reason.
    case refused(String)
}

public enum PCLabHistory {
    /// One GET /v1/history with the paired device key (60 s). Never throws: every way it can fail is a case.
    /// `names` nil = every metric; `latest` = only the newest value per (name, variant, window).
    public static func fetch(credentials: any CredentialStore,
                             transport: any PCLabTransport = URLSessionPCLabTransport(),
                             from: LocalDay, to: LocalDay, names: [String]?,
                             latest: Bool = false) async -> PCHistoryResult {
        let creds: PCCredentials?
        do { creds = try credentials.load() } catch { return .refused("The PC pairing couldn't be read: \(error)") }
        guard let creds else { return .notPaired }
        let client = PCLabClient(transport: transport, baseURL: creds.baseURL, deviceKey: creds.deviceKey)
        do {
            let reply = try await client.history(from: from, to: to, names: names, latest: latest)
            return decode(status: reply.status, body: reply.body)
        } catch let e as TransportError {
            return .unreachable(e.description)
        } catch {
            return .unreachable("\(error)")
        }
    }

    static func decode(status: Int, body: Data) -> PCHistoryResult {
        guard status == 200 else {
            let reason = APIReply(status: status, body: body).apiError?.reason
            if status == 404 {
                return .refused("This PC Lab has no older-history route yet — restart it with the new code."
                                + (reason.map { " (\($0))" } ?? ""))
            }
            return .refused(reason ?? "HTTP \(status)")
        }
        do {
            return .history(try MGJSON.decoder().decode(PCHistoryReply.self, from: body))
        } catch {
            return .refused("The PC's history answer couldn't be read: \(error)")
        }
    }
}
