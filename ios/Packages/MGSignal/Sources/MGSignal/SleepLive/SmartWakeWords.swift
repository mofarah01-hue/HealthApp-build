import Foundation

/// The morning words for a smart-wake night (Python reference: `morning_text` in ref/sleep_live.py; goldens
/// ALG-035.json "words: …"). WP-06: the result goes in the Just-woke "Smart wake result" Now row (never a Moment);
/// UX-SPEC 5.1: the first morning check-in question is about this wake; main (2026-10-11): say plainly when the night
/// ran heart-only; D8: the strap battery cost of the overnight stream.
public struct SmartWakeWords: Equatable, Sendable {
    /// Now row title; nil when there was no plan (the row is not shown; `detail` carries the no-plan reason).
    public var title: String?
    public var detail: String?
    /// "Heart-only staging: …" when no motion data arrived all night.
    public var note: String?
    /// "Strap battery 81 % → 64 % overnight (…)" when both readings exist.
    public var battery: String?
    public var checkinQuestion: String

    public init(title: String?, detail: String?, note: String?, battery: String?, checkinQuestion: String) {
        self.title = title
        self.detail = detail
        self.note = note
        self.battery = battery
        self.checkinQuestion = checkinQuestion
    }

    /// Why live data stopped: the BLE link dropped, or it stayed up and the strap sent nothing (off the wrist).
    public enum Cause: String, Sendable, Codable {
        case disconnected = "disconnected"
        case noData = "no_data"
    }

    static let stageWords: [SleepLiveStage: String] = [.light: "light sleep", .wake: "already stirring",
                                                       .deep: "deep sleep", .rem: "REM sleep",
                                                       .asleep: "asleep (stage unknown)"]

    /// Builds the words. `utcOffsetSeconds` = the local offset at the wake (TimeZone.secondsFromGMT(for:)).
    public static func make(_ o: SmartWakeOutcome, utcOffsetSeconds: Int, cause: Cause = .disconnected,
                            batteryAtBed: Double? = nil, batteryAtWake: Double? = nil) -> SmartWakeWords {
        if o.kind == .noPlan {
            return SmartWakeWords(title: nil, detail: o.noPlanReason, note: nil, battery: nil,
                                  checkinQuestion: "How did you wake up?")
        }
        let t: (Int64) -> String = { hhmm($0, utcOffsetSeconds) }
        let L = o.windowEnd ?? (o.at ?? 0)
        let ws = o.windowStart ?? L
        var win = "window \(t(ws))\u{2013}\(t(L))"
        if o.narrowed {
            win += o.narrowReason == .shortNight ? " (narrowed: short night)" : " (narrowed: late bedtime)"
        }
        let title: String
        let detail: String
        let question: String
        if o.kind == .smart, let at = o.at {
            let before = (L - at) / 60
            let stage = o.stageAtWake ?? .light
            title = "Smart wake got you up at \(t(at))"
            detail = "\(stageWords[stage] ?? "asleep") \u{00B7} \(before) min before \(t(L)) \u{00B7} \(win)"
            question = stage == .light
                ? "Smart wake got you up at \(t(at)), in light sleep. How do you feel?"
                : "Smart wake got you up at \(t(at)), already stirring. How do you feel?"
        } else {
            switch o.reason {
            case .couldntWatch?:
                if let end = o.dataEndedAt {
                    title = cause == .disconnected
                        ? "Smart wake couldn't watch \u{2014} strap disconnected at \(t(end))"
                        : "Smart wake couldn't watch \u{2014} no strap data after \(t(end))"
                } else {
                    title = "Smart wake couldn't watch \u{2014} no strap data last night"
                }
                detail = "the \(t(L)) backstop rang \u{00B7} \(win)"
            case .watchedPartly?:
                title = "Smart wake rang at \(t(L)) \u{2014} watched \(Int(o.watchedMinutes ?? 0)) of "
                    + "\(Int(o.windowMinutes ?? 0)) min"
                detail = "no light sleep while it could see \u{00B7} \(win)"
            default:
                let w = o.stageAtWake.flatMap { stageWords[$0] } ?? "asleep"
                title = "Smart wake rang at \(t(L)) \u{2014} no light sleep in the window"
                detail = "\(w) at \(t(L)) \u{00B7} \(win)"
            }
            question = "Smart wake rang at \(t(L)), the latest time you set. How do you feel?"
        }
        let note = o.cardiacOnly ? "Heart-only staging: the strap sent no motion data last night." : nil
        var battery: String?
        if let b = batteryAtBed, let w = batteryAtWake {
            battery = "Strap battery \(String(format: "%.0f", b)) % \u{2192} \(String(format: "%.0f", w)) % overnight "
                + "(live stream on for smart wake)"
        }
        return SmartWakeWords(title: title, detail: detail, note: note, battery: battery, checkinQuestion: question)
    }

