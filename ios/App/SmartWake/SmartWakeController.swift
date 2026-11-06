import Combine
import Foundation
import MGBLE
import MGContext
import MGDomain
import MGSignal

/// Smart wake for the app and the Tonight sheet (ARCHITECTURE 4.2 `SmartWakeControlling`, 4.11; UX-SPEC 8.1).
/// WP-23 owns the instance and calls `refresh` whenever the inputs may have changed (launch, foreground, BLE restore
/// or wake, a Settings / Tonight edit, a phase change); WP-24's notification delegate routes STOP / SNOOZE_9 here.
@MainActor
public protocol SmartWakeControlling: AnyObject {
    var status: SmartWakeStatus { get }
    /// How tonight rings: AlarmKit (iOS 26+, authorized) or notification (+ the "may not wake you on Silent" line).
    var ringerKind: SmartWakeBlockState.Ringer { get }
    /// Last finished night (the Just-woke "Smart wake result" Now row; the check-in's first question).
    var lastResult: SmartWakeNightResult? { get }
    /// Plans / arms / resumes / finishes tonight. Idempotent: the same settings never re-arm a night.
    func refresh(_ request: SmartWakeRequest) async
    /// Smart wake switched off or "must be up by" cleared: cancels the backstop and stops watching.
    func disarm(reason: String) async
    /// STOP (notification action) — silences the ring and its repeats, records the night.
    func stop() async
    /// SNOOZE_9 (notification action).
    func snooze(minutes: Int) async
}

/// The controller. iPhone only — it sends nothing to the strap; the normal wake's strap layer (buzz, the strap's own
/// alarm in slot 1, repeat until moving) is App/Alarms, allowed since CLAUDE.md rule 5 changed on 2026-10-11.
///
/// Night flow (ARCHITECTURE 4.11):
/// 1. **Plan + backstop at arming**: `ALG035.plan` (no "must be up by" → no plan); the backstop at L is scheduled at
///    once with AlarmKit (iOS 26+) or a time-sensitive notification, so it rings even if the app is killed.
/// 2. **Watch** from bedtime − `watchLeadMinutes` (or arming, if later): `setRealtime(hr: true, motion: true)` (D8: the
///    BLE stream keeps the app alive), `liveBeats` (HR + R-R) and `liveMotion` (gravity; empty in B1 → heart-only) feed
///    the `LiveStager`; every closed 30-s epoch goes to `SmartWakeSession` (the golden-tested fire rule).
/// 3. **Ring** at the first 2 qualifying epochs inside the window: AlarmKit now + 5 s, or the notification series;
///    then the backstop is cancelled (in that order — Mo is never without an alarm).
/// 4. **Record** the night (`SmartWakeNightResult`: outcome, cause, battery at bed vs wake) for the morning row.
///    Strap disconnected → no live ring, only the backstop, and the morning says "couldn't watch — strap disconnected
///    at 03:12". If iOS kills the app overnight, the last provisional outcome (saved each epoch) is the result.
@MainActor
public final class SmartWakeController: ObservableObject, SmartWakeControlling {
    @Published public private(set) var status: SmartWakeStatus
    @Published public private(set) var lastResult: SmartWakeNightResult?

    public var ringerKind: SmartWakeBlockState.Ringer { ringer?.kind ?? SmartWakeRingers.preferredKind }

    private let strap: any StrapLinking
    private let store: any SmartWakeStore
    private let clock: any MGDomain.Clock
    private let config: SmartWakeConfig
    private let makeRinger: () async -> any SmartWakeRinging
    private let log: (String) -> Void

    private var ringer: (any SmartWakeRinging)?
    private var armed: SmartWakeArmedState?
    private var watchFrom: Date?
    private var stager: LiveStager?
    private var session: SmartWakeSession?
    private var tasks: [Task<Void, Never>] = []
    private var ringInFlight = false
    private var finishing = false

