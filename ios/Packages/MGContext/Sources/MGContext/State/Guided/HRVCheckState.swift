import Foundation
import MGDomain

/// HRV spot check — a guided 1–5 min reading with a countdown (UX §6 ActionGrid "HRV check (1–5 min)"; APP-025).
/// Values: RMSSD and lnRMSSD (ALG-010 v1, Task Force 1996), coherence (ALG-104 v1), artefacts flagged by ALG-004;
/// all computed by MGSignal and handed in — never computed in a view.
///
/// Opened (and repeated with another length) by `.startHRVCheck(minutes:)`; inside: `.guided(.endNow)`,
/// `.guided(.close)`. Built by WP-23's presenter.
public struct HRVCheckState: Equatable, Sendable {
    public enum Phase: String, Sendable, CaseIterable {
        /// Pick 1–5 minutes; each choice starts the reading (`.startHRVCheck(minutes:)`).
        case ready = "ready"
        /// Countdown from `startedAt` to `endsAt`, live R-R count and the quality gate.
        case measuring = "measuring"
        /// `result` holds the values, or blanks with the reason when the gate failed.
        case result = "result"
        /// Can't measure (strap off the wrist, not connected): `blankReason`.
        case blocked = "blocked"
    }

    /// The UX range: 1–5 minutes.
    public static let minuteRange: ClosedRange<Int> = 1...5

    public var sample: Bool
    public var phase: Phase
    public var minutes: Int
    public var minuteOptions: [Int]
    /// "Sit still, breathe normally, keep the strap snug."
    public var instruction: String
    public var startedAt: Date?
    public var endsAt: Date?
    /// Live HR from the strap, or blank with the reason.
    public var heartRate: DisplayValue
    /// Live R-R count: every beat so far; nil = no beats arriving.
    public var beats: Int?
    /// Beats ALG-004 flagged so far (left out of the values).
    public var flagged: Int?
    public var gate: HRVCheckGate
    public var result: HRVCheckResult?
    /// Why nothing can be measured now (phase `.blocked`), UX §13 wording.
    public var blankReason: String?

    public init(sample: Bool, phase: Phase, minutes: Int, minuteOptions: [Int], instruction: String, startedAt: Date?,
                endsAt: Date?, heartRate: DisplayValue, beats: Int?, flagged: Int?, gate: HRVCheckGate,
                result: HRVCheckResult?, blankReason: String?) {
        self.sample = sample
        self.phase = phase
        self.minutes = minutes
        self.minuteOptions = minuteOptions
        self.instruction = instruction
        self.startedAt = startedAt
        self.endsAt = endsAt
        self.heartRate = heartRate
        self.beats = beats
        self.flagged = flagged
        self.gate = gate
        self.result = result
        self.blankReason = blankReason
    }
}

/// The live quality gate: whether the beats so far are clean enough for a value.
public struct HRVCheckGate: Equatable, Sendable {
    public enum Status: String, Sendable, CaseIterable {
        /// Not enough beats yet to judge.
        case waiting = "waiting"
        case passing = "passing"
        case failing = "failing"
    }

    public var status: Status
    /// "1 of 108 beats flagged (0.9 %)".
    public var line: String
    /// The rule in words, from the presenter: "Passes with ≥ 60 s of beats and ≤ 5 % flagged (ALG-004 B)".
    public var rule: String

    public init(status: Status, line: String, rule: String) {
        self.status = status
        self.line = line
        self.rule = rule
    }

    /// Dot colour: waiting grey, passing green, failing amber.
    public var tone: StatusTone {
        switch status {
        case .waiting: return .neutral
        case .passing: return .good
        case .failing: return .warn
        }
    }
}

/// The result card. A failed gate leaves the three values blank with the reason (UX §13 "Too few clean beats").
public struct HRVCheckResult: Equatable, Sendable {
    public var passed: Bool
    /// ALG-010 RMSSD, ms.
    public var rmssd: DisplayValue
    /// ALG-010 lnRMSSD (natural log of RMSSD in ms; the Plews scale, ALG-101).
    public var lnRmssd: DisplayValue
    /// ALG-104 coherence ratio (needs ≥ 60 s and 30 beats).
    public var coherence: DisplayValue
    /// Mean HR, SDNN, beats used, minutes measured.
    public var rows: [LabeledValue]
    /// "Lower than your night median (52 ms)" — compared by the presenter; nil = no baseline yet.
    public var comparison: String?
    /// The gate's last word: "182 beats · 2 flagged (1.1 %) · passed".
    public var qualityLine: String
    /// "Saved · Explore › HRV" / "Not saved — sample data."
    public var savedNote: String?

    public init(passed: Bool, rmssd: DisplayValue, lnRmssd: DisplayValue, coherence: DisplayValue, rows: [LabeledValue],
                comparison: String?, qualityLine: String, savedNote: String?) {
        self.passed = passed
        self.rmssd = rmssd
        self.lnRmssd = lnRmssd
        self.coherence = coherence
        self.rows = rows
        self.comparison = comparison
        self.qualityLine = qualityLine
        self.savedNote = savedNote
    }
}
