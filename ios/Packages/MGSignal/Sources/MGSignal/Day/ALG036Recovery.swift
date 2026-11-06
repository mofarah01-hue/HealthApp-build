import Foundation
import MGDomain

/// ALG-036 v1 (second half) — the illness CUSUM, and the legacy "components in band" count.
/// r9h (D-RECOV-WALK-2, 2026-10-17): the "n of 5 in your range" recovery score is REMOVED — no metric is written and no screen
/// shows it; recovery is ALG-160 (Day/ALG160.swift). `readinessInBand` stays ONLY because ALG-102's driver table still reads
/// it (builder r9i replaces that with real baseline statistics, then this goes). The WHOOP-RMSSD baseline top-up
/// (`fillBaseline`, `usableImportedBaseline`) is deleted: our baseline is our own nights only (audit 6.6).
extension ALG036 {
    // MARK: Components in band

    /// The five recovery components, in the order the UX lists them. HRV is first and is required.
    public static let readinessComponents: [String] = ["hrv", "rhr", "sleep", "breathing", "temp"]

    public struct ReadinessInput: Sendable, Equatable {
        /// This morning's value, nil = not available.
        public var today: Double?
        /// The earlier values, oldest first (the last ≤ 28 are used).
        public var history: [Double?]

        public init(today: Double?, history: [Double?]) {
            self.today = today
            self.history = history
        }
    }

    public enum ReadinessStatus: String, Sendable {
        /// HRV scored and at least 3 components scored.
        case ok = "ok"
        /// HRV is there but its baseline is under 14 nights ("Learning your normal").
        case learning = "learning"
        /// HRV missing, or fewer than 3 components scored.
        case tooLittle = "too_little"
    }

    public struct ReadinessComponent: Sendable, Equatable {
        public var name: String
        public var z: Double?
        public var inBand: Bool?
        /// Why the component was not scored.
        public var reason: String?

        public init(name: String, z: Double?, inBand: Bool?, reason: String?) {
            self.name = name
            self.z = z
            self.inBand = inBand
            self.reason = reason
        }
    }

    public struct ReadinessResult: Sendable, Equatable {
        public var status: ReadinessStatus
        public var inBand: Int
        public var scored: Int
        public var components: [ReadinessComponent]
        public var hrvNights: Int

        public init(status: ReadinessStatus, inBand: Int, scored: Int, components: [ReadinessComponent], hrvNights: Int) {
            self.status = status
            self.inBand = inBand
            self.scored = scored
            self.components = components
            self.hrvNights = hrvNights
        }
    }

    /// ALG-036 v1 — how many of HRV, resting HR, sleep performance, breathing and skin temp are "in band" = robust z
    /// (ALG-075) within ±1 of the 28-day baseline, two-sided (UX-SPEC §12). Keys of `components` are
    /// `readinessComponents`; a missing key is a component that is not available.
    ///
    /// V3 (2026-10-15): `minNights` (default 14, ALG-075) and `minScored` (default 3) can be lowered by the caller for an
    /// ESTIMATE while the baseline is short; the app then labels the result as an estimate.
    public static func readinessInBand(_ components: [String: ReadinessInput], minNights: Int = ALG075.robustMinDays,
                                       minScored: Int = 3) -> ReadinessResult {
        var rows: [ReadinessComponent] = []
        var scored = 0
        var inBand = 0
        for name in readinessComponents {
            let c = components[name] ?? ReadinessInput(today: nil, history: [])
            switch ALG075.robustZ(history: c.history, x: c.today, minN: minNights) {
            case .failure(let m):
                rows.append(ReadinessComponent(name: name, z: nil, inBand: nil, reason: m.reason))
            case .success(let r):
                let ok = abs(r.z) <= 1.0
                rows.append(ReadinessComponent(name: name, z: r.z, inBand: ok, reason: nil))
                scored += 1
                if ok { inBand += 1 }
            }
        }
        let hrv = components["hrv"] ?? ReadinessInput(today: nil, history: [])
        let hrvNights = ALG075.cleaned(hrv.history, window: ALG075.robustWindowDays).count
        let status: ReadinessStatus
        if rows[0].z == nil {
            status = (DayKit.finite(hrv.today) && hrvNights < minNights) ? .learning : .tooLittle
        } else {
            status = scored >= minScored ? .ok : .tooLittle
        }
        return ReadinessResult(status: status, inBand: inBand, scored: scored, components: rows, hrvNights: hrvNights)
    }

