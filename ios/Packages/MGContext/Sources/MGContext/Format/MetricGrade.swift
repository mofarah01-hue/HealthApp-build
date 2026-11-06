import Foundation

/// r9v (UI-SCRUB L12 / E3): the METRICS grade (docs/METRICS.md "Grades") shown beside a number or a method name, so
/// Mo sees how far to trust it. The words are the doc's, row by row; a key with no row has no grade (never guessed).
public enum MetricGrade: String, Equatable, Sendable {
    case backbone = "BACKBONE"
    case partial = "PARTIAL"
    case madeUp = "MADE-UP"
    case rawLabel = "RAW/LABEL"
    case passthrough = "PASSTHROUGH"

    /// "grade PARTIAL (M04)".
    public func line(_ row: String) -> String { "grade \(rawValue) (\(row))" }

    /// A method of the PC's HRV suite (`hrvs_<key>`): docs/METRICS.md "Status of the hrvs_* rows: PARTIAL, as M04/M05".
    /// DFA is research tier (M05).
    public static func hrvSuite(_ key: String) -> (grade: MetricGrade, row: String, note: String?)? {
        switch key {
        case "rmssd", "ln_rmssd", "sdnn", "pnn50", "mean_nn", "sd1", "sd2", "sd1_sd2", "sampen":
            return (.partial, "M04", nil)
        case "hr":
            return (.partial, "M04", nil)
        case "lf", "hf", "lf_hf", "lf_nu", "hf_nu":
            return (.partial, "M05", nil)
        case "dfa_a1":
            return (.partial, "M05", "research tier")
        case "pns_index", "sns_index":
            return (.madeUp, "M07", nil)
        default:
            return nil
        }
    }

    /// Live screen rows: heart rate now (M01), rolling RMSSD (M04), stress (M40).
    public enum Live {
        public static let heartRate = (grade: MetricGrade.rawLabel, row: "M01")
        public static let rmssd = (grade: MetricGrade.partial, row: "M04")
        public static let stress = (grade: MetricGrade.madeUp, row: "M40")
        /// Said on the RMSSD tile: the beats are wrist pulse, not ECG (METRICS M04).
        public static let rmssdCaption = "wrist pulse, not ECG · " + rmssd.grade.line(rmssd.row)
    }
}
