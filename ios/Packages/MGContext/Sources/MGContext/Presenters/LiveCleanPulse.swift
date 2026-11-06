import Foundation
import MGDomain

// P9729 (job 12, Oct 14, 2026): the cleaned PPG wave from ALG-144 (MGSignal `ALG144`, T9725) beside the raw Live pulse
// wave (T9723). MGContext does not import MGSignal, so this file holds the pure parts: which records and motion seconds
// go in (`LiveCleanWindow`), when a run is due (the Live pace limit, R-094), and every word on screen
// (`LivePresenter.cleanChip` / `cleanNote`). The app runs `ALG144.analyse(r20:motion:)` off the main thread and maps
// its last window into `LiveCleanPulse`. Research tier: the cleaned values are band-passed raw counts (decoded,
// untested), the pulse number is an estimate.

/// What the app hands the Live presenter after one ALG-144 run (or why none ran).
public struct LiveCleanPulse: Equatable, Sendable {
    /// The band-passed (0.5–4 Hz) trace of the window's chosen optical slot, oldest first; raw counts, no unit.
    public var wave: [Double]
    /// `ALG144.Output.hrEstimated.last`; nil = no number (the reason is in `reasons`).
    public var hrBpm: Double?
    /// The last window's `ALG144.State` raw value ("measured" / "reduced" / "unavailable"), or "waiting" (no run).
    public var state: String
    /// The last window's named gates ("MOTION", "LOW_SNR", …).
    public var gates: [String]
    /// The last window's plain-English reasons (one per gate, plus notes such as "motion not checked").
    public var reasons: [String]
    /// The chosen slot ("r20 b2 A"); nil when none was usable.
    public var slot: String?
    /// Strap seconds of the newest record analysed.
    public var newestTs: Int64

    public init(wave: [Double], hrBpm: Double?, state: String, gates: [String], reasons: [String], slot: String? = nil,
                newestTs: Int64) {
        self.wave = wave
        self.hrBpm = hrBpm
        self.state = state
        self.gates = gates
        self.reasons = reasons
        self.slot = slot
        self.newestTs = newestTs
    }

    public static let waitingState = "waiting"

    /// No run yet, with the reason (never a silent blank).
    public static func waiting(_ why: String) -> LiveCleanPulse {
        LiveCleanPulse(wave: [], hrBpm: nil, state: waitingState, gates: [], reasons: [why], newestTs: 0)
    }
}

/// Which live records and motion seconds ALG-144 gets, and when.
public enum LiveCleanWindow {
    /// One ALG-144 window (`ALG144.Constants.windowSeconds`). Exactly this many seconds go in: with more, ALG-144 adds
    /// a "shorter than one window" blank at the end, and the chip (the last window) would always read blank.
    public static let seconds = 8

    public struct Window: Equatable, Sendable {
        public var records: [R20Record]
        public var motion: [MotionSecond]
        public var newestTs: Int64
    }

    public enum Assembly: Equatable, Sendable {
        case ready(Window)
        case waiting(String)
    }

    /// The newest `seconds` records of the trailing unbroken run (each strap second = the last + 1, same block count,
    /// same samples per record: ALG-144's own continuity rule), and the motion seconds inside that span.
    public static func assemble(records: [R20Record], motion: [MotionSecond]) -> Assembly {
        let sorted = records.sorted { $0.ts < $1.ts }
        guard let newest = sorted.last else { return .waiting("no raw optical records yet") }
        func n(_ r: R20Record) -> Int { r.blocks.map(\.slotA.count).max() ?? 0 }
        var run = [newest]
        for r in sorted.dropLast().reversed() {
            guard run.count < seconds, let first = run.first, r.ts + 1 == first.ts, n(r) == n(first),
                  r.blocks.count == first.blocks.count else { break }
            run.insert(r, at: 0)
        }
        guard run.count == seconds else {
            return .waiting("\(run.count) s of unbroken raw optical so far; ALG-144 needs \(seconds) s")
        }
        let start = run[0].ts, end = newest.ts
        let m = motion.filter { $0.ts >= start && $0.ts <= end }.sorted { $0.ts < $1.ts }
        return .ready(Window(records: run, motion: m, newestTs: newest.ts))
    }

    /// The Live pace limit (R-094): a run only when a newer record arrived than the last run used, and never while one
    /// is still running. Records come once a second, so this is at most one run a second, on the existing UI tick.
    public static func shouldRun(newestTs: Int64?, lastRunTs: Int64?, inFlight: Bool) -> Bool {
        guard let newestTs, !inFlight else { return false }
        return lastRunTs.map { newestTs > $0 } ?? true
    }
}

extension LivePresenter {
    /// "ALG-144 · measured" / "ALG-144 · reduced · MOTION" / "ALG-144 · blank · LOW_SNR, MOTION" / "ALG-144 · waiting".
    static func cleanChip(_ c: LiveCleanPulse) -> StreamChipState {
        let gates = c.gates.isEmpty ? "" : " · " + c.gates.joined(separator: ", ")
        switch c.state {
        case "measured": return StreamChipState(text: "ALG-144 · measured" + gates, tone: c.gates.isEmpty ? .good : .warn)
        case "reduced": return StreamChipState(text: "ALG-144 · reduced" + gates, tone: .warn)
        case "unavailable": return StreamChipState(text: "ALG-144 · blank" + gates, tone: .bad)
        default: return StreamChipState(text: "ALG-144 · waiting", tone: .neutral)
        }
    }

    static let motionNotChecked = "motion not checked"

    /// The line under the cleaned wave: the pulse estimate, or why there is none.
    static func cleanNote(_ c: LiveCleanPulse) -> String {
        if c.state == LiveCleanPulse.waitingState {
            return "No cleaned wave yet: \(c.reasons.first ?? "no run yet")."
        }
        var out: String
        if let bpm = c.hrBpm, bpm.isFinite, c.state != "unavailable" {
            out = "Pulse from the cleaned wave: \(MGFormat.number(bpm, decimals: 0)) bpm (estimate, research, decoded, untested)."
            let gated = c.reasons.filter { r in c.gates.contains { r.hasPrefix($0 + ":") } }
            if !gated.isEmpty { out += " " + gated.joined(separator: "; ") + "." }
        } else {
            let why = c.reasons.filter { !$0.contains(motionNotChecked) }
            out = "No pulse from the cleaned wave: "
                + (why.isEmpty ? "ALG-144 gave no reason (report this)" : why.joined(separator: "; ")) + "."
        }
        if c.reasons.contains(where: { $0.contains(motionNotChecked) }) {
            out += " Motion not checked: turn on Raw motion to let MOTION gate it."
        }
        return out
    }
}