    // MARK: Illness CUSUM

    public enum IllnessState: String, Sendable {
        case green = "green"
        case yellow = "yellow"
        case red = "red"
    }

    public struct IllnessNight: Sendable, Equatable {
        public var day: Int
        public var state: IllnessState
        public var cusum: Double?
        public var z: Double?
        public var note: String?

        public init(day: Int, state: IllnessState, cusum: Double?, z: Double?, note: String?) {
            self.day = day
            self.state = state
            self.cusum = cusum
            self.z = z
            self.note = note
        }
    }

    public static let illnessBaselineDays = 28
    public static let illnessMinBaseline = 7
    public static let illnessH = 4.0
    /// Nightly resting HR is read in whole bpm.
    public static let illnessQuantumBpm = 1.0

    /// ALG-036 v1 — one-sided Page CUSUM on nightly resting HR (OpenStrap/analytics illness_cusum.dart, archive
    /// snapshot): z against the trailing 28 CALENDAR days (median / 1.4826·MAD, SD when the MAD is 0, refused below the
    /// 1 bpm measurement step); cusum = max(0, cusum + z − k); green → yellow when cusum > h → red when yellow persists
    /// 2 nights. Ours, not from the paper: two normal nights (z < 0.5) clear the sum. A gap of more than one day resets
    /// the runs AND the sum. Reports a STATE ("elevated, sustained"), never a diagnosis. `days` ascending day numbers,
    /// `rhr` aligned (nil = no night).
    public static func illnessCUSUM(days: [Int], rhr: [Double?], baselineDays: Int = ALG036.illnessBaselineDays,
                                    k: Double = ALG075.cusumK, h: Double = ALG036.illnessH, persistDays: Int = 2,
                                    minBaseline: Int = ALG036.illnessMinBaseline, returnZ: Double = 0.5,
                                    recoverDays: Int = 2) -> [IllnessNight] {
        var out: [IllnessNight] = []
        let n = rhr.count
        var cusum = 0.0
        var yellowRun = 0
        var normalRun = 0
        var lastScored = -(1 << 20)
        for i in 0..<n {
            let night = rhr[i]
            var window: [Double] = []
            var j = i - 1
            while j >= 0 {
                if days[i] - days[j] > baselineDays { break }
                if let v = rhr[j], v.isFinite { window.append(v) }
                j -= 1
            }
            guard let r = night, r.isFinite, window.count >= minBaseline else {
                let note: String? = DayKit.finite(night) ? "need_baseline: have \(window.count) of \(minBaseline)" : nil
                out.append(IllnessNight(day: days[i], state: .green, cusum: nil, z: nil, note: note))
                continue
            }
            let hist: [Double?] = window.reversed().map { Optional($0) }
            let rz: ALG075.RobustZ
            switch ALG075.robustZ(history: hist, x: r, window: baselineDays, minN: minBaseline, quantum: illnessQuantumBpm) {
            case .failure(let m):
                out.append(IllnessNight(day: days[i], state: .green, cusum: nil, z: nil, note: m.reason))
                continue
            case .success(let v):
                rz = v
            }
            if days[i] - lastScored > 1 {
                yellowRun = 0
                normalRun = 0
                cusum = 0.0
            }
            lastScored = days[i]
            let z = rz.z
            cusum = max(0.0, cusum + (z - k))
            if z < returnZ {
                normalRun += 1
                if normalRun >= recoverDays { cusum = 0.0 }
            } else {
                normalRun = 0
            }
            let state: IllnessState
            if cusum > h {
                yellowRun += 1
                state = yellowRun >= persistDays ? .red : .yellow
            } else {
                yellowRun = 0
                state = .green
            }
            out.append(IllnessNight(day: days[i], state: state, cusum: cusum, z: z, note: nil))
        }
        return out
    }
}
