import Foundation

/// Settings › Model status, and Today's "N models not running ›" line (Mo 2026-10-11: "if something isn't working I
/// should know … all models should be working"; 13:12: "give things numbers for easy call outs", "all models should be
/// enabled — info from past data we have and their outputs if possible, or waiting for first night flag, that's it").
/// Every registry metric with the model ids that write it, and every ALG id of ALGORITHM-REQUIREMENTS.md, each with a
/// stable number. Built by `ModelStatusPresenter`.
public struct ModelStatusState: Equatable, Sendable {
    public struct Row: Equatable, Sendable, Identifiable {
        public enum Kind: String, Sendable {
            /// A value today or in past data: own (phone or PC) or imported history.
            case hasOutput
            /// No output yet, and the missing input is a recorded night: none has been recorded yet.
            case waitingFirstNight
            /// T92 (2026-10-12): a day model that needs 60 worn minutes today and has fewer so far. Not a failure,
            /// not counted on Today; it fills in by itself.
            case tooEarly
            /// Built, should have produced something, has not: a real failure (the reason is the model's own).
            case notRunning
            /// Temporary: in ALGORITHM-REQUIREMENTS.md, no code yet; built in wave N.
            case notBuilt
            /// Temporary: waits for an input the app can't get yet (raw optical, ECG, raw motion, labs, R, …).
            case blocked
            /// T9852: a catalogue row whose model never produces it by design (MS-03 returns only the ratio and band;
            /// ALG-036 gives CTL / ATL / TSB). Not a failure and not counted anywhere on Today.
            case byDesign
        }

        /// "hrv_rmssd|ALG-010" or "req|ALG-043".
        public var id: String
        /// Stable call-out number ("#12"), from the generated catalogue.
        public var number: Int
        /// "#12 · hrv_rmssd · ALG-010" or "#203 · ALG-043 · Impact and falls".
        public var title: String
        /// "52 bpm · 6:58 AM · from your own data" · "41 ms · from past data · WHOOP export · Fri 9 Oct" ·
        /// "waiting for first night" · "not running — …" · "not built yet — wave 1" · "blocked — needs ECG".
        public var state: String
        public var detail: String?
        public var kind: Kind
        /// Opens the metric (registry rows only).
        public var intent: UIIntent?

        public init(id: String, number: Int, title: String, state: String, detail: String?, kind: Kind,
                    intent: UIIntent?) {
            self.id = id
            self.number = number
            self.title = title
            self.state = state
            self.detail = detail
            self.kind = kind
            self.intent = intent
        }
    }

    public struct Section: Equatable, Sendable, Identifiable {
        public var id: String
        public var title: String
        public var note: String?
        public var rows: [Row]

        public init(id: String, title: String, note: String?, rows: [Row]) {
            self.id = id
            self.title = title
            self.note = note
            self.rows = rows
        }
    }

    public var sample: Bool
    /// "180 have output · 12 waiting for first night · 2 not running · 30 not built yet · 13 blocked".
    public var summary: String
    public var sections: [Section]
    /// Model ids built but silent (not running): Today's first number.
    public var notRunningModels: Int
    /// Model ids not built yet or blocked: Today's second number ("54 not built or blocked"), apart from the first.
    public var notBuiltOrBlockedModels: Int

    public init(sample: Bool, summary: String, sections: [Section], notRunningModels: Int,
                notBuiltOrBlockedModels: Int = 0) {
        self.sample = sample
        self.summary = summary
        self.sections = sections
        self.notRunningModels = notRunningModels
        self.notBuiltOrBlockedModels = notBuiltOrBlockedModels
    }
}

/// Where a model's newest value came from (filled by the app from the store, last 60 days, imports included).
public struct ModelOutput: Equatable, Sendable {
    public var value: Double
    public var unit: String
    public var at: Date
    public var computedOnPC: Bool
    /// The import's own label ("WHOOP via Apple Health", "WHOOP export"); nil for the app's own values.
    public var importLabel: String?

    public init(value: Double, unit: String, at: Date, computedOnPC: Bool, importLabel: String?) {
        self.value = value
        self.unit = unit
        self.at = at
        self.computedOnPC = computedOnPC
        self.importLabel = importLabel
    }
}
