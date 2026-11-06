import Foundation
import MGContext
import MGDomain
import MGHealth
import MGStore
import UIKit

// WP-23a — every `UIIntent` (UX §10) handled in ONE exhaustive switch (no `default:`), so the compiler proves no case is
// missed. Writes are refused in SAMPLE mode with the Log's sentence (ARCHITECTURE §4.12). Toggle rule (BRIEF WP-12
// row): a ToggleState's intent already carries the NEW value; it is applied as given.
//
// WRITTEN, NOT COMPILED.

extension AppModel {
    /// What the views call (`\.mgSend`, `send:` closures). `nonisolated` so it converts to the views' plain
    /// `(UIIntent) -> Void`; the work hops to the main actor.
    nonisolated func send(_ intent: UIIntent) {
        Task { @MainActor [weak self] in await self?.handle(intent) }
    }

    /// A sheet went away (Done, swipe down). R8e (X4): only the sheets that can change state ask the PC for its sync status
    /// and rebuild everything; closing a receipt or Tonight changes nothing.
    func sheetDismissed(_ closed: RootSheet) async {
        switch closed {
        case .strapSync, .pairing, .strapConsent:
            syncStatus = await services.sync.refreshStatus()
            await refresh()
        case .tonight, .receipt:
            break
        case .processNow:
            UIApplication.shared.isIdleTimerDisabled = false     // screen may sleep again; a run in progress carries on
        }
    }

    /// R8e: how much work an intent needs after it ran (§0.C-1).
    enum AfterIntent {
        /// Nothing the presenters show changed (tab, a sheet opening): the views that open build what they need.
        case nothing
        /// Only view state changed (open rows, expanded groups): the same snapshot, presented again. No database reads.
        case rerender
        /// Data or settings changed: the whole snapshot is read again.
        case full
    }

    /// R8e: pull-to-refresh on Today waits for the sync and the rebuild (the spinner used to end at once because `send`
    /// only starts a Task). Gives up waiting after 20 s; the work itself carries on.
    func pullRefresh() async {
        let gate = PullGate()
        Task { @MainActor [weak self] in
            await self?.handle(.refresh)
            gate.done = true
        }
        var waited = 0.0
        while !gate.done, waited < 20 {
            try? await Task.sleep(for: .milliseconds(250))
            waited += 0.25
        }
    }

    /// A cover went away: whatever ran in it is over (nothing half-measured is kept).
    func coverDismissed() async {
        breatheSession = nil
        hrvSession = nil
        UIApplication.shared.isIdleTimerDisabled = false
        applyRealtime()
        await refresh()
    }

