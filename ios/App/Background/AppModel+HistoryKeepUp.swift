import Foundation
import MGBLE
import MGContext
import MGDomain
import MGStore
import UIKit

// Wave W11 (2026-10-11, Mo 9:30 PM: "every time I open it it's syncing or fetching strap history … it should be doing
// that without me opening the app"). The decision is MGContext `HistoryKeepUp` (pure, tested); this file feeds it and
// acts on it:
//   - every 15 min while the strap is connected — app open or in the background — a history download (rule 5: only
//     SEND_HISTORICAL_DATA 22, its ACK 23 and ABORT 20, all inside MGBLE's existing download);
//   - in the background, live HR (sanctioned toggle 3) stays on so CoreBluetooth keeps waking the app (bluetooth-central,
//     the mechanism wave 4 uses at night), bounded by phone battery, strap battery and the wrist;
//   - the `.sync` BGTask pulls too when iOS grants time (AppWiring);
//   - the app starts at launch, not when its window first shows (MGApp), so a CoreBluetooth state-restoration relaunch
//     in the background reconnects the restored strap at once (MGBLE: `start()` → restored peripheral → connect).
// What it cost goes in Settings › Usage › "Strap in the background".

@MainActor
final class HistoryKeepUpModel {
    static let storeKey = "history.keepup.v1"
    /// A beat re-checks at most this often (beats arrive ~1 Hz).
    static let evalGap: TimeInterval = 30

    var loaded = false
    var stats = HistoryKeepUp.Stats(day: "")
    var lastPullAt: Date?
    var decision: HistoryKeepUp.Decision?
    var keepAwake = false
    var awakeSince: Date?
    var pulling = false
    /// T9997: when the current pull began, and which pull it is; a pull that never came back (app suspended mid-download)
    /// is written off after `stuckAfter` so `pulling` cannot stay true until the app is restarted.
    var pullStartedAt: Date?
    var pullSerial = 0
    static let stuckAfter: TimeInterval = 30 * 60
    var lastEval: Date?
    var lastSaved: Date?
    var ticker: Task<Void, Never>?
    /// Measured with Settings › Usage.
    var newestStored: Date?
    var motion: HistoryKeepUp.MotionCost?
    /// The newest PC delivery in words (NotifyCenter; it is no longer a banner — wave W11).
    var lastDelivery: String?
}

extension AppModel {
    private var ku: HistoryKeepUpModel { keepUp }

    private func keepUpDay(_ d: Date) -> String { LocalDay(date: d, calendar: calendar).iso }