    /// Local 24-h time, minutes rounded down (a time shown is when it happened).
    static func hhmm(_ t: Int64, _ offset: Int) -> String {
        var s = (t + Int64(offset)) % 86400
        if s < 0 { s += 86400 }
        let h = s / 3600
        let m = (s % 3600) / 60
        return (h < 10 ? "0" : "") + "\(h):" + (m < 10 ? "0" : "") + "\(m)"
    }
}

/// Agreement of two hypnograms on one clock (ARCHITECTURE 4.11 "Check": the live stager replayed in the morning vs
/// the retrospective ALG-120; the number goes in the night's G-STAGE notes). Python reference: `agreement`.
public struct SleepLiveAgreement: Equatable, Sendable {
    /// Epochs where both have W/L/D/R (S and "." are skipped).
    public var n: Int
    public var agreement: Double
    /// Cohen's kappa; Missing when chance agreement is 1 (one class only).
    public var kappa: Computed<Double>
    /// Agreement on {L, W} vs {D, R} — what the fire rule acts on.
    public var binaryAgreement: Double
    /// Rows = a, columns = b, order W L D R.
    public var confusion: [[Int]]

    public init(n: Int, agreement: Double, kappa: Computed<Double>, binaryAgreement: Double, confusion: [[Int]]) {
        self.n = n
        self.agreement = agreement
        self.kappa = kappa
        self.binaryAgreement = binaryAgreement
        self.confusion = confusion
    }

    static let order: [SleepLiveStage] = [.wake, .light, .deep, .rem]

    public static func compare(epoch0A: Int64, _ a: [SleepLiveStage], epoch0B: Int64,
                               _ b: [SleepLiveStage]) -> Computed<SleepLiveAgreement> {
        let step = SleepLiveParams.epochSeconds
        guard epoch0A % step == 0, epoch0B % step == 0 else {
            return .missing("hypnograms must start on a 30-s epoch boundary")
        }
        let lo = max(epoch0A, epoch0B)
        let hi = min(epoch0A + Int64(a.count) * step, epoch0B + Int64(b.count) * step)
        var conf = Array(repeating: Array(repeating: 0, count: 4), count: 4)
        var n = 0
        var agree = 0
        var binAgree = 0
        var t = lo
        while t < hi {
            let x = a[Int((t - epoch0A) / step)]
            let y = b[Int((t - epoch0B) / step)]
            t += step
            guard let i = order.firstIndex(of: x), let j = order.firstIndex(of: y) else { continue }
            n += 1
            conf[i][j] += 1
            if x == y { agree += 1 }
            let lw: (SleepLiveStage) -> Bool = { $0 == .light || $0 == .wake }
            if lw(x) == lw(y) { binAgree += 1 }
        }
        guard n > 0 else { return .missing("no epoch where both hypnograms have a stage") }
        let po = Double(agree) / Double(n)
        var pe = 0.0
        for i in 0..<4 {
            var row = 0
            var col = 0
            for k in 0..<4 {
                row += conf[i][k]
                col += conf[k][i]
            }
            pe += Double(row * col)
        }
        pe /= Double(n * n)
        let kappa: Computed<Double> = pe < 1.0 ? .success((po - pe) / (1.0 - pe))
            : .missing("one class only: kappa undefined")
        return .success(SleepLiveAgreement(n: n, agreement: po, kappa: kappa, binaryAgreement: Double(binAgree) / Double(n),
                                           confusion: conf))
    }

    /// From hypnogram strings (W L D R S .); unknown characters count as no data.
    public static func compare(epoch0A: Int64, hypnogramA: String, epoch0B: Int64,
                               hypnogramB: String) -> Computed<SleepLiveAgreement> {
        let f: (String) -> [SleepLiveStage] = { $0.map { SleepLiveStage(rawValue: String($0)) ?? .noData } }
        return compare(epoch0A: epoch0A, f(hypnogramA), epoch0B: epoch0B, f(hypnogramB))
    }
}