    func handle(_ intent: UIIntent) async {
        var after = AfterIntent.full
        switch intent {
        // MARK: Navigation (UX §3.1)
        case .selectTab(let t):
            tab = t
            after = .nothing
        case .scrollToTop(let t):
            reTap(t)
            after = .nothing
        case .openSettings:
            pushOrPop(.settings)    // R8e (L15): on the tab you are in, so Back comes to it
        case .openPreferences:
            pushOrPop(.preferences) // T10022: the "M" on Today; the first row of Settings
        case .openModelStatus:
            push(.modelStatus)
            await refresh()
        case .openAges:
            push(.ages)
            await refresh()
        case .openStrapSync:
            // Nov 6 2026 (one settings page): the strap chip, the sync badge and the notifications open Settings, scrolled to
            // its Device section, instead of a second screen.
            SettingsScrollModel.shared.target = "device"
            pushOrPop(.settings)
            after = .nothing
            await askHealthReadIfNeeded()
        case .processSleepNow:
            sheet = .processNow
            after = .nothing
            Task { @MainActor [weak self] in await self?.processSleepNow() }
        case .openTonight:
            sheet = .tonight
            after = .nothing
        case .openNight(let day):
            nightDay = day
            push(.night(day))
        case .openWorkout(let id):
            workoutRequested = true
            workoutId = id
            push(.workout(id))
        case .openMetric(let key, let variant):
            detailKey = key
            detailVariant = variant
            push(.metric(key: key, variant: variant))
        case .openGroup(let id):
            groupId = id
            push(.group(id))
        case .openCompare(let key):
            compareFirst = key
            compareSecond = nil
            compareLag = 0
            push(.compare(key))
        case .openMatrix:
            matrixCache = nil          // WP-22: recompute when the Matrix opens
            push(.matrix)
        case .openMonthGrid:
            toggle(LogPresenter.monthGridRowID)
            after = .rerender
        case .openLogItem(let item):
            openLogRow(item)
            after = .rerender
        case .openLive:
            tab = .live
            after = .nothing

        // MARK: In-place expansion (one open per list is the presenter's rule)
        case .toggleRow(let id):
            toggle(id)
            after = .rerender
        case .toggleMethods(let groupId):
            if expandedGroups.contains(groupId) { expandedGroups.remove(groupId) } else { expandedGroups.insert(groupId) }
            after = .rerender

        // MARK: Logging (UX §7)
        case .quickLog(let action):
            await quickLog(action)
        case .confirmDetected(let id, let accepted):
            await confirmDetected(id: id, accepted: accepted)
        case .addEntry(let item):
            openLogRow(item)
            after = .rerender
        case .editEntry(let id):
            await editEntry(id)
        case .removeEntry(let id):
            await removeEntry(id)
        case .undoRemove(let id):
            await undoRemove(id)
        case .shiftHappenedAt(let id, let minutes):
            await shiftHappenedAt(id, minutes: minutes)
        case .undoLastLog:
            await undoLastLog()
        case .saveEvent(let event):
            await saveEvent(event)
        case .startReactionTest:
            cover = .reactionTest              // UI/Guided/ReactionTestView (ALG-050 PVT-B); saves via .saveEvent

        // MARK: Peeks (UX §5)
        case .answerPeek(let kind, let answer):
            await answerPeek(kind, answer: answer)
        case .deferPeek(let kind):
            await deferPeek(kind)
        case .openDeferredQuestion:
            await reopenDeferredQuestion()
        case .editPeekTimes(let kind):
            editPeekTimes(kind)

        // MARK: Methods (UX §11) — drop hides, never deletes (APP-117)
        case .selectMethod(let groupId, let variant):
            await markMethod(groupId, variant, .read)
        case .markMethod(let groupId, let variant, let mark):
            switch mark {
            case .keep: await markMethod(groupId, variant, .keep)
            case .drop: await markMethod(groupId, variant, .drop)
            case .restore: await markMethod(groupId, variant, .keep)   // un-hide = kept
            }
        case .showDropped(let groupId):
            if showDroppedGroups.contains(groupId) { showDroppedGroups.remove(groupId) } else {
                showDroppedGroups.insert(groupId)
            }
            after = .rerender
        case .showReceipt(let receipt):
            // R8e (N1): inside a sheet the receipt opens on top of it; the sheet stays.
            if sheet != nil { sheetReceipt = receipt } else { sheet = .receipt(receipt) }
            after = .nothing
        case .pinMetric(let key, let pinned):
            settings.pinnedMetrics.removeAll { $0 == key }
            if pinned { settings.pinnedMetrics.append(key) }
            await saveState()

        // MARK: Moment card actions (UX §4.2)
        case .remindStrapOff(let minutes):
            await remindStrapOff(minutes: minutes)
        case .openTailscale:
            openTailscale()
        case .dismissMoment(let kind):
            sessions.dismissedMoments[kind.rawValue] = clock.now
            await saveState()
        case .endNap:
            await endNap()
        case .startNap(let minutes):
            _ = await startNap(minutes: minutes, at: clock.now)

        // MARK: Live (UX §6)
        case .startBreathe:
            startBreathe()
        case .startHRVCheck(let minutes):
            startHRVCheck(minutes: minutes)
        case .startECG:
            // Wave W8 (2026-10-11): was a notice ("needs a strap command that stays off until CLAUDE.md rule 5
            // changes"); rule 5 allows the reading behind its switch now.
            openECG()
        case .ecgMotion(let action):
            await ecgMotion(action)
        case .autoRaw(let action):
            await autoRawAction(action)       // r9q
        case .startWorkout:
            await startWorkout()
        case .endWorkout:
            await endWorkout()
        case .nextWorkoutWindow:
            await nextWorkoutWindow()
        case .setBroadcast(let on):
            await setHRBroadcast(on)
        case .hrRead(let action):
            await hrReadAction(action)       // 0.6.0.12
        case .openResearch(let what):
            // W12b's history read test runs in place; every other id opens W10's research screen (#91).
            if what == Self.historyReadTestID { await runHistoryReadTest() }
            else if what == LivePresenter.whoop4RawResearchID { await openWhoop4Raw() }
            else { await openResearch(what) }
        case .research(let action):
            await researchAction(action)
        case .guided(let action):
            await guided(action)
        case .editWorkout(let id, let edit):
            await editWorkout(id: id, edit: edit)

        // MARK: Tonight and sleep (UX §8)
        case .setSmartWake(let on):
            settings.smartWakeOn = on
            await modelInputsChanged()
        case .setWakeWindow(let minutes):
            settings.wakeWindowMinutes = min(45, max(10, minutes))
            await modelInputsChanged()
        case .setNightSounds(let on):
            await setNightSounds(on)
        case .setWindDown(let on):
            settings.windDownOn = on
            await modelInputsChanged()
        case .setLatestWake(let weekday, let time):
            settings.setLatestWake(weekday: weekday, time: time)
            await modelInputsChanged()

        // MARK: Explore (UX §9)
        case .setPeriod(let p):
            // T9822: a picked custom range is checked again here (the sheet checks it too) and remembered.
            if let r = p.customRange {
                let today = LocalDay(date: Date(), calendar: calendar)
                if let why = CustomRange.problem(start: r.start, end: r.end, today: today) {
                    showNotice("That date range was not used: \(why)")
                    break
                }
                settings.customRangeStart = r.start.iso
                settings.customRangeEnd = r.end.iso
            }
            settings.explorePeriod = p.key
            await saveState()
        case .setMetricView(let mode):
            metricView = mode
        case .search(let text):
            exploreQuery = text
        case .setMatrixMetrics(let keys):
            settings.matrixKeys = Array(keys.prefix(MatrixState.maxMetrics))
            await saveState()
        case .openMatrixCell(let row, let column):
            let keys = Array(settings.matrixKeys.prefix(MatrixState.maxMetrics))
            guard row != column, keys.indices.contains(row), keys.indices.contains(column) else { break }
            compareFirst = keys[row]       // x = first metric (BRIEF WP-19 convention)
            compareSecond = keys[column]
            compareLag = 0
            push(.compare(keys[row]))
        case .setCompareWith(let key):
            compareSecond = key
        case .setCompareLag(let days):
            compareLag = min(CompareState.maxLagDays, max(0, days))

        // MARK: Strap, PC, settings (UX §14)
        case .refresh:
            await pullToRefresh()
        case .pairPC:
            services.pairing.reset()
            sheet = .pairing
        case .pairStrap:
            pairStrap()
        case .syncNow:
            await syncPCNow(reset: false)
        case .resetSync:
            await syncPCNow(reset: true)
        case .changeWearLocation(let place):
            await changeWearLocation(place)
        case .openUnlock:
            await runR22(restore: false)
        case .restoreR22:
            await runR22(restore: true)
        case .readStrapSettings:
            await readStrapSettings()
        case .setRawOptical(let on):
            await setRawOptical(on)
        case .setHandBackToWhoop(let on):
            await setHandBackToWhoop(on)
        case .setInputDevice(let device):
            await setInputDevice(device)
        case .setRawOpticalNightsOnly(let on):
            await setRawOpticalNightsOnly(on)
        case .setRawOpticalWindows(let inWorkout, let every, let whenStill):
            await setRawOpticalWindows(inWorkout: inWorkout, every: every, whenStill: whenStill)
        case .measureSpO2Now:
            await measureSpO2Now()
        case .cancelSpO2Now:
            await cancelSpO2Now()
        case .setTheme(let setting):
            settings.theme = setting
            await saveState()
        case .setSampleData(let on):
            await setSampleData(on)
        case .setResearchRows(let on):
            settings.researchRowsShown = on
            await saveState()
        case .setStressSummary(let on):
            settings.stressSummaryOn = on
            await modelInputsChanged()
        case .setHideWorkingBars(let on):
            settings.hideWorkingBars = on
            await saveState()
        case .setQuickLogSurface(let id, let enabled):
            settings.quickLogSurfaces[id] = enabled
            await saveState()
            await publishWidgetSnapshot()      // "widget" surface → the widget's buttons (WP-27)
        case .editSetting(let edit):
            await editSetting(edit)
        case .export:
            await exportEverything()
        case .exportRange(let from, let to):
            await export(from: from, to: to)
        case .appleHealth(let action):
            await appleHealth(action)          // AppModel+AppleHealth.swift
        case .alarms(let action):
            await alarmsAction(action)         // App/Alarms/AppModel+Alarms.swift
        case .usage(let action):
            await usageAction(action)          // App/Usage/AppModel+Usage.swift
        case .places(let action):
            await placesAction(action)         // App/Places/AppModel+Places.swift
        case .frontPage(let action):
            await frontPageAction(action)      // AppModel+FrontPage.swift
        case .commandTest(let action):
            await commandTestAction(action)    // App/CommandTest/AppModel+CommandTest.swift
        case .ringLab(let action):
            await ringLabAction(action)        // App/RingLab/AppModel+RingLab.swift
        case .screenTime(let action):
            await screenTimeAction(action)     // App/ScreenTime/AppModel+ScreenTime.swift
        }
        switch after {
        case .nothing:
            return
        case .rerender:
            await rerender()
        case .full:
            await refresh()
            if alarms.loaded { await alarmsTick() }   // a wake-time or smart-wake edit moves the alarms too
        }
    }

