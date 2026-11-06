import Foundation
import MGBLE
import MGContext
import MGDomain
import MGSync

// T9993 (2026-10-17, Mo: "I need to see my PC-ran data when I wake up, within 10 minutes of me waking up and moving
// around"). When the strap's sleep flag goes awake after a night, this runs the chain in MGContext `WakeChain`: history
// download -> the phone's night pipeline -> upload -> ask the PC to run that date's models now (POST /v1/run-night) -> wait
// for the PC -> pull its results -> a silent local notification "PC numbers are in". Each step is timed and written to the
// compute log (Settings > Usage > Compute log) with the time since the wake, so a slow step is visible.
//
// "Awake" is `LiveSleepState.awake`: the strap's byte-81 flag reads awake / up for 5 minutes straight after a night it read
// asleep (SleepOnsetDetector.liveState), so the walking about is the strap's own "up" reading, not a separate motion test.
// Once per local day on success; up to three tries a day, at least 10 minutes apart, when a step fails.

@MainActor
enum WakeChainState {
    static var running = false
    static var lastCheck = Date.distantPast
    static var lastEnd = Date.distantPast
    static let dayKey = "wakechain.day"
    static let attemptsKey = "wakechain.attempts"
    static let deliveredKey = "wakechain.delivered"
    static let maxAttempts = 3
    static let retryGap: TimeInterval = 10 * 60
    /// T10007: the last decision written to the compute log, so a check that keeps reaching the same answer logs it once.
    static var lastDecision = ""
}

extension AppModel {
    /// Writes a decision of the trigger to the compute log (Settings > Usage > Compute log) when it differs from the last one.
    private func wakeChainDecision(_ text: String, trigger: String) {
        let line = "wake chain check (\(trigger)): \(text)"
        guard line != WakeChainState.lastDecision else { return }
        WakeChainState.lastDecision = line
        ComputeLog.shared.append(.note, line, at: clock.now)
    }

    /// Called from every keep-up tick (about once a minute while iOS keeps the app awake, and on live beats) and, since
    /// T10007 (2026-10-17), also when a history download that stored records finishes and from a background refresh, so the
    /// trigger does not depend on the app being alive at the minute the strap flag turns awake. Each decision is logged.
    func wakeChainCheck(trigger: String = "keep-up tick") async {
        guard !isSample, !WakeChainState.running else { return }
        let now = clock.now
        let minGap: TimeInterval = trigger == "keep-up tick" ? 120 : 15
        guard now.timeIntervalSince(WakeChainState.lastCheck) >= minGap else { return }
        WakeChainState.lastCheck = now
        guard (try? KeychainCredentialStore().load()) != nil else {                  // no PC paired: nothing to chain
            return wakeChainDecision("no PC is paired, nothing to chain", trigger: trigger)
        }
        let how: String
        if case .awake(let since) = await liveSleepState(now: now) {
            how = "the strap flag says awake since \(MGFormat.time(since, calendar: calendar))"
        } else if let w = lastInputs?.detectedWake, calendar.isDate(w, inSameDayAs: now), now.timeIntervalSince(w) < 8 * 3600 {
            // Oct 17: the app was opened at 10:11 AM, three hours after the wake; the strap flag's "awake" state holds for one
            // hour only (LiveSleepState), so the chain never started. The phone's own detected wake of today still counts.
            how = "late: the strap flag's one-hour awake state had run out; using the wake the phone detected at "
                + MGFormat.time(w, calendar: calendar)
        } else {
            return wakeChainDecision("not started: the strap flag is not awake and the phone has no wake for today", trigger: trigger)
        }
        let day = LocalDay(date: now, calendar: calendar)             // the night ends on this morning (D13)
        let defaults = UserDefaults.standard
        var attempts = 0
        if defaults.string(forKey: WakeChainState.dayKey) == day.iso {
            if defaults.bool(forKey: WakeChainState.deliveredKey) {
                return wakeChainDecision("not started: today's chain already delivered", trigger: trigger)
            }
            attempts = defaults.integer(forKey: WakeChainState.attemptsKey)
            if attempts >= WakeChainState.maxAttempts {
                return wakeChainDecision("not started: \(attempts) tries today, none left", trigger: trigger)
            }
            if now.timeIntervalSince(WakeChainState.lastEnd) < WakeChainState.retryGap {
                return wakeChainDecision("not started: the last try ended less than 10 minutes ago", trigger: trigger)
            }
        } else {
            defaults.set(day.iso, forKey: WakeChainState.dayKey)
            defaults.set(false, forKey: WakeChainState.deliveredKey)
        }
        defaults.set(attempts + 1, forKey: WakeChainState.attemptsKey)
        WakeChainState.running = true
        WakeChainState.lastDecision = ""
        ComputeLog.shared.append(.note, "wake chain: \(how) (trigger: \(trigger); try \(attempts + 1) of \(WakeChainState.maxAttempts))",
                                 at: now)
        Task { [weak self] in await self?.runWakeChain(seen: now, day: day) }
    }

