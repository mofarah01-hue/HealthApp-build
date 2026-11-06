import Foundation
import MGDomain

/// The extra rows under a metric's number (Explore, metric detail):
///  - T9896 (e-6) "Against your normal" beside "Against the period before", with one sentence saying what each compares;
///  - T9913 the days-with-a-value row is named for days, the data-quality share (`Metric.coverage`) has its own row;
///  - T9894 (e-5) / T9890 (e-4) a daily metric with nothing in the period shows its newest earlier value with the date and
///    the median of the last 7 days (a static metric, a lab, already shows its newest draw with its date).
/// Pure: strings from one `MetricAnalysis`; nothing is computed here that ALG-075 or the snapshot did not.
enum MetricNumberNotes {
    static func apply(_ s: PresenterSnapshot, _ a: MetricAnalysis, to number: inout MetricNumberSummary) {
        guard let latest = a.latest else { return }
        func fmt(_ v: Double) -> String {
            let (t, u) = MetricText.format(v, unit: latest.unit, name: latest.name)
            return t + (u.map { " \($0)" } ?? "")
        }
        let shown = a.median.flatMap { $0.isFinite ? $0 : nil }

        // e-6: the shown value against the band of the 28 days before (ALG-075 normalBand; today is not part of it).
        if let v = shown {
            if let lo = a.bandLow, let hi = a.bandHigh, lo.isFinite, hi.isFinite {
                let unit = MetricText.format(0, unit: latest.unit, name: latest.name).1
                let range = "\(MetricText.format(lo, unit: latest.unit, name: latest.name).0)–"
                    + "\(MetricText.format(hi, unit: latest.unit, name: latest.name).0)" + (unit.map { " \($0)" } ?? "")
                number.versusNormal = v < lo ? "below your normal (\(range))"
                    : v > hi ? "above your normal (\(range))" : "inside your normal (\(range))"
            } else {
                number.versusNormal = "not known yet — " + (a.missingReason.map(lowerFirst) ?? "your normal needs more days")
            }
        }
        if number.versusPrevious != nil || number.versusNormal != nil {
            number.compareNote = "Against the period before: this period's median next to the median of the same number "
                + "of days just before it. Against your normal: the same number next to the usual range of your last 28 "
                + "days (median ± 1.4826 × MAD, ALG-075), so one odd day does not move it."
        }

        // T9913: the data-quality share of the newest value, never called "coverage" beside the days row.
        if let c = latest.coverage, c.isFinite {
            number.cleanShare = "\(MGFormat.number(min(max(c, 0), 1) * 100, decimals: 0)) % of the data behind the newest "
                + "value was clean. A quality share of the readings, not days and not a share of your sleep."
        }

        // e-5 / e-4: nothing in the period -> the newest earlier value with its date, and the last 7 days' median.
        if shown == nil, let v = latest.value, v.isFinite, !LabDraws.isStatic(a.key) {
            number.lastSeen = "\(fmt(v)), \(MGFormat.shortDate(latest.at, calendar: s.calendar))"
            if let m = a.median7 { number.medianSevenDay = "\(fmt(m)) (\(a.median7Days) of 7 days)" }
        }
    }

    private static func lowerFirst(_ s: String) -> String {
        guard let f = s.first else { return s }
        return f.lowercased() + s.dropFirst()
    }
}
