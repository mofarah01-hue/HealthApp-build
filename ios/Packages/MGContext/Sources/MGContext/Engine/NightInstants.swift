import Foundation
import MGDomain

/// The wake and sleep-onset instants the phase clock anchors on (UX §2), one per night: the app's own row (ALG-030,
/// primary first), else an imported one (WHOOP's export before Apple Health, `ImportedHistory.rank`). W10, 2026-10-11:
/// the anchors read own rows only, so on a night the strap did not record (Mo, 01:51–05:39, in the WHOOP export) the
/// wake was "assumed 07:00" and bedtime fell back to 23:00 while the phone held the real night.
public enum NightInstants {
    public static func instants(_ rows: [(day: LocalDay, metric: Metric)]) -> [Date] {
        var byDay: [LocalDay: Metric] = [:]
        func better(_ a: Metric, than b: Metric) -> Bool {
            let ra = ImportedHistory.rank(a), rb = ImportedHistory.rank(b)
            if ra != rb { return ra < rb }                       // own (0) before WHOOP (1) before Apple (2)
            return a.primary == true && b.primary != true
        }
        for (day, m) in rows where m.value?.isFinite ?? false {
            if let held = byDay[day], !better(m, than: held) { continue }
            byDay[day] = m
        }
        return byDay.keys.sorted().compactMap { byDay[$0]?.value }.map { Date(timeIntervalSince1970: $0) }
    }
}