    /// - Parameters:
    ///   - strap: the app's `StrapLink` (or `MockStrapLink` in tests).
    ///   - store: defaults to `SmartWakeDefaultsStore()` (UserDefaults).
    ///   - makeRinger: defaults to `SmartWakeRingers.make` (AlarmKit when available and allowed, else notifications).
    public init(strap: any StrapLinking, store: (any SmartWakeStore)? = nil, clock: any MGDomain.Clock = SystemClock(),
                config: SmartWakeConfig = .standard, makeRinger: (() async -> any SmartWakeRinging)? = nil,
                log: @escaping (String) -> Void = { _ in }) {
        let st = store ?? SmartWakeDefaultsStore()
        let saved = st.loadArmed()
        self.strap = strap
        self.store = st
        self.clock = clock
        self.config = config
        self.makeRinger = makeRinger ?? { await SmartWakeRingers.make(config: config) }
        self.log = log
        self.armed = saved
        self.lastResult = st.loadResult()
        if let a = saved {
            self.status = .armed(plan: a.plan, watchFrom: Date(timeIntervalSince1970: TimeInterval(a.plan.windowStart)))
        } else {
            self.status = .off(reason: "Smart wake has no plan yet")
        }
    }

    // MARK: SmartWakeControlling

    public func refresh(_ request: SmartWakeRequest) async {
        let now = clock.now
        if let a = armed, unix(now) >= a.plan.windowEnd {
            await finish(a, now: now)                       // the morning: the night is over
        }
        guard request.enabled else {
            await disarmIfArmed(reason: "Smart wake is off")
            return
        }
        guard let L = request.mustBeUpBy else {
            await disarmIfArmed(reason: "No 'must be up by' for tomorrow, so no wake plan (set one in Tonight)")
            return
        }
        let req = SmartWakeArmedRequest(mustBeUpBy: unix(L), windowMinutes: request.windowMinutes,
                                        needMinutes: request.needMinutes, options: request.options)
        let nightId = "\(req.mustBeUpBy)"
        if let r = lastResult, r.nightId == nightId {
            status = .done(r)                               // already woke for this L (e.g. Stop before L)
            return
        }
        if var a = armed, a.nightId == nightId, a.request.windowMinutes == req.windowMinutes,
           (a.request.options ?? .standard) == request.options {
            // Same night and window: never re-plan (a re-plan at 01:00 would read as "past bedtime"). A newer need
            // (ALG-115 updates through the evening) is kept for the next watch start.
            if a.request.needMinutes != req.needMinutes && stager == nil {
                a.request.needMinutes = req.needMinutes
                armed = a
                store.saveArmed(a)
            }
            if watchFrom == nil {
                watchFrom = max(now, request.bedtime.addingTimeInterval(-config.watchLeadMinutes * 60))
            }
            await startWatchingIfDue(now: now)              // same night, same settings: resume
            return
        }
        if armed != nil { await disarm(reason: "Smart wake settings changed") }
        let plan = ALG035.plan(enabled: true, mustBeUpBy: req.mustBeUpBy, windowMinutes: request.windowMinutes,
                               armedAt: unix(now), bedtime: unix(request.bedtime),
                               asleepAround: request.asleepAround.map(unix), needMinutes: request.needMinutes,
                               options: request.options)
        guard case .success(let p) = plan else {
            status = .off(reason: plan.missingReason ?? "No wake plan")
            return
        }
        let r = await ensureRinger()
        guard await r.authorize() else {
            status = .off(reason: r.kind == .alarmKit ? "Alarms are not allowed for MG in iOS Settings › MG › Alarms"
                          : "Notifications are off for MG in iOS Settings › MG › Notifications, so smart wake can't ring")
            return
        }
        let ids: [String]
        do {
            ids = try await r.scheduleBackstop(plan: p)
        } catch {
            status = .off(reason: "Couldn't schedule the wake alarm (\(error.localizedDescription))")
            log("smart wake: backstop failed — \(error)")
            return
        }
        let a = SmartWakeArmedState(nightId: nightId, plan: p, request: req, backstopIds: ids, ringIds: [],
                                    ringer: r.kind.rawValue, batteryAtBed: nil, provisional: nil, disconnectedAt: nil,
                                    rang: false)
        armed = a
        store.saveArmed(a)
        let from = max(now, request.bedtime.addingTimeInterval(-config.watchLeadMinutes * 60))
        watchFrom = from
        status = .armed(plan: p, watchFrom: from)
        log("smart wake: armed for \(nightId), window \(p.windowStart)–\(p.windowEnd), backstop ids \(ids)")
        await startWatchingIfDue(now: now)
    }

