import Foundation
import MGDomain

// WP-24 — sync receipts batched into one notification, and the "Turn on Tailscale" rule (PLAN §2, ARCHITECTURE §4.11,
// §5.5). Pure; mirrored in scratchpad/wp24/notify_mirror.py.

/// A time span the PC confirmed it stored (receipt `range_start` … `range_end`, contract syncReceipt).
struct NotifySpan: Codable, Equatable, Sendable {
    var start: Date
    var end: Date
}

/// Everything delivered since the last receipt notification went out. Each sync's `DeliverySummary` is added; the
/// batch keeps ONE request id until its notification has fired, so a later delivery replaces the pending request
/// with the merged totals instead of adding a second notification ("hourly receipts are batched into one").
struct NotifyReceiptBatch: Codable, Equatable, Sendable {
    var id: String
    var drops: Int = 0
    var files: Int = 0
    /// Bytes as uploaded (compressed), from the receipts (§5.5).
    var bytes: Int = 0
    var records: Int = 0
    /// Union of the delivered ranges, sorted, non-overlapping: a re-sent hour is counted once.
    var spans: [NotifySpan] = []
    var pcName: String?
    /// When its notification fires (now or later); nil = not scheduled yet.
    var scheduledFor: Date?

    init(id: String) { self.id = id }

    mutating func add(_ s: DeliverySummary) {
        drops += s.drops
        files += s.files
        bytes += s.bytes
        records += s.records
        if let name = s.pcName { pcName = name }
        if let a = s.rangeStart, let b = s.rangeEnd, b >= a {
            spans = NotifyReceiptBatch.union(spans, NotifySpan(start: a, end: b))
        }
    }

    /// Seconds of data covered, overlaps counted once.
    var coveredSeconds: TimeInterval { spans.reduce(0) { $0 + $1.end.timeIntervalSince($1.start) } }

    static func union(_ spans: [NotifySpan], _ new: NotifySpan) -> [NotifySpan] {
        var out: [NotifySpan] = []
        for s in (spans + [new]).sorted(by: { $0.start < $1.start }) {
            if let last = out.last, s.start <= last.end {
                out[out.count - 1].end = max(last.end, s.end)
            } else {
                out.append(s)
            }
        }
        return out
    }
}

/// When to remind Mo to switch Tailscale on (PLAN §2 "Reminder", UX §4.2 "Data waiting to sync").
enum NotifyReminderRule {
    /// True when: the engine says offline, something is waiting, the last successful sync is more than
    /// `reminderUnsyncedAfter` ago (the same 6 h rule as the "data waiting" Moment card), and the PC has been
    /// unreachable for at least `reminderUnreachableFor`. Never synced (no `lastSynced`) → false, like the Moment
    /// card (WP-06: "nil → amber chip only"). Spacing and quiet hours are `NotifyPolicy.decide`'s job.
    static func tailscaleDue(now: Date, status: SyncStatus, unreachableSince: Date?, policy: NotifyPolicy) -> Bool {
        guard status.state == .offline else { return false }
        guard (status.unsyncedDays ?? 0) > 0, let last = status.lastSynced else { return false }
        guard now.timeIntervalSince(last) > policy.reminderUnsyncedAfter else { return false }
        guard let since = unreachableSince, now.timeIntervalSince(since) >= policy.reminderUnreachableFor else {
            return false
        }
        return true
    }
}
