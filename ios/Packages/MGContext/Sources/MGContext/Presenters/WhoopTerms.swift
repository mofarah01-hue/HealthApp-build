import Foundation
import MGDomain

/// T9813 (Mo, Oct 15 2026, C6): "just need the output number today" for WHOOP's four day numbers, in WHOOP's terms.
///
/// Display rule (one place, one function): TODAY = ours. A PAST day = WHOOP's own number where the PC imported one,
/// ours otherwise. A day with both shows both ("WHOOP 14.2 · ours 12.9 (estimate)"). Nothing is averaged or blended and
/// a missing side is never shown as 0.
///
/// What "ours" and "WHOOP" are for each number (formulas live with the algorithm, not here):
/// - strain, 0-21: ours = the app's day strain (ALG-036: 21 * ln(1 + 14u) / ln 15, u = net TRIMP above the quiet level
///   / 400, OpenStrap load_trimp; the 0-21 map is not validated against WHOOP, so "estimate"); WHOOP = its export's
///   Day Strain.
/// - stress, 0-3: ours = ALG-123 daily (Baevsky-based). WHOOP's export carries no stress number, so there is never a
///   WHOOP side to show: the row says so instead of staying silent.
/// - sleep performance: ours = ALG-150 (asleep / need, capped at 1); WHOOP = its export's Sleep Performance.
/// - sleep consistency: ours = ALG-030 SRI over 14 nights (Phillips 2017, 0-100), "estimate": WHOOP's own formula is not
///   published; WHOOP = its export's Sleep Consistency (a fraction on the phone, shown here as 0-100).
public enum WhoopTerms {
    public enum Number: String, CaseIterable, Sendable {
        case strain, stress, sleep, sleepConsistency

        /// The registry name of our value and of WHOOP's (they differ only for sleep consistency).
        public var oursKey: String {
            switch self {
            case .strain: return "strain"
            case .stress: return "stress"
            case .sleep: return "sleep_performance"
            case .sleepConsistency: return "sri"
            }
        }

        public var whoopKey: String? {
            switch self {
            case .strain: return "strain"
            case .stress: return nil
            case .sleep: return "sleep_performance"
            case .sleepConsistency: return "sleep_consistency"
            }
        }

        /// Multiplier that brings WHOOP's stored number onto our scale (sleep consistency: fraction -> 0-100).
        var whoopScale: Double { self == .sleepConsistency ? 100 : 1 }
        /// Multiplier for display text (sleep performance is a fraction on both sides, shown as a percent).
        var textScale: Double { self == .sleep ? 100 : 1 }
        var decimals: Int { self == .strain || self == .stress ? 1 : 0 }

        /// The Explore catalogue key this number appears under.
        public static func forEntry(_ key: String) -> Number? {
            switch key {
            case "strain": return .strain
            case "stress": return .stress
            case "sleep_performance": return .sleep
            case "sleep_consistency": return .sleepConsistency
            default: return nil
            }
        }
    }

    public struct Pick: Equatable, Sendable {
        /// The number to show; nil = blank, with `reason`.
        public var headline: DatedMetric?
        /// The other side of the same day when both exist.
        public var other: DatedMetric?
        public var reason: String?
        public var caption: String?
    }

    static func finite(_ r: DatedMetric) -> Bool { r.metric.value?.isFinite ?? false }
    static func isWhoop(_ r: DatedMetric) -> Bool { r.metric.variant == ImportedHistory.whoopExport }

    /// `rows` = every stored row of the number (ours under `oursKey`, WHOOP's under `whoopKey`), any days.
    public static func pick(_ n: Number, rows: [DatedMetric], day: LocalDay, today: LocalDay) -> Pick {
        let onDay = rows.filter { $0.day == day && finite($0) }
        let whoop = n.whoopKey.flatMap { k in onDay.first { isWhoop($0) && $0.metric.name == k } }
        // Ours: the app's own value first, else ours computed on past data (`:import`); never Apple Health's or WHOOP's.
        let ours = onDay.filter { !isWhoop($0) && $0.metric.name == n.oursKey
            && ($0.metric.variant.map { $0 != ImportedHistory.appleHealth && $0 != ImportedHistory.appleWatch } ?? true) }
            .sorted { ImportedHistory.rank($0.metric) < ImportedHistory.rank($1.metric) }.first
        let isToday = day == today
        var p = Pick()
        if isToday {
            p.headline = ours
            p.other = whoop
            if ours == nil {
                // The reason carries WHOOP's number itself, so the claim "shown beside it" is true (round 5 review 4).
                p.reason = "No value of ours yet today" + (whoop.map { "; " + label($0, n) } ?? "")
            }
        } else {
            p.headline = whoop ?? ours
            p.other = (whoop != nil && ours != nil) ? ours : nil
            if p.headline == nil {
                p.reason = n.whoopKey == nil ? "WHOOP's export has no stress number; ours could not be computed for this day"
                    : "Neither WHOOP's export nor ours has a value for this day"
            }
        }
        if let h = p.headline, let o = p.other { p.caption = "\(label(h, n)) · \(label(o, n))" }
        else if n.whoopKey == nil, p.headline != nil { p.caption = "WHOOP's export has no stress number" }
        return p
    }

    /// "WHOOP 14.2" / "ours 12.9 (estimate)".
    static func label(_ r: DatedMetric, _ n: Number) -> String {
        guard let (t, u) = parts(r, n) else { return "" }
        let text = t + (u.map { " " + $0 } ?? "")
        return isWhoop(r) ? "WHOOP \(text)" : "ours \(text) (estimate)"
    }

    /// The number and unit as shown, in WHOOP's terms: WHOOP's stored value is first brought onto our scale (sleep
    /// consistency fraction -> 0-100), then sleep numbers are shown as a percent. The headline and the caption both use this
    /// (round 5 review 1: the headline used to print the raw stored number).
    static func parts(_ r: DatedMetric, _ n: Number) -> (String, String?)? {
        guard let v = r.metric.value, v.isFinite else { return nil }
        let x = (isWhoop(r) ? v * n.whoopScale : v) * n.textScale
        return (MGFormat.number(x, decimals: n.decimals), n == .sleep || n == .sleepConsistency ? "%" : nil)
    }

    /// The day an Explore row speaks for: the newest day with a value on either side.
    public static func latestDay(_ n: Number, rows: [DatedMetric]) -> LocalDay? {
        rows.filter { finite($0) && (isWhoop($0) ? $0.metric.name == n.whoopKey : $0.metric.name == n.oursKey) }
            .map(\.day).max()
    }
}
