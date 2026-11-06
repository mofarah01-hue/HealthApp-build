import Foundation
import MGDomain

/// ALG-161 on Today: one calm "Worth noting" row, only on a morning when last night's metrics (`warning_sign`, one per code)
/// say something is past your own normal. Never a diagnosis, never red; each sentence says what the number is and is not.
/// No sign fired = no row at all (the row returns nil and `nowRows` skips it).
extension TodayPresenter {
    /// (code, plain name), in the order the signs are listed when their levels tie.
    static let warningNames: [(code: String, name: String)] = [
        ("rhr", "resting heart rate"), ("temp", "skin temperature"), ("resp", "breathing"), ("alcohol", "first hours of sleep"),
        ("rhythm", "pulse rhythm"), ("cvhr", "breathing pattern"),
    ]

    /// The signs past your normal, strongest first. Each metric's note is the sentence written by ALG-161.
    static func warningSigns(_ s: PresenterSnapshot) -> [(code: String, name: String, level: Int, metric: Metric)] {
        var out: [(code: String, name: String, level: Int, metric: Metric)] = []
        for w in warningNames {
            guard let m = s.metric(MetricKey.warningSign.rawValue, variant: w.code, window: "night"),
                  !ImportedHistory.isImported(m), let v = m.value, v.isFinite, v >= 1 else { continue }
            out.append((w.code, w.name, Int(v.rounded()), m))
        }
        return out.sorted { $0.level > $1.level }
    }

    static func warningsRow(_ s: PresenterSnapshot) -> NowRowState? {
        let signs = warningSigns(s)
        guard let first = signs.first else { return nil }
        let title = signs.count == 1 ? "Worth noting: \(first.name)" : "Worth noting: \(signs.count) things from last night"
        let lines = signs.compactMap { $0.metric.note } + ["Compared with your own normal, not a diagnosis."]
        return NowRowState(id: RowID.warnings, badge: "i", tone: .ink, title: title,
                           detail: signs.count == 1 ? first.metric.note : signs.map { $0.name }.joined(separator: ", "),
                           receipt: MetricText.receipt(first.metric), isOpen: isOpen(s, RowID.warnings),
                           expansion: NowRowExpansion(lines: lines))
    }
}
