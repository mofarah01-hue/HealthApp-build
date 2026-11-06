import Foundation
import MGDomain

/// UX-SPEC §12 verdict rules (the rule coach on the phone, ALG-076), as pure functions of their inputs. Mirrored in
/// Python (scratchpad wp23b/verdict_mirror.py) and run on the known answers there.
///
/// How they can fail, and what guards each case:
/// - A learning baseline read as a score: `learning` is checked before any count ("Learning your normal." wins).
/// - Missing HRV or < 3 inputs dressed up as a verdict: `tooLittle` → "Too little to say." with what is missing.
/// - Count out of 0…5 (bad upstream): clamped to the table, never a crash.
/// - Another read method with no published bands: no verdict word, the value itself is the headline.
public enum VerdictRules {
    /// UX §12 recovery table, now keyed by the ALG-160 band (Garmin's published bands: 1-24 Poor, 25-49 Low, 50-74 Moderate,
    /// 75-94 High, 95-100 Prime). The words are the ones the rule coach already used, so later phases read the same.
    public static func recoveryHeadline(band: RecoveryReading.Band) -> String {
        switch band {
        case .prime: return "Recovered."
        case .high: return "Recovered, mostly."
        case .moderate: return "Partly recovered."
        case .low: return "Not quite recovered."
        case .poor: return "Not recovered."
        }
    }

    public static let learningHeadline = "Learning your normal."
    public static let tooLittleHeadline = "Too little to say."
    /// Own nights of HRV before any recovery word: the width of your normal band needs a stable SD (our design choice; the
    /// published method, Plews 2012/2013, used 60 nights).
    public static let baselineNights = RecoveryReading.baselineNightsNeeded

    /// The recovery verdict from ALG-160 (UX §12). `sentence` is the rule's own sentence for learning / too little; nil for
    /// a scored verdict (the presenter adds the phase sentence).
    public static func recovery(_ r: RecoveryReading?) -> (headline: String, sentence: String?) {
        guard let r else {
            return (tooLittleHeadline, "No night scored yet — recovery needs last night's HRV.")
        }
        switch r.status {
        case .learning:
            return (learningHeadline, "\(min(r.hrvNights, baselineNights - 1)) of \(baselineNights) nights so far. "
                    + "Your normal range needs \(baselineNights) nights of your own heart-beat data to be steady.")
        case .tooLittle:
            return (tooLittleHeadline, missingSentence(r))
        case .ok:
            return (r.band.map { recoveryHeadline(band: $0) } ?? tooLittleHeadline, nil)
        }
    }

    /// The words that mark a readiness built on a baseline shorter than a full 28 nights.
    public static func shortBaselineLabel(_ r: RecoveryReading) -> String? {
        r.isEstimate ? "estimate — HRV baseline \(r.hrvNights) of \(RecoveryReading.baselineNightsFull) nights" : nil
    }

    /// "HRV in your range" / "HRV below your range" / "HRV above your range" for a scored reading.
    public static func hrvWord(_ r: RecoveryReading) -> String? {
        switch r.hrvState {
        case .some(.below): return "HRV below your range"
        case .some(.balanced): return "HRV in your range"
        case .some(.above): return "HRV above your range"
        case .none: return nil
        }
    }

    /// What is missing and why: HRV first (every recovery method needs it), else the unscored parts.
    static func missingSentence(_ r: RecoveryReading) -> String {
        if let hrv = r.components.first(where: { $0.name == "hrv" }), hrv.points == nil {
            return "No HRV for last night" + (hrv.reason.map { " — \($0)" } ?? "") + "."
        }
        let missing = r.components.filter { $0.name != "hrv" && $0.points == nil }.map { componentName($0.name) }
        if missing.isEmpty { return r.reason ?? "Too few parts were scored." }
        return "HRV is there but too little else: no \(missing.joined(separator: ", "))."
    }

    /// Plain names of the ALG-160 parts.
    public static func componentName(_ id: String) -> String {
        switch id {
        case "hrv": return "HRV"
        case "sleep": return "sleep"
        case "recovery_time": return "recovery time"
        case "load_balance": return "training load balance"
        case "stress": return "recent stress"
        default: return id
        }
    }

    /// Mo reads another G-READY method: its own bands decide (UX §12): top → "Recovered.", middle → "Partly
    /// recovered.", bottom → "Not recovered."; nil when that method has no bands.
    public static func bandHeadline(_ band: Int?) -> String? {
        guard let band else { return nil }
        switch band {
        case 2...: return "Recovered."
        case 1: return "Partly recovered."
        default: return "Not recovered."
        }
    }

    /// The one-word recovery line for later phases ("Recovery this morning: mostly").
    public static func recoveryWord(_ headline: String) -> String {
        switch headline {
        case "Recovered.": return "recovered"
        case "Recovered, mostly.": return "mostly"
        case "Partly recovered.": return "partly"
        case "Not quite recovered.": return "not quite"
        case "Not recovered.": return "not recovered"
        case learningHeadline: return "learning your normal"
        default: return "too little to say"
        }
    }

    // MARK: Dip (early afternoon, ALG-051 / 052)

    /// UX §12: inside the predicted dip → "In the dip." · starts within 60 min → "Dip ahead, probably." · none
    /// predicted → "Clear afternoon."
    public static func dipHeadline(now: Date, dip: DialSpan?) -> String {
        guard let dip, dip.end > now else { return "Clear afternoon." }
        if dip.start <= now { return "In the dip." }
        if dip.start.timeIntervalSince(now) <= 3600 { return "Dip ahead, probably." }
        return "Clear afternoon."
    }

    /// UX §12: fewer than 5 reaction tests → population curve.
    public static let reactionTestsForPersonalCurve = 5

    // MARK: Strain (late afternoon)

    /// UX §12: below p25 "Light day so far." · p25–p75 "Steady afternoon." · above p75 "Big day so far."
    public static func strainHeadline(value: Double, quartiles: Quartiles) -> String {
        if value < quartiles.p25 { return "Light day so far." }
        if value > quartiles.p75 { return "Big day so far." }
        return "Steady afternoon."
    }
}
