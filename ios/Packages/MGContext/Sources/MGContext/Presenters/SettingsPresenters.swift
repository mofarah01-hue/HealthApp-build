import Foundation
import MGDomain

/// Settings (UX §14), pushed from "M". Profile ids use `SettingEdit.profileField(id:text:)`; the calorie goal has its
/// own setting edit because it is stored in AppSettings rather than Profile.
public enum SettingsPresenter {
    public static func make(_ s: PresenterSnapshot) -> SettingsState {
        let set = s.settings
        let r = s.phoneReceipt(.high, method: "Settings")
        func field(_ id: String, _ label: String, _ text: String?, _ unit: String? = nil) -> LabeledValue {
            guard let text, !text.isEmpty else {
                // Tracker #42 (2026-10-11): an empty field says what it unlocks ("Sex unlocks: day strain, …").
                return LabeledValue(id: id, label: label, value: .blank(reason: "Not set — tap to add.", receipt: nil),
                                    caption: ProfileUnlocks.caption(field: id, label: label))
            }
            return LabeledValue(id: id, label: label, value: s.worded(text, unit: unit, receipt: r))
        }
        let p = set.profile
        let profile = [
            field("birth_date", "Birth date", p.birthDate?.iso),
            field("sex", "Sex", p.sex?.rawValue),
            field("height_cm", "Height", p.heightCm.map { ProfileUnits.heightText(cm: $0) }),
            field("weight_kg", "Weight", p.weightKg.map { ProfileUnits.weightText(kg: $0) }),
            field("hr_max", "Max HR (measured)", p.hrMaxMeasured.map { MGFormat.number($0, decimals: 0) }, "bpm"),
            field("hr_rest", "Resting HR baseline", p.hrRestBaseline.map { MGFormat.number($0, decimals: 0) }, "bpm"),
            LabeledValue(id: "calorie_goal_kcal", label: "Daily calorie burn goal (kcal)",
                         value: set.calorieGoalKcal.map { s.worded(MGFormat.number($0, decimals: 0), receipt: r) }
                             ?? .blank(reason: "not set", receipt: nil)),
        ]
        let schedules = set.schedules.map { sc in
            ScheduleRow(id: sc.id, title: PresenterSnapshot.scheduleTitle(sc), detail: scheduleDetail(sc),
                        isSupplement: sc.kind == .supplement, schedule: sc)
        }
        let surfaces = [("doubleTap", "Double-tap the strap logs a vape hit"), ("widget", "Home-screen widget"),
                        ("actionButton", "Action Button logs a vape hit")].map { id, title -> ToggleState in
            let on = set.quickLogSurfaces[id] ?? false
            return ToggleState(id: id, title: title, isOn: on, intent: .setQuickLogSurface(id: id, enabled: !on))
        }
        // UX §5 / APP-363 values, shown as placeholders until Mo sets the notification policy.
        let notes = [
            LabeledValue(id: "quiet", label: "Quiet hours", value: s.worded("bedtime − 30 min → wake", receipt: r),
                         caption: "PLACEHOLDER — Mo sets"),
            LabeledValue(id: "cap", label: "Daily cap", value: s.worded("6", receipt: r), caption: "PLACEHOLDER — Mo sets"),
        ]
        let notificationToggles = [
            ToggleState(id: "stressSummary", title: "Body arousal summary at 5:00 PM", isOn: set.stressSummaryOn,
                        intent: .setStressSummary(!set.stressSummaryOn)),
        ]
        let dropped = s.groupChoices.values.reduce(0) { $0 + $1.dropped.count }
        var built = SettingsState(
            sample: s.sample, profile: profile,
            latestWake: (1...7).map { WeekdayWake(weekday: $0, time: set.latestWake[$0]) },
            wakeWindowMinutes: min(max(set.wakeWindowMinutes, 10), 45),
            needOverride: set.needOverrideMinutes.map { s.worded(MGFormat.duration(minutes: $0), receipt: r) },
            schedules: schedules, drinkPresets: set.drinkPresets, quickLogSurfaces: surfaces, notificationRows: notes,
            notificationToggles: notificationToggles,
            notificationsArePlaceholders: true, theme: set.theme, researchRowsShown: set.researchRowsShown,
            droppedMethodsCount: dropped, sampleData: s.sample,
            privacyLines: ["Nothing leaves the phone except to your own PC over Tailscale.",
                           "Night audio never syncs.", "Meal photos stay on this phone; they are never uploaded."],
            export: ActionState(id: "export", title: "Export", intent: .export),
            fitzpatrickSkinType: set.fitzpatrickSkinType, vitaminDLocation: set.vitaminDLocation)
        .withProfileRecords(s)
        .withHideWorkingBars(set.hideWorkingBars)
        .withPresetLists(set.presetLists)
        .withNotificationSkips(set.skippedNotifications)
        .withSmartWake(mode: set.smartWakeMode, gateMinutes: set.smartWakeGateMinutes, restPercent: set.smartWakeRestPercent)
        .withPrimaryMapLine(PrimaryPick.mapLine(s.primary))
        .withPCStatus(s.inputs.sync.state)
        built.deviceName = s.deviceName
        return built
    }