    /// T10012: internal so the remote debug `run_night` can run the same chain and read how it went.
    /// `progress` (Nov 6 2026, the Process now sheet) is told when the history, compute and upload steps begin (result nil) and end.
    @discardableResult
    func runWakeChain(seen: Date, day: LocalDay,
                      progress: (@MainActor @Sendable (String, WakeChain.StepResult?) -> Void)? = nil) async -> WakeChain.Outcome {
        let clock = self.clock
        let hooks = WakeChain.Hooks(
            now: { clock.now },
            sleep: { s in try? await Task.sleep(for: .seconds(s)) },
            pullHistory: { [weak self] in
                await progress?("history", nil)
                let r = await self?.wakeChainHistory() ?? AppModel.gone
                await progress?("history", r)
                return r
            },
            computeNight: { [weak self] in
                await progress?("compute", nil)
                let r = await self?.wakeChainCompute(day: day) ?? AppModel.gone
                await progress?("compute", r)
                return r
            },
            upload: { [weak self] in
                await progress?("upload", nil)
                let r = await self?.wakeChainUpload() ?? AppModel.gone
                await progress?("upload", r)
                return r
            },
            requestPC: { [weak self] in await self?.wakeChainRequest(day: day) ?? AppModel.gone },
            pcState: { [weak self] in await self?.wakeChainPCState(day: day) ?? .unreachable("app closed") },
            pullResults: { [weak self] in
                guard let self else { return (AppModel.gone, 0) }
                return await self.wakeChainResults()
            },
            log: { line in ComputeLog.shared.append(.note, line, at: clock.now) },
            notify: { [weak self] seconds in
                _ = await self?.services.notifyCenter.pcNumbersIn(day: day.iso, seconds: seconds)
            })
        let outcome = await SyncGrace.run("mg.wakechain") { await WakeChain.run(seen: seen, hooks: hooks) }
        WakeChainState.running = false
        WakeChainState.lastEnd = clock.now
        if outcome.delivered { UserDefaults.standard.set(true, forKey: WakeChainState.deliveredKey) }
        await notifyLastNightIfReady(day: day)        // Nov 6 2026: "Last night is ready", once a day
        return outcome
    }

    nonisolated static let gone = WakeChain.StepResult(ok: false, detail: "the app was closed")

    // MARK: Steps

    /// Waits for a pull already running (the 15-min keep-up pull), then downloads what the strap still holds.
    private func wakeChainHistory() async -> WakeChain.StepResult {
        var waited = 0
        while keepUp.pulling, waited < 300 {
            try? await Task.sleep(for: .seconds(3))
            waited += 3
        }
        guard let link = selectedHistoryLink, case .ready = link.state else {
            return .init(ok: false, detail: "the strap is not connected (the night is uploaded as it is on the phone)")
        }
        keepUp.pulling = true
        keepUp.pullStartedAt = clock.now
        keepUp.pullSerial += 1
        let serial = keepUp.pullSerial
        do {
            let s = try await link.downloadHistory()
            if keepUp.pullSerial == serial { keepUp.pulling = false }
            keepUp.lastPullAt = clock.now
            return .init(ok: true, detail: "\(s.chunksAcked) chunk(s), \(s.recordsInserted) new records")
        } catch {
            if keepUp.pullSerial == serial { keepUp.pulling = false }
            return .init(ok: false, detail: StrapCoordinator.words(error))
        }
    }

    /// The phone's night pipeline for today (the day drop's `wake_time` comes from it). In the background this is the
    /// light run (T9995); in the foreground the full one.
    private func wakeChainCompute(day: LocalDay) async -> WakeChain.StepResult {
        for _ in 0..<12 {
            let report = await services.compute.runNow(.wake, days: [day])
            if report.ran { return .init(ok: report.failedDays.isEmpty, detail: report.line) }
            try? await Task.sleep(for: .seconds(5))              // another run is going; try again
        }
        return .init(ok: false, detail: "compute stayed busy for a minute")
    }

    /// A manual sync (no hold, no backoff): the night's day drop and streams go to the PC.
    private func wakeChainUpload() async -> WakeChain.StepResult {
        let outcome = await services.syncCoordinator.syncUntilDrained()
        let ok = outcome.result == .synced || outcome.result == .nothingToSend
        let sent = outcome.delivered.map { "\($0.bytes) bytes sent" } ?? "nothing new to send"
        return .init(ok: ok, detail: ok ? sent : (outcome.detail ?? outcome.result.rawValue))
    }

    private func wakeChainRequest(day: LocalDay) async -> WakeChain.StepResult {
        switch await PCNightRun.request(date: day, credentials: KeychainCredentialStore()) {
        case .state(let s): return .init(ok: true, detail: "the PC took \(day.iso) (\(s))")
        case .notStored: return .init(ok: false, detail: "the PC has no drop for \(day.iso)")
        case .notPaired: return .init(ok: false, detail: "no PC is paired")
        case .unreachable(let why): return .init(ok: false, detail: "PC not reachable: \(why)")
        case .refused(let why): return .init(ok: false, detail: "the PC refused: \(why)")
        }
    }

    private func wakeChainPCState(day: LocalDay) async -> WakeChain.PCState {
        switch await PCNightRun.state(date: day, credentials: KeychainCredentialStore()) {
        case .state(let s):
            switch s {
            case "idle": return .idle
            case "running": return .running
            case "queued": return .queued
            case "waiting": return .waiting
            default: return .unreachable("unknown state \(s)")
            }
        case .unreachable(let why): return .unreachable(why)
        case .notPaired: return .unreachable("no PC is paired")
        case .notStored: return .unreachable("the PC has no drop for \(day.iso)")
        case .refused(let why): return .unreachable(why)
        }
    }

    /// A manual sync again: its results pull (step 4 of the engine) brings back what the PC produced.
    private func wakeChainResults() async -> (result: WakeChain.StepResult, fetched: Int) {
        let outcome = await services.syncCoordinator.syncUntilDrained()
        let ok = outcome.result == .synced || outcome.result == .nothingToSend
        return (.init(ok: ok, detail: ok ? "results pulled" : (outcome.detail ?? outcome.result.rawValue)),
                outcome.resultsFetched)
    }
}
