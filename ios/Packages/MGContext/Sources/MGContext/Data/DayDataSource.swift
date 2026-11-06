import Foundation
import MGDomain

/// What presenters read (ARCHITECTURE §4.2). Implemented by the app's `StoreDayDataSource` and `SampleDayDataSource`
/// (WP-23). Signature approved by main 2026-10-11; WP-23 extends it through main.
public protocol DayDataSource: Sendable {
    /// true for `SampleDayDataSource`: every state built from it has `sample: true` and shows the SAMPLE banner.
    var isSample: Bool { get }
    /// Everything `ContextEngine.evaluate` needs at `now`.
    func contextInputs(now: Date) async throws -> ContextInputs
    /// Night metrics belong to the wake day (D13); nil = nothing stored for that day.
    func summary(for day: LocalDay) async throws -> DaySummary?
    /// Events with `at` in [from, to); removed ones excluded.
    func events(from: Date, to: Date) async throws -> [EventRecord]
    /// One metric across days, oldest first; `variant` nil = every variant.
    func metricHistory(name: String, variant: String?, from: LocalDay, to: LocalDay) async throws -> [Metric]
}
