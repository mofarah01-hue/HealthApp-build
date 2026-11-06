import Foundation
import MGDomain

/// The wording and numbers of the RMSSD / autonomic-load explainer cards (0.6.0.12). Sources, as in
/// `WHOOP4-REDIR-LED-ALGORITHMS-2026-11-05.md` section 4 and the ChatGPT-B report: nightly lnRMSSD differs night to night by about
/// 4 to 6 % (Bellenger 2021, WHOOP 2.0 validation); a weekly mean beats a single day (Plews 2014); a meaningful change is about
/// 0.5 x the baseline's own SD, stronger over 2 or more nights (Plews 2012/2014, Buchheit 2014).
enum HRVExplainerPresenter {
    /// Nights of baseline: at least `baseMin`, at most `baseMax` (Mo's brief: 14-28).
    static let baseMin = 14
    static let baseMax = 28
    static let weekNights = 7
    static let weekMinNights = 3
    static let swcK = 0.5

    static let footnote = "Plews et al., Int J Sports Physiol Perform 2014 (doi 10.1123/IJSPP.2013-0455); Buchheit, Front Physiol 2014; "
        + "Bellenger et al., Sensors 2021, 21:3571. Wrist pulse, not ECG; not a medical reading."

    /// The 7-night mean and the normal band, from nightly lnRMSSD values (oldest first, the last = last night, nil = no value).
    struct Week: Equatable {
        var mean7Ln: Double?
        var nights7: Int
        var baselineNights: Int
        var muLn: Double?
        var sdLn: Double?
        var standing: HRVExplainerState.Standing
    }

    static func week(_ lnNights: [Double?]) -> Week {
        let last7 = lnNights.suffix(weekNights).compactMap { $0 }.filter { $0.isFinite }
        let base = lnNights.dropLast().suffix(baseMax).compactMap { $0 }.filter { $0.isFinite }
        var w = Week(mean7Ln: nil, nights7: last7.count, baselineNights: base.count, muLn: nil, sdLn: nil, standing: .learning)
        if last7.count >= weekMinNights { w.mean7Ln = last7.reduce(0, +) / Double(last7.count) }
        guard base.count >= baseMin else { return w }
        let mu = base.reduce(0, +) / Double(base.count)
        let sd = (base.reduce(0) { $0 + ($1 - mu) * ($1 - mu) } / Double(base.count - 1)).squareRoot()
        guard sd > 0 else { return w }
        w.muLn = mu
        w.sdLn = sd
        if let m = w.mean7Ln {
            let d = (m - mu) / (swcK * sd)
            w.standing = d < -1 ? .below : (d > 1 ? .above : .inside)
        }
        return w
    }

    static func make(_ kind: HRVExplainerState.Kind, reading: LiveHRVReading?, lnNights: [Double?]) -> HRVExplainerState {
        let wk = week(lnNights)
        var points: [HRVExplainerState.Point] = []
        for w in reading?.today ?? [] {
            points.append(.init(end: w.end, rmssd: w.rmssd, clean: w.ideal, why: w.ideal ? nil : w.why?.text))
        }
        let cleanCount = points.filter(\.clean).count
        let chartNote: String
        if points.isEmpty {
            chartNote = "No finished 5-minute window yet today. A window is judged when its 5 minutes end."
        } else {
            chartNote = "\(points.count) finished 5-minute window\(points.count == 1 ? "" : "s") today, \(cleanCount) clean. "
                + "Solid = met every rule (20+ clean beats, 80 % covered, no gap over 3 s); faded = did not, and is not in the average."
        }

        func ms(_ ln: Double) -> Int { Int(exp(ln).rounded()) }
        let weekLine: String
        if let m = wk.mean7Ln {
            weekLine = "7-night average: RMSSD about \(ms(m)) ms (ln \(MGFormat.number(m, decimals: 2))), from \(wk.nights7) of the last \(weekNights) nights."
        } else {
            weekLine = "7-night average: needs \(weekMinNights) nights of overnight HRV in the last \(weekNights) (have \(wk.nights7))."
        }
        var bandLine: String
        var bandMs: [Double]?
        if let mu = wk.muLn, let sd = wk.sdLn {
            let lo = exp(mu - swcK * sd)
            let hi = exp(mu + swcK * sd)
            bandMs = [lo, hi]
            bandLine = "Your normal: \(Int(lo.rounded())) to \(Int(hi.rounded())) ms (your mean ± 0.5 SD over the last \(wk.baselineNights) nights)."
            switch wk.standing {
            case .below: bandLine += " Your 7-night average is below it."
            case .above: bandLine += " Your 7-night average is above it."
            case .inside: bandLine += " Your 7-night average is inside it."
            case .learning: break
            }
        } else {
            bandLine = "Learning your normal: \(wk.baselineNights) of \(baseMin) nights so far."
        }

        let title: String
        let what: String
        let howOften: String
        switch kind {
        case .rmssd:
            title = "RMSSD (5 min)"
            what = "RMSSD is how much the time between one heartbeat and the next changes from beat to beat, in milliseconds. "
                + "Higher usually means a more relaxed, recovered body. It is worked out from your wrist pulse, so it is a close "
                + "cousin of the ECG measure, not the same thing."
            howOften = "Minute to minute it moves with breathing, posture, talking, caffeine and movement, and most of that is noise, "
                + "so one reading means little. The tile shows the average of today's clean 5-minute windows. The number that "
                + "tracks your recovery is the overnight one, once a night; nights normally differ by about 4 to 6 %."
        case .load:
            title = "Autonomic load"
            what = "Autonomic load compares your pulse and RMSSD over the last clean 5 minutes with your own usual for this hour of "
                + "the day. \"About usual\" is close to your normal; \"higher than usual\" is a faster pulse and less beat-to-beat "
                + "variation than you normally have at this hour. It can come from exercise, caffeine, stress, illness or little "
                + "sleep. It is a description, not a stress test."
            howOften = "It is recalculated whenever the last 5 minutes are clean, so it can move every few minutes, and it uses the same "
                + "windows as the chart below. With no clean window it shows your last stored value in grey. Hour-by-hour "
                + "baselines build over days."
        }
        let change = "A change that matters is about half of your own normal spread (0.5 × the SD of your baseline nights), and it "
            + "counts more when it lasts 2 or more nights or when the 7-night average moves. One night shifting 2 to 3 % is noise: "
            + "the measurement itself varies by about that much."
        return HRVExplainerState(kind: kind, title: title, what: what, howOften: howOften, points: points, chartNote: chartNote,
                                 weekLine: weekLine, bandLine: bandLine, standing: wk.standing, bandMs: bandMs, changeLine: change,
                                 footnote: footnote)
    }
}
