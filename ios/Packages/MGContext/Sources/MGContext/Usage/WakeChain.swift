import Foundation

/// T9993 (2026-10-17, Mo: "I need to see my PC-ran data when I wake up, within 10 minutes of me waking up and moving
/// around"). The chain that runs when the strap's sleep flag goes awake after a night:
///
///   history  -> download what the strap still holds of the night;
///   compute  -> the phone's night pipeline (the day drop needs its `wake_time`);
///   upload   -> send the night to the PC;
///   request  -> ask the PC to run that date's models now (POST /v1/run-night; it skips the 10 min quiet wait);
///   wait     -> poll the PC until the date is idle;
///   results  -> pull what the PC produced.
///
/// then a local notification "PC numbers are in". Every step is timed from the moment the wake was noticed and written to
/// the run log (Settings > Usage > Compute log), so a slow step is visible. A step that fails ends the chain (the log says
/// which and why); `history` and `compute` failing do not, because the night may already be on the phone. Pure over
/// injected hooks, so it is tested on Linux; the app wires the hooks to the strap link, the compute coordinator, the sync
/// engine and the PC client (AppModel+WakeChain.swift).
public enum WakeChain {
    public static let goal: TimeInterval = 10 * 60
    /// How long the chain waits for the PC to finish before it pulls what is there and says so.
    public static let pcWaitLimit: TimeInterval = 8 * 60
    public static let pollEvery: TimeInterval = 5

    public struct StepResult: Sendable, Equatable {
        public var ok: Bool
        public var detail: String
        public init(ok: Bool, detail: String) {
            self.ok = ok
            self.detail = detail
        }
    }

    /// What the PC says about the date (GET /v1/run-night `state`).
    public enum PCState: Sendable, Equatable {
        case running, queued, waiting, idle
        /// No answer (Tailscale off, PC asleep); the text says why.
        case unreachable(String)
    }

    public struct Hooks: Sendable {
        public var now: @Sendable () -> Date
        public var sleep: @Sendable (TimeInterval) async -> Void
        public var pullHistory: @Sendable () async -> StepResult
        public var computeNight: @Sendable () async -> StepResult
        public var upload: @Sendable () async -> StepResult
        public var requestPC: @Sendable () async -> StepResult
        public var pcState: @Sendable () async -> PCState
        /// Pulls the PC's results; `fetched` is how many came back.
        public var pullResults: @Sendable () async -> (result: StepResult, fetched: Int)
        public var log: @Sendable (String) -> Void
        /// "PC numbers are in", with the seconds from the wake to now.
        public var notify: @Sendable (_ secondsSinceWake: TimeInterval) async -> Void

        public init(now: @escaping @Sendable () -> Date, sleep: @escaping @Sendable (TimeInterval) async -> Void,
                    pullHistory: @escaping @Sendable () async -> StepResult,
                    computeNight: @escaping @Sendable () async -> StepResult,
                    upload: @escaping @Sendable () async -> StepResult,
                    requestPC: @escaping @Sendable () async -> StepResult,
                    pcState: @escaping @Sendable () async -> PCState,
                    pullResults: @escaping @Sendable () async -> (result: StepResult, fetched: Int),
                    log: @escaping @Sendable (String) -> Void,
                    notify: @escaping @Sendable (_ secondsSinceWake: TimeInterval) async -> Void) {
            self.now = now; self.sleep = sleep; self.pullHistory = pullHistory; self.computeNight = computeNight
            self.upload = upload; self.requestPC = requestPC; self.pcState = pcState; self.pullResults = pullResults
            self.log = log; self.notify = notify
        }
    }

    public struct Outcome: Sendable, Equatable {
        /// Step name -> seconds it took, in order.
        public var steps: [(name: String, seconds: TimeInterval)]
        public var totalSeconds: TimeInterval
        /// The PC's numbers are on the phone (results fetched after the PC finished).
        public var delivered: Bool
        /// Why the chain stopped early or what it could not do; nil when it ran through.
        public var stoppedAt: String?

        public var withinGoal: Bool { delivered && totalSeconds <= WakeChain.goal }

        public static func == (a: Outcome, b: Outcome) -> Bool {
            a.totalSeconds == b.totalSeconds && a.delivered == b.delivered && a.stoppedAt == b.stoppedAt
                && a.steps.map(\.name) == b.steps.map(\.name) && a.steps.map(\.seconds) == b.steps.map(\.seconds)
        }
    }

