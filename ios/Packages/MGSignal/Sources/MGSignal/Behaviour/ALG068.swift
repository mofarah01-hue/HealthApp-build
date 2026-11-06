import Foundation
import MGDomain

/// ALG-068 v1 — time to first vape after waking: minutes from the strap-detected wake (ALG-030; a nap does NOT reset
/// it — the caller passes the main sleep's wake) to the first hit, plus hits in the first hour after waking and hits in
/// the day. PS-ECDI item 2; Pienkowski et al. 2021 (n = 1,205: convergent validity). Hits logged before the wake do not
/// count as "first after waking" but do count in the day. An event may carry several puffs (`hits`).
/// Python reference: app/pclab/mglab/ref/behaviour.py `vape_after_waking`; goldens
/// app/shared/golden/behaviour/ALG-068.json.
public enum ALG068 {
    public static let method = "ALG-068@1 first-hit-after-wake"
    public static let citation = "PS-ECDI item 2; Pienkowski T et al. 2021"
    public static let firstHourSeconds = 3600.0

    /// One logged vape event (button, widget, strap double-tap): when, and how many puffs.
    public struct Hit: Sendable, Hashable {
        public var at: Date
        public var hits: Int

        public init(at: Date, hits: Int = 1) {
            self.at = at
            self.hits = hits
        }
    }

    /// Each field is a value or nil with its reason in `reasons[field]` (R6). `hitsFirstHour` is 0 (a fact) when the
    /// hour has passed with no hit; `firstHourComplete == false` means the hour is still running.
    public struct Summary: Sendable, Equatable {
        public var firstAfterWakeMin: Double?
        public var hitsFirstHour: Int?
        public var hitsDay: Int?
        public var firstHourComplete: Bool?
        public var reasons: [String: String]

        public init(firstAfterWakeMin: Double?, hitsFirstHour: Int?, hitsDay: Int?, firstHourComplete: Bool?,
                    reasons: [String: String]) {
            self.firstAfterWakeMin = firstAfterWakeMin
            self.hitsFirstHour = hitsFirstHour
            self.hitsDay = hitsDay
            self.firstHourComplete = firstHourComplete
            self.reasons = reasons
        }
    }

    /// ALG-068 v1 — see the type comment.
    /// - Parameters:
    ///   - wake: the strap-detected wake of the main sleep; nil → the first two fields are blank with a reason.
    ///   - dayStart, dayEnd: the day's window [start, end) for `hitsDay`; nil → blank with a reason.
    ///   - now: only used to say whether the first hour is over.
    public static func compute(wake: Date?, hits: [Hit], dayStart: Date?, dayEnd: Date?, now: Date? = nil) -> Summary {
        let ev: [(t: Double, n: Int)] = hits
            .map { (t: BehaviourClock.seconds($0.at), n: $0.hits > 0 ? $0.hits : 1) }
            .sorted { $0.t < $1.t }
        var first: Double?
        var hourHits: Int?
        var day: Int?
        var complete: Bool?
        var reasons: [String: String] = [:]
        if let w = wake.map({ BehaviourClock.seconds($0) }) {
            if let f = ev.first(where: { $0.t >= w }) {
                first = (f.t - w) / 60.0
            } else {
                reasons["first_after_wake_min"] = "no hit logged since waking"
            }
            var count = 0
            for e in ev where e.t >= w && e.t < w + firstHourSeconds { count += e.n }
            hourHits = count
            if let nowDate = now { complete = BehaviourClock.seconds(nowDate) >= w + firstHourSeconds }
        } else {
            let why = "no wake time: the strap-detected wake (ALG-030) is needed"
            reasons["first_after_wake_min"] = why
            reasons["hits_first_hour"] = why
        }
        if let ds = dayStart, let de = dayEnd {
            let s = BehaviourClock.seconds(ds)
            let e = BehaviourClock.seconds(de)
            var count = 0
            for h in ev where h.t >= s && h.t < e { count += h.n }
            day = count
        } else {
            reasons["hits_day"] = "no day window given"
        }
        return Summary(firstAfterWakeMin: first, hitsFirstHour: hourHits, hitsDay: day, firstHourComplete: complete,
                      reasons: reasons)
    }

    /// `vape_first_after_wake` (min), window "day".
    public static let firstAfterWakeSpec = MetricSpec(
        key: .vapeFirstAfterWake, unit: "min", group: nil, variant: "ALG-068", method: method, tier: .high,
        source: "vape log", window: "day", citation: citation, paramsVersion: "naps-excluded")
}