    /// Once from `start()`: today's counts, then a 60-s loop (it runs while iOS keeps the app awake; beats and
    /// connection changes also re-check).
    func startHistoryKeepUp() async {
        if !ku.loaded {
            ku.stats = (try? await services.kv.load(HistoryKeepUp.Stats.self, key: HistoryKeepUpModel.storeKey))
                ?? HistoryKeepUp.Stats(day: keepUpDay(clock.now))
            ku.lastPullAt = ku.stats.lastPullAt
            ku.loaded = true
        }
        UIDevice.current.isBatteryMonitoringEnabled = true
        ku.ticker?.cancel()
        ku.ticker = Task { [weak self] in
            while !Task.isCancelled {
                await self?.historyKeepUpTick(force: true)
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    /// T9988: a live beat is a wake the app gets even when iOS would otherwise leave it suspended, so it also asks the sync
    /// coordinator whether a sync is due (at most every 5 min; the coordinator and the engine keep their own gaps, so this is
    /// a cheap no-op most of the time). Before this, only a finished history download did, and a strap that stayed connected
    /// without downloading history produced no sync request for hours (2026-10-15 8:44 PM to 10:23 PM).
    func syncCadenceBeat() {
        let now = ProcessInfo.processInfo.systemUptime
        guard !isSample, now - syncCadenceBeatAt >= 300 else { return }
        syncCadenceBeatAt = now
        Task { [weak self] in await self?.services.syncCoordinator.strapWoke() }
    }

    /// Every live beat: re-check at most every `evalGap` (no Task per beat).
    func keepUpBeat() {
        if let last = ku.lastEval, clock.now.timeIntervalSince(last) >= 0,
           clock.now.timeIntervalSince(last) < HistoryKeepUpModel.evalGap { return }
        Task { [weak self] in await self?.historyKeepUpTick(force: true) }
    }

    func historyKeepUpTick(force: Bool = false) async {
        guard ku.loaded else { return }
        let now = clock.now
        if !force, let last = ku.lastEval, now.timeIntervalSince(last) >= 0,
           now.timeIntervalSince(last) < HistoryKeepUpModel.evalGap { return }
        ku.lastEval = now
        if ku.pulling, let began = ku.pullStartedAt, now.timeIntervalSince(began) > HistoryKeepUpModel.stuckAfter {
            noteSelectedStrap("keep-up history pull: no answer for \(Int(now.timeIntervalSince(began) / 60)) min — "
                                        + "written off, pulling again")
            ku.pulling = false
        }
        let day = keepUpDay(now)
        if day != ku.stats.day {
            ku.stats.roll(to: day)
            if ku.keepAwake { ku.awakeSince = now }
        }
        if ku.keepAwake, let since = ku.awakeSince, now > since {
            ku.stats.keepAwakeSeconds += now.timeIntervalSince(since)
            ku.awakeSince = now
        }
        let link = selectedHistoryLink
        var connected = false
        var downloading = false
        switch link?.state {
        case .ready?: connected = true
        case .downloadingHistory?: connected = true; downloading = true
        default: break
        }
        let device = UIDevice.current
        let level = device.batteryLevel
        let charging: Bool? = device.batteryState == .unknown ? nil
            : (device.batteryState == .charging || device.batteryState == .full)
        let d = HistoryKeepUp.decide(HistoryKeepUp.Input(
            enabled: true, sample: isSample, appActive: appActive, connected: connected,
            downloading: downloading || ku.pulling, lastPullAt: ku.lastPullAt, now: now,
            phoneBattery: level < 0 ? nil : Double(level), phoneCharging: charging,
            strapBattery: selectedStrapBatteryPercent, offWrist: offWristSince != nil))
        ku.decision = d
        if d.keepAwake != ku.keepAwake {
            ku.keepAwake = d.keepAwake
            ku.awakeSince = d.keepAwake ? now : nil
            applyRealtime(force: true)
        }
        if d.pull, let link { keepUpPull(link, background: !appActive) }
        if ku.lastSaved.map({ now.timeIntervalSince($0) > 300 }) ?? true { await keepUpSave() }
        if connected { await wakeChainCheck() }      // T9993: the strap flag went awake after a night -> the PC chain
        maintenanceIfDue(charging: charging == true, busy: downloading || ku.pulling)     // r9u: compaction while charging, app open
    }

    private func keepUpPull(_ link: any HistoryPulling, background: Bool) {
        guard !ku.pulling else { return }
        ku.pulling = true
        let started = clock.now
        ku.pullStartedAt = started
        ku.pullSerial += 1
        let serial = ku.pullSerial
        Task { [weak self] in
            var records = 0
            let result: String
            do {
                let s = try await link.downloadHistory()
                records = s.recordsInserted
                result = "\(s.chunksAcked) chunk(s), \(s.recordsInserted) records"
            } catch {
                result = "not started — \(StrapCoordinator.words(error))"
            }
            guard let self else { return }
            let now = self.clock.now
            if self.ku.pullSerial == serial { self.ku.pulling = false }   // an older, written-off pull must not clear a newer one
            self.ku.lastPullAt = now
            self.ku.stats.roll(to: self.keepUpDay(now))
            self.ku.stats.pulls += 1
            if background { self.ku.stats.backgroundPulls += 1 }
            self.ku.stats.records += records
            self.ku.stats.pullSeconds += max(0, now.timeIntervalSince(started))
            self.ku.stats.lastPullAt = now
            self.ku.stats.lastResult = result
            self.noteSelectedStrap("keep-up history pull\(background ? " (background)" : ""): \(result)")
            await self.keepUpSave()
        }
    }

    /// T10012 remote debug `pull_history`: the same pull the 15-minute keep-up starts, now. Answers at once whether it
    /// started (`status` shows how it goes). Starts nothing the keep-up would not start itself: SEND_HISTORICAL_DATA, its ACK
    /// and ABORT inside MGBLE's download.
    func debugPullHistoryNow() -> (started: Bool, why: String) {
        guard ku.loaded else { return (false, "the keep-up has not started yet (the app is still launching)") }
        guard !isSample else { return (false, "sample data is on") }
        guard let link = selectedHistoryLink else { return (false, "the strap link is not started") }
        guard case .ready = link.state else { return (false, "the strap is not ready for a download (link: \(link.state))") }
        guard !ku.pulling else {
            let since = ku.pullStartedAt.map { " since \(Int(clock.now.timeIntervalSince($0))) s ago" } ?? ""
            return (false, "a history download is already running\(since)")
        }
        keepUpPull(link, background: !appActive)
        return (true, "started")
    }

    /// Any finished download (on connect, alarms, keep-up) counts as the last pull.
    func keepUpHistoryFinished() {
        ku.lastPullAt = clock.now
    }

    /// The `.sync` BGTask: a short pull when the strap is connected, before the PC sync (iOS gives ~25 s; a download cut
    /// short leaves unacked chunks on the strap — ack only after the store, MGBLE).
    func backgroundHistoryPull() async {
        guard ku.loaded, !isSample, let link = selectedHistoryLink else {
            BackgroundRunLog.note(.sync, "history: strap link not started")
            return
        }
        guard case .ready = link.state, !ku.pulling else {
            BackgroundRunLog.note(.sync, "history: strap not connected or already downloading")
            return
        }
        keepUpPull(link, background: true)
        BackgroundRunLog.note(.sync, "history: pull started")
    }

    func keepUpSave() async {
        ku.lastSaved = clock.now
        try? await services.kv.save(ku.stats, key: HistoryKeepUpModel.storeKey)
    }

    /// Settings › Usage: where stored HR ends, and raw motion's storage and strap battery cost (store reads).
    func keepUpMeasure() async {
        let store = services.store
        let now = clock.now
        let to = Int64(now.timeIntervalSince1970)
        let newest: Int64? = (try? await store.newestHRSecond(atOrBefore: to)) ?? nil
        ku.newestStored = newest.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        let dayStart = Int64(calendar.startOfDay(for: now).timeIntervalSince1970)
        let today = (try? await store.motionSecondCount(from: dayStart, to: to)) ?? 0
        let stored: (seconds: Int, bytes: Int64) = (try? await store.motionStorage()) ?? (seconds: 0, bytes: 0)
        let battery = (try? await store.batteryReadings(from: to - 86_400, to: to)) ?? []
        let drain = HistoryKeepUp.drainPerHour(battery.map { (ts: $0.ts, percent: $0.percent, charging: $0.charging) })
        ku.motion = HistoryKeepUp.MotionCost(switchOn: settings.rawMotionOn, streaming: rawMotionStatus.on,
                                             secondsToday: today, storedSeconds: stored.seconds,
                                             storedBytes: stored.bytes, strapDrainPerHour: drain)
        ku.lastDelivery = await services.notifyCenter.lastDeliveryLine
    }

    func keepUpUsageSection() -> UsageState.Section {
        var s = HistoryKeepUp.usageSection(stats: ku.stats, decision: ku.decision, appActive: appActive,
                                           newestStored: ku.newestStored, motion: ku.motion, now: clock.now,
                                           calendar: calendar)
        s.rows.append(UsageState.Row(id: "keepup.pcsync", title: "Last delivery to the PC",
                                     value: ku.lastDelivery == nil ? "none yet" : "",
                                     detail: ku.lastDelivery.map {
                                         $0 + ". Routine syncs no longer post a notification; problems still do."
                                     }))
        // 0.5.8.1 "Raw night": R20 / R21 minutes, gaps and reconnects since last evening, for the morning check.
        s.rows.append(UsageState.Row(id: "keepup.rawnight", title: "Raw night", value: "",
                                     detail: RawNightLog.current().summary(now: clock.now, calendar: calendar,
                                                                           r20Wanted: settings.rawOpticalOn && !isSample,
                                                                           r21Wanted: settings.rawMotionOn && !isSample)
                                         ?? "nothing counted yet (switch raw optical or raw motion on)"))
        return s
    }
}

extension AppModel {
    /// T140: the app is in the background and the phone is not charging (battery state unknown counts as not charging):
    /// a compute run then stops at its CPU limit (`WorkBudget`) and leaves the other days for the foreground or power.
    /// T9995: the app is in the background, charging or not (iOS's CPU limit does not care about power).
    func computeInBackground() -> Bool { !appActive }

    func computeBackgroundOnBattery() -> Bool {
        let d = UIDevice.current
        if !d.isBatteryMonitoringEnabled { d.isBatteryMonitoringEnabled = true }
        return !appActive && !(d.batteryState == .charging || d.batteryState == .full)
    }
}