    public static func calorieGoalIntent(_ kcal: Double?) -> UIIntent {
        .editSetting(.calorieGoalKcal(kcal))
    }

    /// A schedule's stored "HH:MM" as 12-hour words ("07:15" -> "7:15 AM"); text that is not "HH:MM" is returned as is.
    static func clockWords(_ hhmm: String) -> String {
        let bits = hhmm.split(separator: ":")
        guard bits.count == 2, let h = Int(bits[0]), let m = Int(bits[1]), (0..<24).contains(h), (0..<60).contains(m)
        else { return hhmm }
        return ClockText.hm(hour: h, minute: m)
    }

    /// "daily · 7:15 AM" / "mon, wed · 7:15 AM"; with the medications-list fields (tracker #42): "as needed", what it is
    /// for, "since 2 Jan 2024", "stopped 28 Feb 2025".
    static func scheduleDetail(_ sc: MedSchedule) -> String {
        let days = (sc.days?.isEmpty ?? true) ? "daily" : sc.days!.map(\.rawValue).joined(separator: ", ")
        let times = sc.times?.map(clockWords).joined(separator: ", ")
        let when = sc.asNeeded == true ? "as needed" : [days, times].compactMap { $0 }.filter { !$0.isEmpty }
            .joined(separator: " · ")
        let since = sc.started.map { "since " + PCHistoryText.day($0) }
        let stopped = sc.stopped.map { "stopped " + PCHistoryText.day($0) }
        return [when, sc.purpose, since, stopped].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

/// Strap & sync sheet (UX §14): strap, history, write log, unlock (disabled in B1), broadcast, PC Lab, Apple Health.
public enum StrapSyncPresenter {
    public static func make(_ s: PresenterSnapshot) -> StrapSyncState {
        let strap = s.inputs.strap
        let info = s.strapSync
        let strapR = Receipt(computedOn: .strap, tier: .strap, at: strap.lastRecordAt ?? s.now)
        func row(_ id: String, _ label: String, _ text: String?, _ unit: String? = nil, why: String) -> LabeledValue {
            guard let text else { return LabeledValue(id: id, label: label, value: .blank(reason: why, receipt: nil)) }
            return LabeledValue(id: id, label: label, value: s.worded(text, unit: unit, receipt: strapR))
        }
        let rows = [
            row("bond", "Bond", info.bonded.map { $0 ? "bonded" : "not bonded" }, why: "Known once the strap connects."),
            row("battery", "Battery", strap.batteryPercent.map { MGFormat.number($0, decimals: 0) }, "%",
                why: "Read on connect."),
            row("batteryLeft", "Battery left", strap.batteryEstimate.map { $0.words },
                why: "Needs a few hours of battery readings."),
            row("firmware", "Firmware", info.firmware, why: "Read on connect."),
            row("worn", "Worn", strap.wearLocation.map { TodayPresenter.wearName($0).lowercased() },
                why: "Not answered yet."),
            row("last", "Last record", strap.lastRecordAt.map { s.hm($0) }, why: "Nothing recorded yet."),
        ]
        var historyLine = strap.link == .connected ? "up to date" : "not downloading — strap not connected"
        var progress: Double?
        if let h = s.inputs.history {
            progress = HistoryProgressWords.barFraction(h, now: s.now)
            let words = HistoryProgressWords.state(h, now: s.now)   // T10013 (r8b): no stuck 98 % near "now"
            if case .caughtUp = words, let tail = HistoryProgressWords.tail(h, now: s.now, hm: s.hm) {
                historyLine = tail
            } else if case .catchingUp = words {
                historyLine = "catching up to now · \(h.chunksStored) chunk\(h.chunksStored == 1 ? "" : "s") stored"
            } else if let f = h.fraction, let c = h.coveredSeconds, let t = h.totalSeconds {
                historyLine = "\(Int((f * 100).rounded(.down))) % · \(MGFormat.duration(Double(c))) of \(MGFormat.duration(Double(t)))"
            } else {
                historyLine = "\(h.chunksStored) chunk\(h.chunksStored == 1 ? "" : "s") stored"
            }
        }
        let ackAt = s.inputs.history?.lastAckAt ?? info.lastAckAt
        var counts: [String: Int] = [:]
        var order: [String] = []
        for w in info.writesToday {
            if counts[w] == nil { order.append(w) }
            counts[w, default: 0] += 1
        }
        let writes = order.isEmpty ? "no strap writes today ›"
            : order.map { "\($0) ×\(counts[$0] ?? 0)" }.joined(separator: " · ") + " today ›"
        let sync = s.inputs.sync
        let pcLine: String
        switch sync.state {
        case .notSetUp: pcLine = "PC Lab not set up — everything runs on the phone."
        case .pairing: pcLine = "Pairing…"
        case .error: pcLine = "Sync error" + (sync.error.map { ": \($0)" } ?? ".")
        case .online, .offline:
            if let rec = sync.lastReceipt {
                pcLine = "PC got \(MGFormat.duration(rec.rangeEnd.timeIntervalSince(rec.rangeStart))) · "
                    + TodayPresenter.bytes(rec.bytes) + " · \(s.hm(rec.receivedAt))"
            } else if let last = sync.lastSynced {
                pcLine = "Last synced \(s.hm(last))" + (sync.state == .offline ? " · PC offline now" : "")
            } else {
                pcLine = sync.state == .offline ? "PC offline — nothing synced yet." : "Paired — nothing synced yet."
            }
        }
        var unsynced: String?
        if let d = sync.unsyncedDays, d > 0 { unsynced = "\(d) day\(d == 1 ? "" : "s") not yet on the PC" }
        if let b = info.unsyncedBytes, b > 0 { unsynced = [unsynced, TodayPresenter.bytes(b) + " waiting"].compactMap { $0 }.joined(separator: " · ") }
        let pair = ActionState(id: "pair", title: sync.state == .notSetUp ? "Pair PC Lab" : "Pair again", intent: .pairPC,
                               enabled: !s.sample, disabledReason: s.sample ? "Sample data is on — sync is off." : nil)
        var health: [String]
        if info.healthAvailable {
            health = [info.healthGranted.isEmpty ? "No Apple Health types granted yet." : info.healthGranted.joined(separator: ", ")]
            if let at = info.healthLastRead { health[0] += " · read \(s.hm(at))" }
        } else {
            health = ["Apple Health isn't available in this build."]
        }
        let settings = settingsSection(s, link: strap.link)
        let r22 = r22Section(s, link: strap.link)
        let rawOptical = rawOpticalSection(s, link: strap.link)
        var state = StrapSyncState(
            sample: s.sample, strapRows: rows,
            changeWearLocation: ActionState(id: "wear", title: "Change", intent: .changeWearLocation(strap.wearLocation ?? .leftWrist)),
            historyLine: historyLine, historyProgress: progress,
            lastAckLine: ackAt.map { "last chunk acked \(s.hm($0)) (acked = the phone saved the chunk, then told the strap it can move on)" }, writeLogLine: writes,
            unlock: r22.enable, unlockStatus: r22.status,
            broadcast: broadcastToggle(s),
            pcState: sync.state, pcLine: pcLine, unsyncedLine: unsynced, pair: pair, healthLines: health,
            connect: connectAction(strap.link), settingsLine: settings.line, settingsRows: settings.rows,
            readSettings: settings.action, restoreR22: r22.restore, rawOptical: rawOptical.toggle,
            rawOpticalLine: rawOptical.line, r22WatchLine: r22WatchLine(s), cleanupLine: cleanupLine(s))
        let nights = rawOpticalNightsSection(s)
        state.rawOpticalNights = nights.toggle
        state.rawOpticalNightLines = nights.lines
        state.rawOpticalWorkout = rawOpticalWorkoutToggle(s)
        state.rawOpticalEveryLabel = SpO2EveryOption.matching(s.strapSync.rawOpticalEvery).title
        state.rawOpticalEveryOptions = rawOpticalEveryOptions(s)
        state.rawOpticalWhenStill = rawOpticalWhenStillToggle(s)
        state.ecgMotion = EcgMotionPresenter.strapSection(s, link: strap.link)   // wave W8
        state.inputDevice = inputDeviceSection(s)                                // 0.6.0.3 Ring live
        state.handBack = handBackToggle(s)                                       // wave W12b (#103)
        state.autoRaw = AutoRawPresenter.section(s.strapSync.autoRaw, sample: s.sample, mgOnly: s.mgOnlyReason)   // r9q
        state.deviceName = s.deviceName
        state.hrRead = HRReadPresenter.section(s)
        state.syncPanel = syncPanel(s, history: historyLine, ack: ackAt, link: strap.link, lastRecord: strap.lastRecordAt)
        state.handBackLines = s.strapSync.handBackLines
        return state
    }

    /// P9734: the expandable sync panel. Strap to phone: link, history, last ack, last record. Phone to PC: state, last
    /// success, queue, bytes, last error in engineering detail, next try. "Sync now" and "Reset" (Reset never deletes data).
    static func syncPanel(_ s: PresenterSnapshot, history: String, ack: Date?, link: StrapStatus.Link, lastRecord: Date?) -> SyncPanelState? {
        guard let p = s.strapSync.pcSync else { return nil }
        func bytes(_ n: Int) -> String { TodayPresenter.bytes(n) }
        let strapRows = [
            SyncPanelRow(id: "link", label: "Link", value: link == .connected ? "connected" : "not connected"),
            SyncPanelRow(id: "history", label: "History download", value: history),
            SyncPanelRow(id: "ack", label: "Last chunk acked", value: ack.map { s.hm($0) + " (the phone saved the chunk, then told the strap it can move on)" } ?? "none yet"),
            SyncPanelRow(id: "record", label: "Last record", value: lastRecord.map { s.hm($0) } ?? "none yet"),
        ]
        let stateWord: String
        switch p.state {
        case .notSetUp: stateWord = "not set up"
        case .pairing: stateWord = "pairing"
        case .offline: stateWord = "offline"
        case .online: stateWord = "online"
        case .error: stateWord = "error"
        }
        var pcRows = [
            SyncPanelRow(id: "state", label: "State", value: stateWord),
            SyncPanelRow(id: "success", label: "Last full sync", value: p.lastSuccess.map { s.hm($0) } ?? "none yet"),
            SyncPanelRow(id: "accepted", label: "PC last accepted data", value: p.lastAcceptedAt.map { s.hm($0) } ?? "none yet"),
            SyncPanelRow(id: "queue", label: "Waiting on the phone",
                         value: p.queueDrops == 0 ? "nothing" : "\(p.queueDrops) drop\(p.queueDrops == 1 ? "" : "s") · \(bytes(p.queueBytes)) (kept until the PC confirms)"),
            SyncPanelRow(id: "bytes", label: "Confirmed by the PC", value: bytes(p.bytesDelivered)),
        ]
        if let stop = p.lastStop {
            pcRows.append(SyncPanelRow(id: "stop", label: "Last sync", value: stop + (p.lastStopAt.map { " · " + s.hm($0) } ?? "")))
        }
        if let e = p.lastError {
            pcRows.append(SyncPanelRow(id: "error", label: "Last error", value: e + (p.lastErrorAt.map { " · " + s.hm($0) } ?? "")))
        } else {
            pcRows.append(SyncPanelRow(id: "error", label: "Last error", value: "none"))
        }
        if let next = p.nextRetryAt, p.consecutiveFailures > 0 {
            pcRows.append(SyncPanelRow(id: "next", label: "Next automatic try",
                                       value: "\(s.hm(next)) (failure \(p.consecutiveFailures) in a row; steps 1, 2, 5, 15, then every 60 min)"))
        }
        if p.authFailures > 0 {
            pcRows.append(SyncPanelRow(id: "auth", label: "Key refused",
                                       value: "\(p.authFailures) of \(p.authFailuresToRepair) in a row" + (p.needsRepair ? " — scan the QR again" : "")))
        }
        var head = stateWord.prefix(1).uppercased() + stateWord.dropFirst()
        head += p.queueDrops == 0 ? " · nothing waiting" : " · \(p.queueDrops) waiting (\(bytes(p.queueBytes)))"
        if let stop = p.lastStop { head += " · " + stop }
        let off = s.sample
        let why = "Sample data is on — sync is off."
        return SyncPanelState(
            banner: p.banner, headline: head, strapToPhone: strapRows, phoneToPC: pcRows,
            syncNow: ActionState(id: "syncNow", title: "Sync now", intent: .syncNow, enabled: !off,
                                 disabledReason: off ? why : nil),
            reset: ActionState(id: "resetSync", title: "Reset", intent: .resetSync, enabled: !off,
                               disabledReason: off ? why : nil))
    }

    /// T77: HR broadcast to gym kit and other apps (commands 14 and 119; MGBLE `setHRBroadcast`). Default off.
    static func broadcastToggle(_ s: PresenterSnapshot) -> ToggleState {
        let i = s.strapSync
        return ToggleState(
            id: "broadcast", title: "Broadcast heart rate to other devices",
            detail: "The strap advertises your heart rate as a standard Bluetooth sensor, so a Garmin, Zwift, Peloton or "
                + "gym machine can read it. Uses a little strap battery. The strap may keep this setting after the app "
                + "disconnects (sources differ), so check what it reports. Strap reports: "
                + "\(i.hrBroadcastReading ?? "not read yet").",
            isOn: i.hrBroadcastOn, enabled: !s.sample, disabledReason: s.sample ? "Sample data is on." : nil,
            intent: .setBroadcast(!i.hrBroadcastOn))
    }

    /// 0.6.0.3 Ring live: "Input device" picker (Auto / WHOOP strap / Ring) and which one is active now.
    static func inputDeviceSection(_ s: PresenterSnapshot) -> InputDeviceSection {
        let i = s.strapSync
        let active = InputDeviceRule.active(setting: i.inputDevice, strapLinkUp: i.strapLinkUp, ringConnected: i.ringConnected)
        let line = InputDeviceRule.line(active: active, strapLinkUp: i.strapLinkUp, ringConnected: i.ringConnected,
                                        ringName: i.ringName)
        var details = [line]
        if let steps = i.ringStepsLine { details.append(steps) }
        return InputDeviceSection(
            currentTitle: i.inputDevice.title,
            options: InputDevice.allCases.map { d in
                ActionState(id: "inputDevice.\(d.rawValue)", title: d.title, intent: .setInputDevice(d),
                            enabled: !s.sample, disabledReason: s.sample ? "Sample data is on." : nil)
            },
            detailLines: details)
    }

    /// Wave W12b (#103): leave-no-trace. On = HealthApp puts back what it changed on the strap and stops connecting.
    static func handBackToggle(_ s: PresenterSnapshot) -> ToggleState {
        let on = s.strapSync.handBackOn
        return ToggleState(
            id: "handBack", title: "Hand the strap back to WHOOP",
            detail: on ? "On: HealthApp doesn't connect. Switch off to connect again and re-apply your settings."
                : "Puts back what HealthApp changed on the strap (enable_r22_packets to its saved value, the strap alarm it "
                + "set), stops raw optical, raw motion and ECG, then disconnects and stays off. Everything already "
                + "collected stays on the phone and the PC.",
            isOn: on, enabled: !s.sample && s.mgOnlyReason == nil,
            disabledReason: s.mgOnlyReason ?? (s.sample ? "Sample data is on." : nil),
            intent: .setHandBackToWhoop(!on))
    }

    /// Wave 4 (#65): the night schedule under the raw optical switch. Since W11 (2026-10-11 9:43 PM) raw optical runs
    /// while the app is open AND in these night windows; title and detail reworded at the W10 merge (11:20 PM), they
    /// said "Nights only, in the background" / "Instead of while the app is open: …".
    static func rawOpticalNightsSection(_ s: PresenterSnapshot) -> (toggle: ToggleState, lines: [String]) {
        let i = s.strapSync
        let sched = i.rawOpticalSchedule ?? .researchDefault
        let pct = MGFormat.number(RawOpticalNight.dutyFraction(sched) * 100, decimals: 0)
        let run = MGFormat.number(Double(RawOpticalNight.runLength(sched)) / 60, decimals: 1)
        let why: String? = s.sample ? "Sample data is on." : (i.rawOpticalWanted ? nil : "Turn raw optical on first.")
        let toggle = ToggleState(
            id: "rawOpticalNights", title: "At night too, in the background",
            detail: "As well as while the app is open: during your sleep window, \(run) min around each of the strap's "
                + "SpO₂ bursts (every \(sched.periodS / 60) min, about \(pct) % of the night). Live heart rate stays on "
                + "from up to 3 h before bedtime so the phone keeps the app awake. Frames upload to the PC like any raw.",
            isOn: i.rawOpticalNightsOnly, enabled: why == nil, disabledReason: why,
            intent: .setRawOpticalNightsOnly(!i.rawOpticalNightsOnly))
        var lines: [String] = []
        if let l = sched.learnedAt {
            lines.append("Burst schedule: \(sched.windowLenS) s at strap unix % \(sched.periodS) = \(sched.phaseS), "
                         + "learned from this strap's R18 \(MGFormat.shortDate(l, calendar: s.calendar)).")
        } else {
            lines.append("Burst schedule: not learned from this strap yet; using the one strap measured (unix % 1200 = "
                         + "337, 30 s). It is learned from the first night with SpO₂ bytes.")
        }
        if i.rawOpticalNightsOnly, let d = i.rawOpticalDecision {
            if d.runNow {
                lines.append("Running now (a burst window).")
            } else if let n = d.nextStart {
                lines.append("Next window \(s.hm(n))" + (d.inSleepWindow ? "." : " (sleep window)."))
            } else {
                lines.append("Not tonight's sleep window.")
            }
        }
        lines.append(RawOpticalCost.line(i.rawOpticalCost ?? RawOpticalCost.Estimate(withRate: nil, withNights: 0,
                                                                                       withoutRate: nil, withoutNights: 0)))
        lines.append(LedExperiment.status(s.pcResults).text)       // the PC's LED identity experiment (research)
        return (toggle, lines)
    }

    /// T124: raw optical also runs in the background during a workout (RawOpticalWindows). Same gating as the night switch.
    static func rawOpticalWorkoutToggle(_ s: PresenterSnapshot) -> ToggleState {
        let i = s.strapSync
        let why: String? = s.sample ? "Sample data is on." : (i.rawOpticalWanted ? nil : "Turn raw optical on first.")
        return ToggleState(
            id: "rawOpticalWorkout", title: "In workouts too, in the background",
            detail: "Keeps raw optical on while a workout is running, even with the app in the background.",
            isOn: i.rawOpticalInWorkout, enabled: why == nil, disabledReason: why,
            intent: .setRawOpticalWindows(inWorkout: !i.rawOpticalInWorkout, every: i.rawOpticalEvery,
                                          whenStill: i.rawOpticalWhenStill))
    }

    /// T124: the "every X" picker rows. Each bakes in the CURRENT `rawOpticalInWorkout` / `rawOpticalWhenStill`
    /// (same intent as the other two rows), so picking a schedule never undoes them.
    static func rawOpticalEveryOptions(_ s: PresenterSnapshot) -> [ActionState] {
        let i = s.strapSync
        return SpO2EveryOption.allCases.map { option in
            ActionState(id: "rawOpticalEvery.\(option.title)", title: option.title,
                        intent: .setRawOpticalWindows(inWorkout: i.rawOpticalInWorkout, every: option.every,
                                                       whenStill: i.rawOpticalWhenStill))
        }
    }

    /// T124: "When the wrist is still" (RawOpticalWindows.isStill), same gating as the workout toggle.
    static func rawOpticalWhenStillToggle(_ s: PresenterSnapshot) -> ToggleState {
        let i = s.strapSync
        let why: String? = s.sample ? "Sample data is on." : (i.rawOpticalWanted ? nil : "Turn raw optical on first.")
        return ToggleState(
            id: "rawOpticalWhenStill", title: "When the wrist is still",
            detail: "Keeps raw optical on for a minute after the wrist sits still, even with the app in the background.",
            isOn: i.rawOpticalWhenStill, enabled: why == nil, disabledReason: why,
            intent: .setRawOpticalWindows(inWorkout: i.rawOpticalInWorkout, every: i.rawOpticalEvery,
                                          whenStill: !i.rawOpticalWhenStill))
    }

    /// The last phone-side cleanup (Mo 2026-10-11): what went, and the rule it follows.
    static func cleanupLine(_ s: PresenterSnapshot) -> String? {
        guard let r = s.strapSync.lastCleanup else { return nil }
        var parts: [String] = []
        if r.rawFrames > 0 { parts.append("\(r.rawFrames) raw frame\(r.rawFrames == 1 ? "" : "s")") }
        if r.perSecondTotal > 0 { parts.append("\(r.perSecondTotal) per-second row\(r.perSecondTotal == 1 ? "" : "s")") }
        if r.outboxCopies > 0 {
            parts.append("\(r.outboxCopies) stored upload cop\(r.outboxCopies == 1 ? "y" : "ies") ("
                         + TodayPresenter.bytes(r.outboxBytes) + ")")
        }
        let what = parts.isEmpty ? "nothing old enough yet" : "removed " + parts.joined(separator: ", ")
        return "Phone cleanup \(s.hm(r.at)): \(what). Only data the PC confirmed, kept 30 days first."
    }

    /// The R22 watch in words (Mo 2026-10-11, "Single write, then see").
    static func r22WatchLine(_ s: PresenterSnapshot) -> String? {
        guard let w = s.strapSync.r22Watch else { return nil }
        switch w.verdict {
        case .arriving:
            return "R22 records arriving: \(w.r22Records) since \(w.firstR22At.map { s.hm($0) } ?? "the write")."
        case .waiting:
            return "R22 enabled \(s.hm(w.writtenAt)) — waiting for offloads with data recorded after the write "
                + "(\(w.offloadsAfterWrite) of \(R22Watch.offloadsNeeded)). R22 is only recorded while the strap is worn."
        case .noneYet:
            if let flag = w.hintFlag {
                return "R22 enabled but no R22 records yet — the strap may also need \(flag) = 1 (not written by the app yet)."
            }
            return "R22 enabled but no R22 records yet — an R22 version flag already reads 1; R22 is only recorded "
                + "while the strap is worn."
        }
    }

    /// Raw optical (2026-10-11): live R20 (108) while the switch is on and the strap connected. T10000 (2026-10-17): since
    /// 0.5.8 it runs in the background until the switch is turned off, and pauses only while a history download runs.
    static func rawOpticalSection(_ s: PresenterSnapshot, link: StrapStatus.Link) -> (toggle: ToggleState, line: String) {
        let i = s.strapSync
        // 0.6.0.12: raw optical works on the 4.0 too (command 63, whoop4-wire 6): only Sample mode greys it.
        let why: String? = s.sample ? "Sample data is on." : nil
        let toggle = ToggleState(
            id: "rawOptical", title: "Raw optical (uses strap battery)",
            detail: s.whoop4Selected
                ? "Streams the WHOOP 4.0's live optical wave (one LED, believed green; raw counts, decoded, untested). Sends "
                    + "63 [01]; off with 63 [00]. The same command also starts raw motion. Pauses while a history download runs."
                : "Streams the strap's 5-block optical record (R20, 25 Hz, raw counts). Sends 108 [01 01]. It keeps running "
                + "in the background until you switch it off, and pauses only while a history download runs.",
            isOn: i.rawOpticalWanted, enabled: why == nil, disabledReason: why, intent: .setRawOptical(!i.rawOpticalWanted))
        var line: String
        if let stopped = i.rawOpticalStopped {
            line = stopped
        } else if !i.rawOpticalWanted {
            line = "off"
        } else if link != .connected {
            line = "on — waiting for the strap"
        } else if i.rawOpticalOn {
            line = "streaming · \(i.rawOpticalFrames) record\(i.rawOpticalFrames == 1 ? "" : "s")"
                + (i.rawOpticalLastFrameAt.map { " · last \(s.hm($0))" } ?? " · none yet")
        } else {
            // T10000: was "on — while the app is open and at night (see below)" / "on — starts when the app is open".
            line = i.rawOpticalNightsOnly ? "on — runs in the background, and at night (see below)"
                : "on — starts when the strap is connected"
        }
        return (toggle, line)
    }

    /// R22 research stream (2026-10-11): one write, enable_r22_packets = '1', behind the confirm sheet; the status
    /// comes from the newest stored settings snapshot (the strap's own answer, not what the app last sent).
    static func r22Section(_ s: PresenterSnapshot, link: StrapStatus.Link)
        -> (enable: ActionState, restore: ActionState, status: String) {
        var status = "not read yet"
        if let snap = s.strapSync.flagSnapshot {
            let at = s.hm(snap.readAt)
            switch snap.value(of: "enable_r22_packets") {
            case "1"?: status = "on ('1') · read \(at)"
            case let v?: status = "off ('\(v)') · read \(at)"
            case nil: status = "not readable · read \(at)"
            }
        }
        // The latest known value: a write's read-back when it is newer than the snapshot (2026-10-11).
        if let w = s.strapSync.r22LastWrite, w.at > (s.strapSync.flagSnapshot?.readAt ?? .distantPast) {
            let at = s.hm(w.at)
            status = w.readback == "1" ? "on ('1') · read back after the write \(at)"
                : "off ('\(w.readback)') · read back after the write \(at)"
        }
        let why: String? = s.mgOnlyReason
            ?? (s.sample ? "Sample data is on." : (link != .connected ? "Connect the strap first." : nil))
        let enable = ActionState(id: "unlock", title: "Turn on R22 (enable_r22_packets → 1)", intent: .openUnlock,
                                 enabled: why == nil, disabledReason: why)
        let restore = ActionState(id: "restoreR22", title: "Restore the saved value", intent: .restoreR22,
                                  enabled: why == nil, disabledReason: why)
        return (enable, restore, status)
    }

    /// Strap settings (117/118/128 snapshot, added 2026-10-11): the newest stored snapshot and the read button.
    static func settingsSection(_ s: PresenterSnapshot, link: StrapStatus.Link)
        -> (line: String, rows: [StrapSettingRow], action: ActionState) {
        var line = "Not read yet. Reading writes nothing to the strap."
        var rows: [StrapSettingRow] = []
        if let snap = s.strapSync.flagSnapshot {
            let ok = snap.readings.filter { $0.status == "ok" }.count
            line = "read \(s.hm(snap.readAt)) · \(snap.readings.count) keys, \(ok) with a value"
                + (snap.firmware.map { " · fw \($0)" } ?? "")
            rows = snap.readings.map { r in
                StrapSettingRow(key: r.key, value: r.status == "ok" ? (r.value ?? "—") : "—",
                                note: r.status == "ok" ? nil : r.status)
            }
        }
        let action: ActionState
        if let mgOnly = s.mgOnlyReason {
            action = ActionState(id: "readSettings", title: "Read strap settings", intent: .readStrapSettings,
                                 enabled: false, disabledReason: mgOnly)
        } else if s.sample {
            action = ActionState(id: "readSettings", title: "Read strap settings", intent: .readStrapSettings,
                                 enabled: false, disabledReason: "Sample data is on.")
        } else if link != .connected {
            action = ActionState(id: "readSettings", title: "Read strap settings", intent: .readStrapSettings,
                                 enabled: false, disabledReason: "Connect the strap first.")
        } else {
            action = ActionState(id: "readSettings", title: "Read strap settings", intent: .readStrapSettings)
        }
        return (line, rows, action)
    }

    /// The one button that starts the strap link (`.pairStrap`: consent sheet the first time, then scan + bond).
    static func connectAction(_ link: StrapStatus.Link) -> ActionState? {
        switch link {
        case .notPaired:
            return ActionState(id: "connect", title: "Pair strap", intent: .pairStrap)
        case .disconnected:
            return ActionState(id: "connect", title: "Connect strap", intent: .pairStrap)
        case .bluetoothOff:
            return ActionState(id: "connect", title: "Connect strap", intent: .pairStrap, enabled: false,
                               disabledReason: "Bluetooth is off — switch it on in Control Center or iOS Settings › Bluetooth.")
        case .bluetoothNotAllowed:
            return ActionState(id: "connect", title: "Connect strap", intent: .pairStrap, enabled: false,
                               disabledReason: "iOS hasn't allowed MG to use Bluetooth — turn it on in iOS Settings › MG › Bluetooth.")
        case .searching, .connecting:
            return ActionState(id: "connect", title: "Looking for your strap…", intent: .pairStrap, enabled: false,
                               disabledReason: "Keep it close and close the WHOOP app — the strap takes one connection at a time.")
        case .connected:
            return nil
        }
    }
}
