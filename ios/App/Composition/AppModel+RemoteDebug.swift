import Foundation
import MGBLE
import MGContext
import MGDomain
import MGHealth
import MGStore
import MGSync
import UIKit
import os

// T10012 (0.5.8.4 "Debug line", Mo Oct 17: "no server debug feature for you to request logs or use a pull strap data command
// to the app"). The PC queues a command (pclab/mglab/debug.py); this keeps ONE long poll going while the app runs, runs each
// command serially with a time limit, logs it in the compute log, and posts the answer. A phone that is not polling still
// learns of waiting commands from the PC's reply to the 5-minute app-status post (LifecycleRecorder.onPendingCommands).
//
// The queueing, time limits and backoff are the pure MGContext `RemoteDebug*` types (tested on Linux); this file feeds them.
// NOTHING here writes to the strap: `pull_history` starts the download the 15-minute keep-up already starts, `read_strap_settings`
// is the existing read-only flag read (117/118/128), `sync_now` and `run_night` are the app's own sync and the T9993 chain.
// Off switch for a misbehaving build: UserDefaults "remote.debug.off" = true (no screen; set from the PC with a command later).

private let remoteDebugOffKey = "remote.debug.off"

@MainActor
final class RemoteDebugRunner {
    private var task: Task<Void, Never>?
    private var loop: RemoteDebugLoop?
    private var generation = 0
    /// A command is running right now (set by `AppModel.runRemoteDebug`): a nudge must not restart the loop then.
    private(set) var busy = false

    func setBusy(_ on: Bool) { busy = on }

    /// Starts the loop once; a second call while it runs does nothing.
    func start(model: AppModel) {
        guard !UserDefaults.standard.bool(forKey: remoteDebugOffKey) else { return }
        if loop == nil { loop = Self.makeLoop(model: model) }
        guard task == nil, let loop else { return }
        generation += 1
        let mine = generation
        task = Task { [weak self] in
            await loop.run()
            if let self, self.generation == mine { self.task = nil }
        }
    }

    /// "Poll now": the PC said commands are waiting, or the app just came to the front (a long poll from before iOS suspended it
    /// is dead). While a command runs the loop is left alone: it polls again right after.
    func nudge(model: AppModel) {
        guard !UserDefaults.standard.bool(forKey: remoteDebugOffKey) else { return }
        guard task != nil else { return start(model: model) }
        guard !busy else { return }
        task?.cancel()
        task = nil
        start(model: model)
    }

    private static func makeLoop(model: AppModel) -> RemoteDebugLoop {
        let dispatcher = RemoteDebugDispatcher(
            handler: { [weak model] command in
                guard let model else { return .failure("the app was shutting down") }
                return await model.runRemoteDebug(command)
            },
            now: { Date() },
            limit: { $0.timeLimit })
        let hooks = RemoteDebugLoop.Hooks(
            poll: { wait in
                let reply = await PCLabDebug.poll(wait: wait, credentials: KeychainCredentialStore())
                if Task.isCancelled { return .empty }          // restarted on purpose: not a failure
                switch reply {
                case .body(let data):
                    let commands = RemoteDebug.decodeCommands(data)
                    return commands.isEmpty ? .empty : .commands(commands)
                case .notPaired:
                    return .failed("no PC is paired")
                case .unreachable(let why):
                    return .failed("PC not reachable: \(why)")
                case .unavailable(let why):
                    return .unavailable("this PC Lab does not serve the debug channel (\(why))")
                }
            },
            post: { answer in
                guard let body = try? MGJSON.encoder().encode(answer) else { return true }     // cannot be encoded: never will be
                return await PCLabDebug.postResult(body, credentials: KeychainCredentialStore())
            },
            sleep: { seconds in try? await Task.sleep(for: .seconds(seconds)) },
            shouldRun: { !UserDefaults.standard.bool(forKey: remoteDebugOffKey) },
            log: { line in ComputeLog.shared.append(.note, line, at: Date()) })
        return RemoteDebugLoop(hooks: hooks, dispatcher: dispatcher)
    }
}