    /// "4:52" for 292 seconds.
    public static func clock(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded()))
        return "\(s / 60):" + (s % 60 < 10 ? "0" : "") + "\(s % 60)"
    }

    /// Runs the chain once. `seen` is when the wake was noticed (the clock the steps are timed from).
    @discardableResult
    public static func run(seen: Date, hooks h: Hooks) async -> Outcome {
        var steps: [(name: String, seconds: TimeInterval)] = []
        var stoppedAt: String?
        func since() -> TimeInterval { h.now().timeIntervalSince(seen) }

        func step(_ name: String, _ body: () async -> StepResult) async -> StepResult {
            let began = h.now()
            let r = await body()
            let took = h.now().timeIntervalSince(began)
            steps.append((name, took))
            h.log("wake chain: \(name) \(r.ok ? "done" : "FAILED") in \(clock(took)) (\(clock(since())) after the wake): \(r.detail)")
            return r
        }
        func finish(delivered: Bool) -> Outcome {
            let total = since()
            let parts = steps.map { "\($0.name) \(clock($0.seconds))" }.joined(separator: ", ")
            let end = delivered ? (total <= goal ? "PC numbers in under 10 min" : "PC numbers in, over 10 min")
                                : "stopped: \(stoppedAt ?? "unknown")"
            h.log("wake chain: \(parts.isEmpty ? "no steps" : parts) - total \(clock(total)) - \(end)")
            return Outcome(steps: steps, totalSeconds: total, delivered: delivered, stoppedAt: stoppedAt)
        }

        h.log("wake chain: wake noticed, starting")
        _ = await step("history", h.pullHistory)      // a failure here is logged, not fatal: the night may be stored already
        _ = await step("compute", h.computeNight)     // same: an older night result is still uploaded
        let up = await step("upload", h.upload)
        guard up.ok else { stoppedAt = "upload failed - \(up.detail)"; return finish(delivered: false) }
        let ask = await step("request", h.requestPC)
        guard ask.ok else { stoppedAt = "the PC did not take the request - \(ask.detail)"; return finish(delivered: false) }

        // wait for the PC to finish the date
        let waitBegan = h.now()
        var last = PCState.queued
        var polls = 0
        while true {
            last = await h.pcState()
            polls += 1
            if last == .idle || last == .waiting { break }      // waiting: nothing runs now (night not closed, or a retry)
            if h.now().timeIntervalSince(waitBegan) >= pcWaitLimit { break }
            await h.sleep(pollEvery)
        }
        let waited = h.now().timeIntervalSince(waitBegan)
        steps.append(("pc", waited))
        let waitText: String
        switch last {
        case .idle: waitText = "the PC finished after \(clock(waited)) (\(polls) check(s))"
        case .waiting: waitText = "the PC has nothing running (a night model waits for the night to close, or a retry is due) after \(clock(waited))"
        case .unreachable(let why): waitText = "the PC stopped answering (\(why)) after \(clock(waited))"
        default: waitText = "the PC was still \(last) after \(clock(waited)); pulling what is there"
        }
        h.log("wake chain: pc \(last == .idle || last == .waiting ? "done" : "NOT DONE") in \(clock(waited)) (\(clock(since())) after the wake): \(waitText)")

        let began = h.now()
        let pulled = await h.pullResults()
        let took = h.now().timeIntervalSince(began)
        steps.append(("results", took))
        h.log("wake chain: results \(pulled.result.ok ? "done" : "FAILED") in \(clock(took)) (\(clock(since())) after the wake): "
              + "\(pulled.fetched) new result(s); \(pulled.result.detail)")
        guard pulled.result.ok else { stoppedAt = "results not pulled - \(pulled.result.detail)"; return finish(delivered: false) }
        guard last == .idle || last == .waiting else {
            stoppedAt = "the PC was not finished (\(last)); \(pulled.fetched) result(s) pulled, no notification"
            return finish(delivered: false)
        }
        guard pulled.fetched > 0 else {
            stoppedAt = "the PC finished but sent no new result for this night"
            return finish(delivered: false)
        }
        await h.notify(since())
        return finish(delivered: true)
    }
}