    // MARK: Navigation helpers

    /// Pushes onto the current tab's stack (or `tab`'s, switching to it).
    func push(_ route: RootRoute, on target: AppTab? = nil) {
        let t = target ?? tab
        if tab != t { tab = t }
        var stack = paths[t] ?? []
        if stack.last != route { stack.append(route) }
        paths[t] = stack
    }

    /// T10022: Settings and Preferences link to each other. A screen already on the stack is gone back to rather than
    /// pushed a second time, so Settings › Preferences › Settings › … cannot pile up.
    func pushOrPop(_ route: RootRoute) {
        var stack = paths[tab] ?? []
        if let i = stack.lastIndex(of: route) {
            stack = Array(stack[...i])
        } else {
            stack.append(route)
        }
        paths[tab] = stack
    }

    /// Re-tap of the current tab (UX §3.1): pop to the root, or scroll to the top when already there.
    func reTap(_ t: AppTab) {
        if let stack = paths[t], !stack.isEmpty {
            paths[t] = []
        } else {
            scrollTicks[t, default: 0] += 1
        }
    }

    func toggle(_ id: String) {
        if openRows.contains(id) { openRows.remove(id) } else { openRows.insert(id) }
    }

    /// The Log tab with one row open (`.openLogItem`, `.addEntry`: "opens its row", BRIEF WP-18 row).
    func openLogRow(_ item: LogItemID) {
        tab = .log
        for other in LogItemID.allCases where other != item { openRows.remove(other.rawValue) }
        openRows.insert(item.rawValue)
    }

