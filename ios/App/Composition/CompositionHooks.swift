import Foundation
import MGContext
import MGDomain

// WP-23a — the compute seam. `ComputeRunning` is what ComputeCoordinator calls; `ComputeRunners.current` (AppWiring)
// picks the implementation: WP-22's night pipeline over MGStore (`StorePipelineRunner`, PipelineWiring.swift).
// `PipelinesNotBuiltRunner` below is the fallback that computes nothing and says so — every metric then stays blank
// with its reason, never a made-up value (R6, BRIEF "No fake numbers"). WP-11 (smart wake) and WP-24 (notifications,
// background, intents) are wired directly (AppWiring.swift, AppModel+Strap.swift).
//
// WRITTEN, NOT COMPILED.

/// Why a compute ran (ARCHITECTURE §11 WP-23: on history stored, hourly, at wake, on log save).
enum ComputeReason: String, Sendable {
    case launch = "launch"
    case historyStored = "history_stored"
    case hourly = "hourly"
    case wake = "wake"
    case logSaved = "log_saved"
    case settingsChanged = "settings_changed"
    case background = "background"
    case manual = "manual"
    /// The app came to the foreground (added 2026-10-11): coalesced with the others by the 3 s debounce.
    case foreground = "foreground"
    /// The night pipeline said the night may still be going (WP-22 `NightResult.provisional`): run it again later.
    case provisional = "provisional"

    /// T134 (Mo's D-014): these only repeat what already ran, so they run only the days with new or changed inputs.
    var runsOnlyOnNewData: Bool { self == .hourly || self == .foreground }
}

/// Settings the pipelines need that are not in the store (WP-22's `PipelineSettings` is built from this).
struct ComputeSettings: Sendable, Equatable {
    /// Sleep-need override (Settings › Sleep & wake); nil = ALG-115 learns it (WP-10: no 8 h default).
    var needOverrideMinutes: Int?
    /// "Must be up by" per weekday, 1 = Sunday … 7 = Saturday; a missing weekday = blank (BRIEF default 3).
    var latestWake: [Int: TimeOfDay]
    var timeZone: TimeZone
    var profile: Profile
    /// Settings › Medications & supplements (WP-22 `PipelineSettings.medSchedules`: ALG-069 adherence, ALG-143).
    var medSchedules: [MedSchedule] = []
    /// T9973: product names for the ALG-143 compound, from the local preset file (empty without it).
    var lisdexAliases: [String] = []
    /// T140: the app is in the background and the phone is not on power; ComputeCoordinator sets it for each run.
    var backgroundOnBattery = false
    /// T9995: the app is in the background (not the power-gated `.compute` task): the run does the night pipeline of the
    /// newest day only, rests long between stages and stops at `WorkBudget.lightCPULimit`. The day pipeline and the older
    /// days wait for the foreground or the BGProcessing task.
    var lightBackground = false
}

/// What one compute did, in one line for the diagnostics log, plus what the app acts on afterwards.
struct ComputeReport: Sendable, Equatable {
    var ran: Bool
    var days: [LocalDay]
    var metricsWritten: Int
    var line: String
    /// Wake days whose night may still be going (WP-22 `NightResult.provisional`): re-run them later.
    var provisionalDays: [LocalDay] = []
    /// T134: days whose night or day pipeline threw; they are marked dirty again so the next hourly run retries them.
    var failedDays: [LocalDay] = []
    /// T140: days left out because the run hit its background CPU limit; marked dirty again like `failedDays`.
    var deferredDays: [LocalDay] = []
    /// T9995: days a light background run did the night pipeline for but not the day pipeline; the coordinator adds them
    /// to the next run that is not a light background one.
    var nightOnlyDays: [LocalDay] = []
    /// ALG-041 workout suggestions (never logged automatically): they become "Workout 17:32–18:20 — right?" questions.
    var suggestedWorkouts: [DateInterval] = []
    /// ALG-033 nap candidates read as naps: they become "Nap 14:05–14:31?" questions.
    var suggestedNaps: [DateInterval] = []
    /// Wave 2: today's non-metric outputs (movement, medication level, nicotine response, adherence, habits, social
    /// jetlag, raw step ticks); nil when today was not in the run.
    var dayExtras: DayExtrasInput?
}

/// A per-run write generation. The coordinator invalidates it before replacing a stale run; every pipeline mutation
/// checks it immediately before touching the store. Acknowledgement lets replacement wait briefly for cooperative exit
/// without allowing a frozen pipeline to block compute indefinitely.
actor ComputeWriteLease {
    private var valid = true
    private var acknowledged = false
    private var acknowledgementWaiters: [UUID: CheckedContinuation<Bool, Never>] = [:]

    func check() throws {
        guard valid else { throw CancellationError() }
    }

    func permitsWork() -> Bool { valid }

    func invalidate() { valid = false }

    func acknowledge() {
        guard !acknowledged else { return }
        acknowledged = true
        let waiters = Array(acknowledgementWaiters.values)
        acknowledgementWaiters.removeAll()
        for waiter in waiters { waiter.resume(returning: true) }
    }

    func waitForAcknowledgement(for timeout: Duration) async -> Bool {
        if acknowledged { return true }
        let id = UUID()
        return await withCheckedContinuation { continuation in
            acknowledgementWaiters[id] = continuation
            Task { [weak self] in
                try? await Task.sleep(for: timeout)
                await self?.timeOutWaiter(id)
            }
        }
    }

    private func timeOutWaiter(_ id: UUID) {
        acknowledgementWaiters.removeValue(forKey: id)?.resume(returning: false)
    }
}

/// Runs the phone pipelines (WP-22 `NightPipeline`, `DayPipeline`, `GroupPipeline`, `Baselines`) for `days` and stores
/// what they produce.
protocol ComputeRunning: Sendable {
    func run(days: [LocalDay], settings: ComputeSettings, reason: ComputeReason,
             writeLease: ComputeWriteLease) async -> ComputeReport
}

/// Default until WP-22's adapter exists.
struct PipelinesNotBuiltRunner: ComputeRunning {
    static let reason = "the WP-22 pipelines are not wired into this build yet"

    func run(days: [LocalDay], settings: ComputeSettings, reason: ComputeReason,
             writeLease: ComputeWriteLease) async -> ComputeReport {
        ComputeReport(ran: false, days: days, metricsWritten: 0,
                      line: "compute (\(reason.rawValue)) skipped: \(PipelinesNotBuiltRunner.reason)")
    }
}
