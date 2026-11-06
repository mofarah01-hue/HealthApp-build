import Foundation
import MGDomain

/// The wording and the grey / solid / blank choice of the two live tiles (0.6.0.12). Pure: the windows are judged upstream
/// (MGSignal `LiveHRV`), this only picks what to show.
enum LiveTilePresenter {
    static let rmssdMethod = "ALG-010 RMSSD · 5-min windows · 20+ clean successive intervals · 80 % covered"
    static let rmssdCitation = "Task Force of the ESC and NASPE 1996 (5-minute convention); window gates as noop and OpenStrap"

    static func windowsWord(_ n: Int) -> String { n == 1 ? "1 clean 5-min window" : "\(n) clean 5-min windows" }

    /// RMSSD tile. `blankReason` = nothing streams (the Live tab's own words).
    static func rmssd(_ reading: LiveHRVReading?, blankReason: String?, now: Date) -> LiveTileState {
        if let blankReason { return .blank(blankReason) }
        guard let r = reading else { return .blank("Needs 5 minutes of clean beats.") }
        let receipt = Receipt(computedOn: .phone, tier: .high, at: now, method: rmssdMethod, citation: rmssdCitation)
        let clean = r.cleanWindows
        let mean = clean.isEmpty ? nil : clean.compactMap(\.rmssd).reduce(0, +) / Double(clean.count)
        if r.latest.ideal, let own = r.latest.rmssd {
            if let mean {
                return LiveTileState(kind: .solid, text: MGFormat.number(mean, decimals: 0), unit: "ms",
                                     note: "average of \(windowsWord(clean.count)) today", receipt: receipt)
            }
            return LiveTileState(kind: .solid, text: MGFormat.number(own, decimals: 0), unit: "ms",
                                 note: "the last 5 minutes; the average starts when the first 5-min window finishes",
                                 receipt: receipt)
        }
        let why = r.latest.why?.text ?? "the last 5 minutes did not meet the rules"
        if let mean {
            return LiveTileState(kind: .grey, text: MGFormat.number(mean, decimals: 0), unit: "ms",
                                 reason: "Right now: " + why, note: "average of \(windowsWord(clean.count)) today", receipt: receipt)
        }
        if let own = r.latest.rmssd {
            return LiveTileState(kind: .grey, text: MGFormat.number(own, decimals: 0), unit: "ms",
                                 reason: "Provisional: " + why, note: "no clean 5-min window yet", receipt: receipt)
        }
        return LiveTileState(kind: .grey, text: "—", reason: "Nothing to show yet: " + why, note: "no clean 5-min window yet",
                             receipt: receipt)
    }

    /// Autonomic-load tile. `live` = the live metric (blank with its reason when the window or the baseline is not ready);
    /// `stored` = the newest stored day value of ALG-054, shown grey as "from stored days" when no live value exists.
    /// Returns the tile and the 0...1 level for the meter (nil unless solid).
    static func load(live: Metric?, stored: Metric?, blankReason: String?, calendar: Calendar) -> (tile: LiveTileState, level: Double?) {
        if let blankReason { return (.blank(blankReason), nil) }
        if let m = live, let z = m.value, z.isFinite {
            let basis = m.note.map { " · " + $0 } ?? ""
            return (LiveTileState(kind: .solid, text: LivePresenter.loadWord(z),
                                  note: "this 5-min window against your usual for this hour" + basis,
                                  receipt: MetricText.receipt(m)), min(1, max(0, (z + 3) / 6)))
        }
        let why = live?.note.flatMap { $0.isEmpty ? nil : $0.capitalizedFirst } ?? "Needs a clean 5-minute window."
        if let s = stored, let z = s.value, z.isFinite {
            return (LiveTileState(kind: .grey, text: LivePresenter.loadWord(z), reason: why,
                                  note: "from stored days · last stored value, " + MGFormat.shortDate(s.at, calendar: calendar),
                                  receipt: MetricText.receipt(s)), nil)
        }
        return (LiveTileState(kind: .grey, text: "—", reason: why, note: "from stored days · nothing stored yet"), nil)
    }

    /// The newest stored day value of ALG-054 (the PC / phone day compute), or nil.
    static func storedLoad(_ s: PresenterSnapshot) -> Metric? {
        s.metrics.filter {
            $0.name == MetricKey.stress.rawValue && ($0.variant ?? "") == "ALG-054" && ($0.window ?? "day") == "day"
                && ($0.value?.isFinite ?? false)
        }.max { $0.at < $1.at }
    }
}