    public func disarm(reason: String) async {
        if let a = armed {
            await ringer(for: a).cancel(ids: a.backstopIds + a.ringIds)
        }
        await stopWatching()
        armed = nil
        store.clearArmed()
        status = .off(reason: reason)
    }

    public func stop() async {
        guard let a = armed else { return }
        await ringer(for: a).cancel(ids: a.ringIds + a.backstopIds)
        await finish(a, now: clock.now)
    }

    public func snooze(minutes: Int) async {
        guard var a = armed else { return }
        let r = ringer(for: a)
        await r.cancel(ids: a.ringIds + a.backstopIds)
        do {
            a.ringIds = try await r.snooze(minutes: minutes, plan: a.plan)
            a.backstopIds = []
            armed = a
            store.saveArmed(a)
            status = .ringing(at: clock.now.addingTimeInterval(Double(minutes) * 60), smart: false)
        } catch {
            log("smart wake: snooze failed — \(error)")
        }
    }

    // MARK: watching

    private func startWatchingIfDue(now: Date) async {
        guard var a = armed, stager == nil, !a.rang, let from = watchFrom, now >= from,
              unix(now) < a.plan.windowEnd else { return }
        let st = LiveStager(start: unix(now))                     // set before any await: one watcher per night
        stager = st
        session = SmartWakeSession(plan: a.plan, needMinutes: a.request.needMinutes)
        do {
            try await strap.setRealtime(hr: true, motion: true)   // D8: 3 + 63, re-applied by StrapLink on reconnect
        } catch {
            log("smart wake: realtime toggles not set yet (\(error)); StrapLink applies them when ready")
        }
        guard stager === st, let current = armed else { return } // disarmed while the toggles were being set
        a = current
        a.batteryAtBed = a.batteryAtBed ?? strap.info?.batteryPercent
        armed = a
        store.saveArmed(a)
        status = .watching(plan: a.plan)
        let beats = strap.liveBeats
        let motion = strap.liveMotion
        tasks.append(Task { [weak self] in
            for await b in beats {
                guard let self else { return }
                self.take(beat: b)
            }
        })
        tasks.append(Task { [weak self] in
            for await m in motion {
                guard let self else { return }
                self.stager?.addGravity(ts: m.ts, gx: m.gx, gy: m.gy, gz: m.gz)
            }
        })
        let every = UInt64(max(1, config.tickSeconds) * 1_000_000_000)
        tasks.append(Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: every)
                guard let self else { return }
                self.tick()
            }
        })
        log("smart wake: watching from \(st.epoch0)")
    }

    private func stopWatching() async {
        for t in tasks { t.cancel() }
        tasks = []
        let wasWatching = stager != nil
        stager = nil
        session = nil
        if wasWatching && config.realtimeOffAfterWake {
            try? await strap.setRealtime(hr: false, motion: false)
        }
    }

    private func take(beat b: LiveBeat) {
        guard let st = stager else { return }
        let ts = Int64(b.at.timeIntervalSince1970.rounded(.down))
        st.addHeartRate(ts: ts, bpm: b.bpm)
        if !b.rrMs.isEmpty { st.addBeats(ts: ts, rrMs: b.rrMs) }
        tick()
    }

    /// Closes finished epochs (strap clock = phone clock + the readback offset), runs the fire rule, saves the
    /// provisional outcome, and finishes the night at L. Ticks come from beats (~1 Hz) and a timer, so data gaps still
    /// close as "." epochs while the app is alive. (A ring for a stale epoch cannot happen: the app only sleeps when no
    /// BLE data arrives, and epochs without data never qualify.)
    private func tick() {
        guard let st = stager, var s = session, var a = armed else { return }
        let now = clock.now
        let strapNow = Int64((now.timeIntervalSince1970 + (strap.info?.clockOffsetSeconds ?? 0)).rounded(.down))
        var changed = false
        let linkUp: Bool
        switch strap.state {
        case .ready, .downloadingHistory: linkUp = true
        default: linkUp = false
        }
        if !linkUp && a.disconnectedAt == nil {
            a.disconnectedAt = now
            changed = true
        } else if linkUp && a.disconnectedAt != nil {
            a.disconnectedAt = nil
            changed = true
        }
        let L = a.plan.windowEnd
        let through = min(strapNow - config.closeGraceSeconds, L)
        let closed = st.close(through: through)
        var rangNow = false
        for ep in closed where !s.hasRung {
            if s.observe(ep) {
                rangNow = true
                break
            }
        }
        if !closed.isEmpty { changed = true }
        session = s
        if !a.rang { a.provisional = s.outcome(lastDataTs: st.lastDataTs, motionEpochs: st.motionEpochs) }
        if changed {
            armed = a
            store.saveArmed(a)
        }
        if rangNow, let o = a.provisional {
            Task { await self.ringSmart(o) }
        } else if strapNow - config.closeGraceSeconds >= L {
            Task { await self.finish(a, now: now) }
        }
    }

    private func ringSmart(_ o: SmartWakeOutcome) async {
        guard !ringInFlight, var a = armed, !a.rang, let r = ringer else { return }
        ringInFlight = true
        defer { ringInFlight = false }
        do {
            a.ringIds = try await r.ringNow(plan: a.plan, outcome: o)
        } catch {
            log("smart wake: ring failed (\(error)) — the backstop at L stays")
            return
        }
        await r.cancel(ids: a.backstopIds)                   // only after the ring is in place
        a.backstopIds = []
        a.rang = true
        a.provisional = o
        armed = a
        store.saveArmed(a)
        record(a, outcome: o, now: clock.now)
        status = .ringing(at: clock.now, smart: true)
        log("smart wake: rang at \(o.at ?? 0) (\(o.reason?.rawValue ?? "?"))")
    }

    /// Ends the night: records the result once (a smart ring is recorded when it rings), stops watching, clears the
    /// armed state. Ringing that is still going is left to Stop (AlarmKit's own Stop, or the notification action).
    private func finish(_ a: SmartWakeArmedState, now: Date) async {
        guard !finishing, armed?.nightId == a.nightId else { return }
        finishing = true
        defer { finishing = false }
        let current = armed ?? a
        if lastResult?.nightId != current.nightId {
            let outcome: SmartWakeOutcome
            if let s = session, let st = stager {
                outcome = s.outcome(lastDataTs: st.lastDataTs, motionEpochs: st.motionEpochs)
            } else if let p = current.provisional {
                outcome = p
            } else {
                outcome = SmartWakeSession(plan: current.plan, needMinutes: current.request.needMinutes)
                    .outcome(lastDataTs: nil, motionEpochs: 0)
            }
            record(current, outcome: outcome, now: now)
        }
        await stopWatching()
        armed = nil
        store.clearArmed()
        if let r = lastResult { status = .done(r) }
    }

    private func record(_ a: SmartWakeArmedState, outcome: SmartWakeOutcome, now: Date) {
        let result = SmartWakeNightResult(nightId: a.nightId, plan: a.plan, outcome: outcome,
                                          cause: a.disconnectedAt != nil ? .disconnected : .noData,
                                          batteryAtBed: a.batteryAtBed, batteryAtWake: strap.info?.batteryPercent,
                                          ringer: a.ringer, paramsVersion: SleepLiveParams.version, recordedAt: now)
        lastResult = result
        store.saveResult(result)
    }

    private func disarmIfArmed(reason: String) async {
        if armed != nil { await disarm(reason: reason) } else { status = .off(reason: reason) }
    }

    /// The ringer that scheduled this night's ids (after an app restart the live `ringer` may be unset or differ).
    private func ringer(for a: SmartWakeArmedState) -> any SmartWakeRinging {
        if let r = ringer, r.kind.rawValue == a.ringer { return r }
        #if canImport(AlarmKit)
        if a.ringer == SmartWakeBlockState.Ringer.alarmKit.rawValue, #available(iOS 26.0, *) {
            return SmartWakeAlarmKitRinger(leadSeconds: config.ringLeadSeconds)
        }
        #endif
        return SmartWakeNotificationRinger(config: config)
    }

    private func ensureRinger() async -> any SmartWakeRinging {
        if let r = ringer { return r }
        let r = await makeRinger()
        ringer = r
        return r
    }

    private func unix(_ d: Date) -> Int64 { Int64(d.timeIntervalSince1970.rounded(.down)) }
}