    /// The path of one tab changed (pop, swipe back): forget the state slots the popped screens used.
    func pathChanged(_ t: AppTab) {
        let stack = paths.values.flatMap { $0 }
        if !stack.contains(where: { if case .workout = $0 { return true } else { return false } }) {
            workoutRequested = false
            workoutId = nil
        }
        if let top = stack.last(where: { if case .metric = $0 { return true } else { return false } }),
           case .metric(let key, let variant) = top {
            detailKey = key
            detailVariant = variant
        } else {
            detailKey = nil
        }
        if !stack.contains(where: { if case .group = $0 { return true } else { return false } }) { groupId = nil }
        if !stack.contains(where: { if case .compare = $0 { return true } else { return false } }) {
            compareFirst = nil
            compareSecond = nil
        }
        if !stack.contains(where: { if case .night = $0 { return true } else { return false } }) { nightDay = nil }
        Task { await rerender() }      // R8e: the popped screens' states are dropped; no new reads
    }

    func openTailscale() {
        // The Shortcut "HealthApp Tailscale" (Tailscale's Connect action; ShortcutNames, 2026-10-11 — was the placeholder
        // "Connect Tailscale"). Run with x-callback-url so a missing Shortcut says so, with its build steps.
        Task { await runShortcut(ShortcutNames.tailscale) }
    }
}

/// R8e: set when the pull-to-refresh work has finished (read by the waiting loop in `pullRefresh`).
@MainActor
private final class PullGate {
    var done = false
}
