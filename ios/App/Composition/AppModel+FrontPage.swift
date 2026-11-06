import Combine
import Foundation
import MGContext
import MGDomain
import MGSignal
import MGStore

// Settings › Front page (tracker #34) and Today's "Today so far" strap values (tracker #75), 2026-10-11.
//   Front page: the order, hidden / removed cards and the dial's layers live in `AppSettings.frontPage` (kv
//   `app.settings`, saved like every other setting); every edit is `UIIntent.frontPage(_:)`, then Today rebuilds.
//   Today so far: today's stored heart rate and R18 seconds (local midnight → now), summarised with MGSignal's shared
//   kernels (TodayStrap: ALG-036 worn minutes, ALG-040 ticks). Incremental (wave 6 second pass): the first read of a
//   day, or after a launch, takes the day so far once through the ts index; every later read takes only the rows
//   stored since — by row id, so a history offload's backfill of earlier seconds is seen too — into a running
//   per-minute summary (`TodayStrap.Accumulator`, held by `TodayStrapReader` off the main actor). Bounded: ts ≥ local
//   midnight, ids above the last read, one day held in memory; a new day starts over.
// Read-only towards the strap: nothing here sends a command.

/// The page's model: `state` is what UI/Sheets/Settings/FrontPageSettingsView.swift draws; `today` caches the last read.
@MainActor
final class FrontPageModel: ObservableObject {
    @Published var state: FrontPageSettingsState?

    /// The last summary of today's strap data and the midnight it counts from.
    var today: (at: Date, from: Date, input: TodaySoFarInput)?
    /// Holds today's running summary between refreshes (created on first use).
    var reader: TodayStrapReader?
}

/// Today's strap rows, summarised as they are stored: each call reads only the rows stored since the last call.
actor TodayStrapReader {
    private let store: MGStore
    private var acc: TodayStrap.Accumulator?
    private var hrAfter: Int64 = 0
    private var r18After: Int64 = 0

    init(store: MGStore) {
        self.store = store
    }

    /// `from` = local midnight (a new value starts a new day), `to` = now; `newRows` = rows this call read.
    func summary(from: Int64, to: Int64) async throws -> (summary: TodayStrap.Summary, newRows: Int) {
        if acc?.from != from {
            acc = TodayStrap.Accumulator(from: from)
            hrAfter = 0
            r18After = 0
        }
        let hr = try await store.hrSamplesStored(afterId: hrAfter, from: from)
        let r18 = try await store.r18StepsStored(afterId: r18After, from: from)
        // Both reads succeeded: only now move the cursors (a failed read is read again next time). Two calls that
        // overlap read the same rows twice; the accumulator keeps one copy of each second.
        acc?.add(hr: hr.points, r18: r18.rows)
        hrAfter = max(hrAfter, hr.upTo)
        r18After = max(r18After, r18.upTo)
        guard let s = acc?.summary(to: to) else { throw CancellationError() }
        return (s, hr.points.count + r18.rows.count)
    }
}

extension AppModel {
    /// Today's strap data is read again after this long (the minute ticker refreshes once a minute; intents in between
    /// reuse the last read). Each read takes only the rows stored since the one before.
    static let todaySoFarMaxAge: TimeInterval = 20

    func frontPageAction(_ action: FrontPageAction) async {
        if case .open = action {
            if paths[tab]?.last != .frontPage { push(.frontPage) }
            frontPagePublish()
            return
        }
        guard !isSample else {
            showNotice(FrontPagePresenter.sampleReason)
            frontPagePublish()
            return
        }
        var layout = settings.frontPage
        switch action {
        case .open: break
        case .move(let from, let to): layout.move(from: from, to: to)
        case .setHidden(let item, let hidden): layout.setHidden(item, hidden)
        case .add(let item): layout.add(item)
        case .remove(let item): layout.remove(item)
        case .reset: layout.resetPage()
        case .setDialLayer(let layer, let shown): layout.setDialLayer(layer, shown: shown)
        case .resetDial: layout.resetDial()
        case .pickMetric(let key, let form): layout.setPick(key, form)
        case .unpickMetric(let key): layout.removePick(key)
        }
        settings.frontPage = layout
        await saveState()
        frontPagePublish()
    }

    func frontPagePublish() {
        let s = FrontPagePresenter.settings(layout: settings.frontPage, sample: isSample)
        if frontPage.state != s { frontPage.state = s }
    }

    /// Today's strap values since local midnight; nil in SAMPLE mode (the presenter says why). A failed read never
    /// fails the snapshot: the day's last numbers stay, with the failure named in the block.
    func todaySoFarInput(now: Date) async -> TodaySoFarInput? {
        guard !isSample else { return nil }
        let from = calendar.startOfDay(for: now)
        if let c = frontPage.today, c.from == from, now >= c.at, now.timeIntervalSince(c.at) < Self.todaySoFarMaxAge {
            return c.input
        }
        let reader = frontPage.reader ?? TodayStrapReader(store: services.store)
        frontPage.reader = reader
        do {
            let sum = try await reader.summary(from: Int64(from.timeIntervalSince1970),
                                               to: Int64(now.timeIntervalSince1970)).summary
            let input = TodaySoFarInput(from: from, at: now, hrSeconds: sum.hrSeconds, wornMinutes: sum.wornMinutes,
                                        averageHR: sum.averageHR, latestHR: sum.latestHR,
                                        latestHRAt: sum.latestHRTs.map { Date(timeIntervalSince1970: TimeInterval($0)) },
                                        stepTicks: sum.stepTicks, ticksMissing: sum.ticksMissing,
                                        r18Seconds: sum.r18Seconds)
            frontPage.today = (now, from, input)
            return input
        } catch {
            let why = "couldn't read today's strap data (\(error))"
            if let c = frontPage.today, c.from == from {
                var last = c.input
                last.problem = why
                return last
            }
            return TodaySoFarInput(from: from, at: now, hrSeconds: 0, wornMinutes: 0, averageHR: nil, latestHR: nil,
                                   latestHRAt: nil, stepTicks: nil, ticksMissing: nil, r18Seconds: 0, problem: why)
        }
    }

    /// Settings › Front page is on a stack.
    var frontPageOnScreen: Bool {
        paths.values.contains { $0.contains(.frontPage) }
    }
}
