import Foundation
import MGContext
import MGDomain

// R7 / T23 (Mo: "the app is very choppy, loads slow, lags on scrolling"): every presenter is a pure function of one
// `PresenterSnapshot` (no clock, no I/O), yet `AppModel.present` ran all of them, and compared each result with the
// last one, on the main actor after every refresh (every minute, every data change). They now run here, on a background
// task; the main actor only reads which optional screens are open (`ScreenPlan`) and assigns the results.
//
// WRITTEN, NOT COMPILED. Nothing in a state changes: the same presenters get the same snapshot.

/// What `AppModel.present` reads on the main actor before the presenters run elsewhere.
struct ScreenPlan: Sendable {
    var detail: Bool
    var group: Bool
    var compare: Bool
    var workout: Bool
    var modelStatus: Bool
    var ages: Bool
    /// The Night screen for a day other than the wake day (`.openNight(day)`); nil = the wake day's.
    var nightDay: LocalDay?
    var nightMetrics: [Metric]
    var nightSeries: [Series]
    /// The first pass at launch: Today only.
    var light: Bool
    /// R8e (§0.C-2): the screens that only matter while they are open (or stale) are built when asked. Tonight and the
    /// wake-day Night are always built once: Today's dial reads both.
    var log = true
    var explore = true
    var matrix = true
    var settings = true
    var strapSync = true
}

/// The screens one snapshot produces, as plain values.
struct PresentedScreens: Sendable {
    struct Rest: Sendable {
        var tonight: TonightState
        var night: NightState
        /// nil = not built this pass (its screen is closed): the model keeps the last one.
        var log: LogState?
        var explore: ExploreState?
        var metricDetail: MetricDetailState?
        var group: GroupState?
        var compare: CompareState?
        var matrix: MatrixState?
        var settings: SettingsState?
        var strapSync: StrapSyncState?
        var workoutDetail: WorkoutDetailState?
        var modelStatus: ModelStatusState?
        var ages: InfoScreenState?
    }

    var today: TodayState
    var quiet: Bool
    /// nil on the light pass.
    var rest: Rest?
}

enum ScreenBuilder {
    static func build(_ s: PresenterSnapshot, plan: ScreenPlan) -> PresentedScreens {
        let quiet = s.context.phase == .night || s.context.phase == .lateNight
        // The light pass has no Model status data yet: the line under the verdict (a count of models) waits for the full
        // pass instead of showing a wrong number.
        if plan.light {
            var today = TodayPresenter.make(s)
            today.modelStatus = nil
            return PresentedScreens(today: today, quiet: quiet, rest: nil)
        }
        // R8e: Tonight and the wake-day Night are built once and handed to Today's dial (it used to build them again).
        let tonight = TonightPresenter.make(s)
        let night: NightState
        let nightForToday: NightState
        if let day = plan.nightDay {
            var nightSnapshot = s
            nightSnapshot.day = day
            nightSnapshot.metrics = plan.nightMetrics
            nightSnapshot.series = plan.nightSeries
            night = NightPresenter.make(nightSnapshot)
            nightForToday = NightPresenter.make(s)
        } else {
            night = NightPresenter.make(s)
            nightForToday = night
        }
        let today = TodayPresenter.make(s, night: nightForToday, tonight: tonight)
        let rest = PresentedScreens.Rest(
            tonight: tonight,
            night: night,
            log: plan.log ? LogPresenter.make(s) : nil,
            explore: plan.explore ? ExplorePresenter.make(s) : nil,
            metricDetail: plan.detail ? MetricDetailPresenter.make(s) : nil,
            group: plan.group ? GroupPresenter.make(s) : nil,
            compare: plan.compare ? ComparePresenter.make(s) : nil,
            matrix: plan.matrix ? MatrixPresenter.make(s) : nil,
            settings: plan.settings ? SettingsPresenter.make(s) : nil,
            strapSync: plan.strapSync ? StrapSyncPresenter.make(s) : nil,
            workoutDetail: plan.workout ? WorkoutDetailPresenter.make(s) : nil,
            modelStatus: plan.modelStatus ? ModelStatusPresenter.make(s) : nil,
            ages: plan.ages ? AgesPresenter.make(s) : nil)
        return PresentedScreens(today: today, quiet: quiet, rest: rest)
    }
}
