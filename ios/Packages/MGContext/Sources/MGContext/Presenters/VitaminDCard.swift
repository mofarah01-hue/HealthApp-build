import Foundation
import MGDomain

// Today's "Sun vitamin D (estimate)" card (wave 12, tracker #82; app/docs/features/VITAMIN-D.md section 5). Hidden by
// default (FrontPageItem.hiddenByDefault); Mo shows it in Settings › Front page. The number is the PC's
// (pc.vitamin-d@1: Apple's Time in Daylight × the UV index, Holick's rule); this card only words it — always as an
// estimate and an oral-dose equivalent, never a blood level — or says why it is blank, in the PC's own words.
extension FrontPagePresenter {
    static let vitaminDTitle = "Sun vitamin D (estimate)"
    /// The literature's "standard vitamin D dose" (Webb and Engelsen 2006): the UV equivalent of 1,000 IU by mouth.
    static let standardDoseIU = 1000.0

    /// T15: the newest lab vitamin D (Health vault draw) beside the estimate, with unit, draw date and source; nil when
    /// no lab exists. A measured blood level, not the estimate.
    static func vitaminDLabLine(_ s: PresenterSnapshot) -> String? {
        guard let lab = AgesPresenter.newest(s, MetricKey.labVitaminD.rawValue), let v = lab.value, v.isFinite else { return nil }
        let (text, unit) = MetricText.format(v, unit: lab.unit, name: lab.name)
        let year = s.calendar.component(.year, from: lab.at)
        return "lab \(text)\(unit.map { " \($0)" } ?? "") drawn \(AgesPresenter.dayMonth(lab.at, s.calendar)) \(year), "
            + "\(lab.source) (a measured blood level)"
    }

    static func vitaminDRow(_ s: PresenterSnapshot) -> NowRowState {
        let open = ActionState(id: "vitaminD", title: "Explore ›",
                               intent: .openMetric(key: MetricKey.vitaminDIuEst.rawValue, variant: nil))
        let daylight = s.number(.daylightMin).map { "\(MGFormat.duration(minutes: Int($0.rounded(.down)))) in daylight" }
        guard let m = s.metric(.vitaminDIuEst) else {
            let why = daylight.map { "\($0) — the PC hasn't sent its estimate for today yet" }
                ?? "No Time in Daylight from Apple Health for today yet — the Shortcut “Health → HealthApp” brings it "
                + "to the PC, which works out the estimate"
            return NowRowState(id: "vitaminD", badge: "D", tone: .body, title: vitaminDTitle, detail: why, receipt: nil,
                               button: open)
        }
        guard let v = m.value, v.isFinite else {
            let note = (m.note ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return NowRowState(id: "vitaminD", badge: "D", tone: .body, title: vitaminDTitle,
                               detail: ([note.isEmpty ? PresenterKit.noReason : note.capitalizedFirst]
                                        + [vitaminDLabLine(s)].compactMap { $0 }).joined(separator: " · "),
                               receipt: MetricText.receipt(m), button: open)
        }
        let iu = Int(v.rounded())
        var detail = [String]()
        if let daylight { detail.append(daylight) }
        detail.append("\(MGFormat.number(v / standardDoseIU * 100, decimals: 0)) % of the 1,000 IU standard dose")
        detail.append("oral-dose equivalent, not a blood level")
        if let lab = vitaminDLabLine(s) { detail.append(lab) }
        return NowRowState(id: "vitaminD", badge: "D", tone: .body,
                           title: "Sun vitamin D: about \(MGFormat.grouped(iu)) IU (estimate)",
                           detail: detail.joined(separator: " · "), receipt: MetricText.receipt(m), button: open)
    }
}