// MARK: - JSON helpers (file-private, not main-actor)

private func jStr(_ s: String?) -> JSONValue { s.map { JSONValue.string($0) } ?? .null }
private func jNum(_ v: Int?) -> JSONValue { v.map { JSONValue.number(Double($0)) } ?? .null }
private func jNum(_ v: Int64?) -> JSONValue { v.map { JSONValue.number(Double($0)) } ?? .null }
private func jNum(_ v: Double?) -> JSONValue { v.map { JSONValue.number($0) } ?? .null }
private func jBool(_ v: Bool?) -> JSONValue { v.map { JSONValue.bool($0) } ?? .null }

extension AppModel {
    /// 0.6.0.12: the debug channel's `ble.whoop4_led` block: the newest three LED settings reads (GET 40 / 42 / 44, raw reply hex
    /// with the time and wear state), or no reads when none was made. Read-only; nothing here interprets the bytes.
    func whoop4LedDebug() -> JSONValue {
        var o = JObj()
        o["last_read_at"] = jDate(whoop4Raw.ledLastAt)
        o["reads"] = .array(whoop4Raw.ledReads.prefix(3).map { r in
            var e = JObj()
            e["command"] = .number(Double(r.command))
            e["at"] = jDate(r.at)
            e["worn"] = jBool(r.worn)
            e["result"] = .string(r.result)
            e["reply_hex"] = .string(r.replyHex)
            e["error"] = jStr(r.error)
            return e.value
        })
        return o.value
    }
}

/// A JSON object built one statement at a time (long dictionary literals of mixed calls are slow to type-check).
private struct JObj {
    private var d: [String: JSONValue] = [:]
    subscript(key: String) -> JSONValue {
        get { d[key] ?? .null }
        set { d[key] = newValue }
    }
    var value: JSONValue { JSONValue.object(d) }
}

/// ISO 8601 with the phone's offset, as the PC's timestamp checks require.
private func jDate(_ d: Date?) -> JSONValue {
    guard let d else { return .null }
    let f = ISO8601DateFormatter()
    f.timeZone = .current
    f.formatOptions = [.withInternetDateTime]
    return .string(f.string(from: d))
}

private func jText(_ d: Date?) -> String {
    if case .string(let s) = jDate(d) { return s }
    return "-"
}

// MARK: - The commands

extension AppModel {
    /// Runs one command on the main actor; the dispatcher has already applied the time limit and the one-at-a-time rule.
    func runRemoteDebug(_ command: RemoteDebug.Command) async -> RemoteDebug.Outcome {
        remoteDebug.setBusy(true)
        defer { remoteDebug.setBusy(false) }
        guard let kind = command.known else { return .failure("unknown kind '\(command.kind)'") }
        switch kind {
        case .logs: return await debugLogs(command)
        case .status: return await debugStatus()
        case .pullHistory: return debugPullHistory()
        case .syncNow: return await debugSyncNow()
        case .runNight: return await debugRunNight(command)
        case .readStrapSettings: return await debugReadStrapSettings()
        case .ble:
            switch await RingBridge.shared.run(command.args) {
            case .ok(let v): return .success(v)
            case .fail(let why): return .failure(why)
            }
        }
    }

    /// T10010: the three lines the 5-minute status post carries besides the lifecycle log.
    func statusExtras() -> StatusExtras {
        let night = RawNightLog.current().summary(now: clock.now, calendar: calendar,
                                                  r20Wanted: settings.rawOpticalOn && !isSample,
                                                  r21Wanted: settings.rawMotionOn && !isSample)
        return StatusExtras(rawNight: night ?? "nothing counted yet (switch raw optical or raw motion on)",
                            launchTiming: LaunchTimer.summary(),
                            batteryLearner: BatteryLearnerSummary.line(batteryLearned, calendar: calendar),
                            healthQueue: StorageNotes.shared.summary)
    }

    // MARK: logs

    private func debugSettings() -> JSONValue {
        var o = JObj()
        o["raw_optical_on"] = .bool(settings.rawOpticalOn)
        o["raw_optical_nights_only"] = .bool(settings.rawOpticalNightsOnly)
        o["raw_optical_in_workout"] = .bool(settings.rawOpticalInWorkout)
        o["raw_optical_when_still"] = .bool(settings.rawOpticalWhenStill)
        o["raw_motion_on"] = .bool(settings.rawMotionOn)
        o["keep_raw_on_strap"] = .bool(settings.keepRawOnStrap)
        o["hand_back_to_whoop"] = .bool(settings.handBackToWhoop)
        o["sample_data"] = .bool(settings.sampleData)
        return o.value
    }

    private func backgroundRunsText() -> String {
        var lines: [String] = []
        for r in BackgroundRunLog.all() {
            var line = "\(jText(r.start)) | \(r.role) | end \(jText(r.end)) | \(r.outcome ?? "did not finish") | cpu "
            line += r.cpuSeconds.map { String(format: "%.1f s", $0) } ?? "-"
            if let note = r.note { line += " | \(note)" }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    private func debugLogs(_ command: RemoteDebug.Command) async -> RemoteDebug.Outcome {
        // The files together must stay under the PC's 6 MB upload cap (debug.py MAX_FILE_BYTES): 1.4 MB each at most.
        let cap = min(max(command.int("max_kb") ?? 1400, 20), 1400) * 1000
        let strapLog = services.strap.log
        let computeLines = ComputeLog.shared.lines()
        let computeText = "epoch|kind|text (epoch = seconds since 1970)\n" + computeLines.joined(separator: "\n")
        var files: [RemoteDebug.File] = []
        files.append(RemoteDebug.File(name: "strap-log.txt", text: RemoteDebug.tail(strapLog.joined(separator: "\n"), maxBytes: cap)))
        // 0.6.0.11: the WHOOP 4.0 link's own log (bond, firmware, clock, events, history, stop buzzing)
        files.append(RemoteDebug.File(name: "whoop4-log.txt",
                                      text: RemoteDebug.tail(services.whoop4.log.joined(separator: "\n"), maxBytes: cap)))
        files.append(RemoteDebug.File(name: "compute-log.txt", text: RemoteDebug.tail(computeText, maxBytes: cap)))
        files.append(RemoteDebug.File(name: "lifecycle-log.txt", text: RemoteDebug.tail(lifecycle.logText(), maxBytes: cap)))
        files.append(RemoteDebug.File(name: "background-runs.txt", text: RemoteDebug.tail(backgroundRunsText(), maxBytes: cap)))
        let extras = statusExtras()
        var names: [JSONValue] = []
        for f in files { names.append(JSONValue.string(f.name)) }
        var o = JObj()
        o["app_version"] = .string(AppBundle.version)
        o["now"] = jDate(clock.now)
        o["raw_night"] = jStr(extras.rawNight)
        o["launch_timing"] = jStr(extras.launchTiming)
        o["battery_learner"] = jStr(extras.batteryLearner)
        o["health_queue"] = jStr(extras.healthQueue)
        o["settings"] = debugSettings()
        o["strap_log_lines"] = .number(Double(strapLog.count))
        o["compute_log_lines"] = .number(Double(computeLines.count))
        o["files"] = .array(names)
        return .success(o.value, files: files)
    }

    // MARK: status

    private func linkWords(_ s: StrapLinkState) -> String {
        switch s {
        case .bluetoothOff: return "bluetooth off"
        case .unauthorized: return "bluetooth not allowed"
        case .idle: return "idle"
        case .scanning: return "scanning"
        case .connecting: return "connecting"
        case .bonding: return "bonding"
        case .handshaking: return "handshaking"
        case .ready: return "ready"
        case .downloadingHistory: return "downloading history"
        case .disconnected(let reason): return "disconnected" + (reason.map { ": \($0)" } ?? "")
        }
    }

    private func debugStatus() async -> RemoteDebug.Outcome {
        let now = clock.now
        let strap = services.strap
        let on4 = StrapDeviceChoice.stored == .whoop4      // WHOOP4-WIRE: the selected device's link is the one described
        let state: StrapLinkState = on4 ? services.whoop4.state : strap.state

        // BLE and the history download.
        var handshakeDone = false
        var downloading = keepUp.pulling
        var progress = JObj()
        var progressKnown = false
        switch state {
        case .ready:
            handshakeDone = true
        case .downloadingHistory(let p):
            handshakeDone = true
            downloading = true
            progressKnown = true
            var pct: Double?
            if let first = p.firstTs, let newest = p.newestTs, let target = p.targetTs, target > first {
                pct = min(100, max(0, Double(newest - first) / Double(target - first) * 100))
            }
            progress["started_at"] = jDate(p.startedAt)
            progress["chunks_stored"] = .number(Double(p.chunksStored))
            progress["records_stored"] = .number(Double(p.recordsStored))
            progress["percent"] = jNum(pct)
            progress["last_ack"] = jStr(p.lastAck?.rawValue)
            progress["last_ack_at"] = jDate(p.lastAckAt)
            progress["newest_ts"] = jNum(p.newestTs)
            progress["target_ts"] = jNum(p.targetTs)
        default:
            break
        }
        let last = on4 ? services.whoop4.status.lastHistory : strap.link?.lastHistory
        let endReason: String? = last.map { String(describing: $0.endReason) }
        var history = JObj()
        history["running"] = .bool(downloading)
        history["keepup_pull_started_at"] = jDate(keepUp.pullStartedAt)
        history["keepup_last_pull_at"] = jDate(keepUp.lastPullAt)
        history["progress"] = progressKnown ? progress.value : JSONValue.null
        history["runs_today"] = .number(Double(keepUp.stats.pulls))
        history["background_runs_today"] = .number(Double(keepUp.stats.backgroundPulls))
        history["last_result"] = jStr(keepUp.stats.lastResult)
        history["last_end_reason"] = jStr(endReason)
        history["last_end_at"] = jDate(last?.endedAt)
        history["last_chunks_acked"] = jNum(last?.chunksAcked)
        history["last_records_inserted"] = jNum(last?.recordsInserted)

        var ble = JObj()
        ble["link_state"] = .string(linkWords(state))
        ble["device"] = .string(on4 ? "whoop4" : "mg_or_none")
        ble["link_started"] = .bool(selectedHistoryLink != nil)
        ble["handshake_done"] = .bool(handshakeDone)
        ble["bonded"] = jBool(on4 ? services.whoop4.status.bonded : strap.info?.bonded)
        ble["strap_firmware"] = jStr(on4 ? services.whoop4.status.firmware : strap.info?.firmware)
        ble["strap_battery_percent"] = jNum(selectedStrapBatteryPercent)
        ble["strap_clock_offset_s"] = jNum(on4 ? services.whoop4.status.clockOffsetSeconds : strap.info?.clockOffsetSeconds)
        if on4 { ble["whoop4_led"] = whoop4LedDebug() }      // 0.6.0.12: the last LED settings reads (raw hex), read-only

        // Streams: live counters, plus R18 from the store (the newest second stored in the last half hour).
        let to = Int64(now.timeIntervalSince1970)
        let r18rows = (try? await services.store.r18Seconds(from: to - 1800, to: to, strapId: nil)) ?? []
        let r18newest: Date? = r18rows.map(\.ts).max().map { Date(timeIntervalSince1970: TimeInterval($0)) }
        let raw = RawNightLog.current()
        let ro = rawOpticalStatus
        let rm = rawMotionStatus
        var hr = JObj()
        hr["last_frame_at"] = jDate(liveBuffer.lastBeatAt)
        var r20 = JObj()
        r20["switch_on"] = .bool(settings.rawOpticalOn)
        r20["streaming"] = .bool(ro.on)
        r20["frames_since_on"] = .number(Double(ro.frames))
        r20["last_frame_at"] = jDate(ro.lastFrameAt)
        r20["last_minute_with_frame"] = jDate(raw.r20.last.map { Date(timeIntervalSince1970: TimeInterval($0 * 60)) })
        r20["stopped_reason"] = jStr(ro.stoppedReason)
        var r21 = JObj()
        r21["switch_on"] = .bool(settings.rawMotionOn)
        r21["streaming"] = .bool(rm.on)
        r21["seconds_since_on"] = .number(Double(rm.seconds))
        r21["last_frame_at"] = jDate(rm.lastSecondAt)
        r21["last_minute_with_frame"] = jDate(raw.r21.last.map { Date(timeIntervalSince1970: TimeInterval($0 * 60)) })
        r21["stopped_reason"] = jStr(rm.stoppedReason)
        var r18 = JObj()
        r18["newest_stored_in_last_30_min"] = jDate(r18newest)
        var streams = JObj()
        streams["hr_live"] = hr.value
        streams["r20_raw_optical"] = r20.value
        streams["r21_raw_motion"] = r21.value
        streams["r18_history_seconds"] = r18.value

        // Sync queue.
        let report = try? await services.store.storageReport()
        var sync = JObj()
        sync["state"] = .string("\(syncStatus.state)")
        sync["unsynced_days"] = jNum(syncStatus.unsyncedDays)
        sync["last_synced_at"] = jDate(syncStatus.lastSynced)
        sync["error"] = jStr(syncStatus.error)
        sync["outbox_bytes"] = jNum(report?.outboxBytes)
        sync["raw_frames_unconfirmed"] = jNum(report?.rawFramesUnconfirmed)
        sync["raw_frame_bytes"] = jNum(report?.rawFrameBytes)

        // Memory and CPU.
        let proc = ProcessUsage.sample()
        var memory = JObj()
        memory["footprint_bytes"] = jNum(proc.memoryBytes)
        memory["available_to_app_bytes"] = .number(Double(os_proc_available_memory()))
        memory["cpu_user_s"] = .number(proc.cpuUserSeconds)
        memory["cpu_system_s"] = .number(proc.cpuSystemSeconds)
        memory["thermal"] = jStr(proc.thermalState)
        memory["low_power_mode"] = jBool(proc.lowPowerMode)
        memory["process_started_at"] = jDate(proc.launchedAt)

        // Phone battery (monitoring is switched on for the read only, as LifecycleRecorder does).
        let device = UIDevice.current
        let wasMonitoring = device.isBatteryMonitoringEnabled
        device.isBatteryMonitoringEnabled = true
        let level = device.batteryLevel
        let charging = device.batteryState == .charging || device.batteryState == .full
        device.isBatteryMonitoringEnabled = wasMonitoring
        var battery = JObj()
        if level >= 0 { battery["level_percent"] = .number((Double(level) * 100).rounded()) }
        battery["charging"] = .bool(charging)

        var o = JObj()
        o["app_version"] = .string(AppBundle.version)
        o["now"] = jDate(now)
        o["scene_phase"] = .string(appActive ? "active" : "background")
        o["ble"] = ble.value
        o["streams"] = streams.value
        o["history_download"] = history.value
        o["sync"] = sync.value
        o["memory"] = memory.value
        o["phone_battery"] = battery.value
        o["wake_chain_running"] = .bool(WakeChainState.running)
        o["health_sync"] = await debugHealthSync()
        // 0.6.0.10: does the phone see the Watch app, and how many recordings wait / went to the PC
        let ws = WatchReceiver.shared.status()
        var watch = JObj()
        watch["paired"] = jBool(ws["paired"] as? Bool)
        watch["watch_app_installed"] = jBool(ws["watch_app_installed"] as? Bool)
        watch["inbox_waiting"] = jNum(ws["inbox_waiting"] as? Int)
        watch["uploaded"] = jNum(ws["uploaded"] as? Int)
        o["watch"] = watch.value
        // 0.6.0.11: which strap is chosen, and the 4.0 link's state and status
        let w4 = services.whoop4
        var whoop4 = JObj()
        whoop4["device_choice"] = .string(StrapDeviceChoice.stored == .whoop4 ? "whoop4" : "mg_or_none")
        whoop4["link_state"] = .string(linkWords(w4.state))
        whoop4["status_line"] = .string(w4.statusLine)
        whoop4["bonded"] = .bool(w4.status.bonded)
        whoop4["firmware"] = jStr(w4.status.firmware)
        whoop4["battery_percent"] = jNum(w4.status.batteryPercent)
        whoop4["clock_offset_s"] = jNum(w4.status.clockOffsetSeconds)
        o["whoop4"] = whoop4.value
        return .success(o.value)
    }

    /// 0.6.0.7: is HealthKit background delivery working? Observers (when and at which launch kind), the last delivery per
    /// type, the last read error and what waits for unlock, the last read and the last time the PC took a batch.
    private func debugHealthSync() async -> JSONValue {
        var o = JObj()
        let reg = HealthObserverLaunch.record
        o["observers_registered_at"] = jDate(reg.at)
        o["observers_launch_kind"] = jStr(reg.launchKind)
        o["observer_types"] = jNum(reg.typeCount)
        o["unlock_runs"] = .number(Double(HealthObserverLaunch.unlockRuns))
        // Nov 5 2026: what iOS answered to enableBackgroundDelivery per type, and whether the stored PC address is a name or an IP.
        let bgDelivery = HealthBackgroundDeliveryLog.shared.summary()
        var bgd = JObj()
        bgd["enabled"] = .array(bgDelivery.enabled.map { JSONValue.string($0) })
        var refused = JObj()
        for (name, why) in bgDelivery.refused.sorted(by: { $0.key < $1.key }) { refused[name] = .string(why) }
        bgd["refused"] = refused.value
        o["background_delivery"] = bgd.value
        let creds = try? KeychainCredentialStore().load()
        o["pc_address_kind"] = jStr(PCAddressKind.of(host: creds?.baseURL.host)?.rawValue)     // "name" | "ip" | nil (not paired)
        o["pc_tailscale_ip_known"] = .bool(creds?.tailscaleIP != nil)
        guard let auto = services.healthAuto else {
            o["available"] = .bool(false)
            return o.value
        }
        let st = await auto.status()
        var delivery = JObj()
        for (id, at) in (st.lastDelivery ?? [:]).sorted(by: { $0.key < $1.key }) {
            delivery[id.replacingOccurrences(of: "HKQuantityTypeIdentifier", with: "")
                .replacingOccurrences(of: "HKCategoryTypeIdentifier", with: "")] = jDate(at)
        }
        o["last_delivery_per_type"] = delivery.value
        o["last_read_error"] = jStr(st.lastReadError)
        o["last_read_error_at"] = jDate(st.lastReadErrorAt)
        o["waiting_for_unlock"] = .array((st.lockedTypes ?? []).map { JSONValue.string($0) })
        // Nov 5 2026: `last_read` was only the anchored history pull ("Oct 17" while the observer read hourly). Two times now.
        o["last_history_read"] = jDate(st.lastHistoryRead)
        o["last_recent_read"] = jDate(st.lastRecentRead)
        o["last_reached_pc"] = jDate(st.lastReached)
        o["queued_batches"] = jNum(st.queuedBatches)
        o["last_problem"] = jStr(st.lastProblem)
        return o.value
    }

    // MARK: actions

    private func debugPullHistory() -> RemoteDebug.Outcome {
        let r = debugPullHistoryNow()
        var o = JObj()
        o["started"] = .bool(r.started)
        o["detail"] = .string(r.why)
        return r.started ? .success(o.value) : .failure(r.why, result: o.value)
    }

    private func debugSyncNow() async -> RemoteDebug.Outcome {
        guard !isSample else { return .failure("sample data is on — sync is off") }
        let coordinator = services.syncCoordinator
        let outcome = await SyncGrace.run("mg.debug.sync") { await coordinator.syncUntilDrained() }
        syncStatus = await services.sync.refreshStatus()
        let ok = outcome.result == .synced || outcome.result == .nothingToSend
        var o = JObj()
        o["result"] = .string(outcome.result.rawValue)
        o["detail"] = jStr(outcome.detail)
        o["bytes_sent"] = jNum(outcome.delivered.map { Int($0.bytes) })
        o["results_fetched"] = .number(Double(outcome.resultsFetched))
        return ok ? .success(o.value) : .failure(outcome.detail ?? outcome.result.rawValue, result: o.value)
    }

    private func debugRunNight(_ command: RemoteDebug.Command) async -> RemoteDebug.Outcome {
        guard !isSample else { return .failure("sample data is on") }
        let day: LocalDay
        if let text = command.string("day") {
            guard let parsed = LocalDay(iso: text) else { return .failure("day must be YYYY-MM-DD, got '\(text)'") }
            day = parsed
        } else {
            day = LocalDay(date: clock.now, calendar: calendar)
        }
        guard (try? KeychainCredentialStore().load()) != nil else { return .failure("no PC is paired") }
        guard !WakeChainState.running else { return .failure("the wake chain is already running") }
        WakeChainState.running = true                       // runWakeChain clears it when the chain ends
        let started = clock.now
        let outcome = await runWakeChain(seen: started, day: day)
        let since = started.timeIntervalSince1970 - 1
        var logLines: [JSONValue] = []
        for line in ComputeLog.shared.lines().suffix(300) {
            let stamp = line.prefix(while: { (ch: Character) -> Bool in ch != "|" })
            if (Double(stamp) ?? 0) >= since { logLines.append(JSONValue.string(line)) }
        }
        var steps: [JSONValue] = []
        for step in outcome.steps {
            var one = JObj()
            one["name"] = .string(step.name)
            one["seconds"] = .number(step.seconds)
            steps.append(one.value)
        }
        var o = JObj()
        o["day"] = .string(day.iso)
        o["delivered"] = .bool(outcome.delivered)
        o["total_seconds"] = .number(outcome.totalSeconds)
        o["stopped_at"] = jStr(outcome.stoppedAt)
        o["steps"] = .array(steps)
        o["log"] = .array(Array(logLines.suffix(80)))
        return outcome.delivered ? .success(o.value) : .failure(outcome.stoppedAt ?? "the chain did not deliver", result: o.value)
    }

    private func debugReadStrapSettings() async -> RemoteDebug.Outcome {
        guard !isSample else { return .failure("sample data is on — the strap is not read") }
        // WHOOP4-WIRE: the snapshot reads the 5/MG's flag list (117/118/128); with the 4.0 selected it would only describe the idle
        // MG link. The 4.0's flags differ (noop PROTOCOL_WHOOP4: 11 flags, unreliable reads): use the Command test page for those.
        guard StrapDeviceChoice.stored != .whoop4 else {
            return .failure("WHOOP 4.0 is the selected device: read_strap_settings reads the 5/MG's flags only (use Settings > Command test)")
        }
        switch await services.strap.readFlagSnapshot() {
        case .success(let snap):
            flagSnapshot = snap
            var readings: [JSONValue] = []
            for r in snap.readings {
                var one = JObj()
                one["key"] = .string(r.key)
                one["value"] = jStr(r.value)
                one["status"] = .string(r.status)
                readings.append(one.value)
            }
            var o = JObj()
            o["read_at"] = jDate(snap.readAt)
            o["firmware"] = jStr(snap.firmware)
            o["announced_count"] = jNum(snap.announcedCount)
            o["walk_stop"] = .string(snap.walkStop)
            o["readings"] = .array(readings)
            return .success(o.value)
        case .failure(let why):
            return .failure(why.text)
        }
    }
}
