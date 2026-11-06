import Foundation
import MGDomain
import UIKit

// NightSoundsController (WP-26): the one object the app talks to. It owns the "Listen tonight" switch, decides with
// NightSoundsPolicy when the listener may run (bedtime -> wake window, strap awake 30 min, phone battery, microphone),
// starts / stops NightSoundsListener, records listening sessions, and hands every `audio` event to the injected sink.
//
// WP-23 wires it (see the report): `.setNightSounds(on)` -> setEnabled; plan (bedtime, window end) -> updatePlan;
// strap sleep state -> feedStrap; scene phase -> setAppActive; every BLE wake -> evaluate(); events -> a sink over
// MGStore.upsertEvent (refusing in SAMPLE mode).
//
// WRITTEN, NOT COMPILED.

/// "Listen tonight" is opt-in per night by default (PLAN 8: others in the room get recorded too). `.always` keeps the
/// switch on for every night until Mo switches it off; no screen offers that choice yet.
enum NightSoundsScope: String, Sendable {
    case tonight = "tonight"
    case always = "always"
}

enum NightSoundsStatus: Equatable, Sendable {
    case off
    /// Switched on, waiting for bedtime.
    case waiting(until: Date)
    case listening(since: Date)
    /// Strap says awake for 30 min: stopped to save battery; resumes if the strap says asleep again.
    case pausedAwake(since: Date)
    case needsMicrophone
    /// iOS refused to start the microphone from the background: open the app once.
    case needsForeground
    case lowBattery
    /// The window is over (tonight's switch has been cleared).
    case finished
    case failed(String)
}

/// Where events go. WP-23: an adapter over `MGStore.upsertEvent`.
protocol NightSoundsEventSink: Sendable {
    func record(_ event: EventRecord) async throws
}

/// The phone's own battery. UIDevice is main-actor isolated, hence the hop.
enum NightSoundsDevice {
    @MainActor
    static func readBattery() -> (level: Double?, charging: Bool?) {
        let d = UIDevice.current
        if !d.isBatteryMonitoringEnabled { d.isBatteryMonitoringEnabled = true }
        let level: Double? = d.batteryLevel >= 0 ? Double(d.batteryLevel) : nil
        switch d.batteryState {
        case .charging, .full: return (level, true)
        case .unplugged: return (level, false)
        case .unknown: return (level, nil)
        @unknown default: return (level, nil)
        }
    }

    static func battery() async -> (level: Double?, charging: Bool?) {
        await MainActor.run { readBattery() }
    }
}

actor NightSoundsController {
    /// ALG-025: for a groan-like event, a string such as "breathing pause 14 s, SpO2 steady" built from the strap's
    /// breathing and SpO2 data for that window, or nil. Applied as a second write of the same event id (revision + 1).
    typealias Corroborator = @Sendable (EventRecord) async -> String?

    private enum Keys {
        static let enabled = "mg.nightsounds.enabled"
        static let scope = "mg.nightsounds.scope"
        static let armedAt = "mg.nightsounds.armedAt"
    }

    private let listener: NightSoundsListening
    private let sink: NightSoundsEventSink
    private let sessions: NightSoundsSessionLog
    private let clock: MGDomain.Clock
    private let defaults: UserDefaults
    private let params: NightSoundsPolicyParams
    private let permission: @Sendable () -> NightSoundsPermission
    private let requestPermission: @Sendable () async -> Bool
    private let battery: @Sendable () async -> (level: Double?, charging: Bool?)
    private let corroborate: Corroborator?

    private var enabled: Bool
    private var scope: NightSoundsScope
    private var armedAt: Date?
    private var bedtime: Date?
    private var windowEnd: Date?
    private var tracker = NightSoundsStrapTracker()
    private var appIsActive = true

    private var sessionID: UUID?
    private var sessionStartedAt: Date?
    private(set) var status: NightSoundsStatus = .off
    private var subscribers: [UUID: AsyncStream<NightSoundsStatus>.Continuation] = [:]

    private var tickTask: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?
    private var undelivered: [EventRecord] = []
    private var flushing = false

    init(listener: NightSoundsListening,
         sink: NightSoundsEventSink,
         sessions: NightSoundsSessionLog,
         clock: MGDomain.Clock = SystemClock(),
         defaults: UserDefaults = .standard,
         params: NightSoundsPolicyParams = NightSoundsPolicyParams(),
         permission: @escaping @Sendable () -> NightSoundsPermission = { NightSoundsPermissionCheck.current() },
         requestPermission: @escaping @Sendable () async -> Bool = { await NightSoundsPermissionCheck.request() },
         battery: @escaping @Sendable () async -> (level: Double?, charging: Bool?) = { await NightSoundsDevice.battery() },
         corroborate: Corroborator? = nil) {
        self.listener = listener
        self.sink = sink
        self.sessions = sessions
        self.clock = clock
        self.defaults = defaults
        self.params = params
        self.permission = permission
        self.requestPermission = requestPermission
        self.battery = battery
        self.corroborate = corroborate
        self.enabled = defaults.bool(forKey: Keys.enabled)
        self.scope = NightSoundsScope(rawValue: defaults.string(forKey: Keys.scope) ?? "") ?? .tonight
        if let t = defaults.object(forKey: Keys.armedAt) as? Double {
            self.armedAt = Date(timeIntervalSince1970: t)
        }
    }

    // MARK: Reads for the presenter

    var isEnabled: Bool { enabled }
    var currentScope: NightSoundsScope { scope }
    var microphone: NightSoundsPermission { permission() }
    var labelCoverage: NightSoundLabelCoverage? { listener.labelCoverage }

    /// Current status now, then every change.
    func statusUpdates() -> AsyncStream<NightSoundsStatus> {
        let id = UUID()
        var continuation: AsyncStream<NightSoundsStatus>.Continuation!
        let stream = AsyncStream<NightSoundsStatus> { continuation = $0 }
        subscribers[id] = continuation
        continuation.yield(status)
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeSubscriber(id) }
        }
        return stream
    }

    private func removeSubscriber(_ id: UUID) {
        subscribers[id] = nil
    }

    // MARK: Lifecycle

    /// Wires the listener to the sink and starts the periodic evaluation. Call once, at app launch.
    func start() {
        guard tickTask == nil else { return }
        var eventContinuation: AsyncStream<EventRecord>.Continuation!
        let events = AsyncStream<EventRecord> { eventContinuation = $0 }
        let cont = eventContinuation!
        // Callbacks arrive on the listener's queue: they only enqueue, never call back into the listener.
        listener.onEvent = { event in cont.yield(event) }
        listener.onStatus = { [weak self] st in
            Task { await self?.listenerReported(st) }
        }
        eventTask = Task { [weak self] in
            for await event in events { await self?.deliver(event) }
        }
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                _ = await self?.evaluate()
                await self?.flushUndelivered()
                let delay = await self?.nextDelaySeconds() ?? 30
                try? await Task.sleep(nanoseconds: UInt64(max(1, delay) * 1_000_000_000))
            }
        }
    }

    /// App is going away: stop listening cleanly (open episodes become events), keep the switch as it is.
    func shutdown() {
        tickTask?.cancel()
        tickTask = nil
        if listener.isRunning || sessionID != nil {
            listener.stop()
            endSession(clock.now)
        }
        eventTask?.cancel()
        eventTask = nil
    }

    // MARK: Inputs from the app

    /// The Tonight switch. Turning on asks for the microphone the first time (the app must be in the foreground).
    @discardableResult
    func setEnabled(_ on: Bool, scope newScope: NightSoundsScope = .tonight) async -> NightSoundsStatus {
        if on {
            var p = permission()
            if p == .undetermined {
                _ = await requestPermission()
                p = permission()
            }
            guard p == .granted else {
                enabled = false
                armedAt = nil
                persist()
                return publish(.needsMicrophone)
            }
            enabled = true
            scope = newScope
            armedAt = clock.now
            tracker.reset()
        } else {
            enabled = false
            armedAt = nil
        }
        persist()
        return await evaluate()
    }

    /// Tonight's bedtime B and the end of the listening window (the wake plan; nil = B + 10 h). Call `evaluate()` after.
    func updatePlan(bedtime: Date, windowEnd: Date?) {
        self.bedtime = bedtime
        self.windowEnd = windowEnd
    }

    /// The strap's own sleep reading (WP-11 live stager, or R18 `sleepState`). Readings from before the listening
    /// start never count.
    func feedStrap(_ reading: NightSoundsStrapReading, at: Date) {
        guard enabled else { return }
        let start = NightSoundsPolicy.listeningStart(bedtime: effectiveBedtime(), armedAt: armedAt)
        guard at >= start else { return }
        tracker.feed(reading, at: at)
    }

    func setAppActive(_ active: Bool) async {
        appIsActive = active
        if active { _ = await evaluate() }
    }

    // MARK: Decision

    /// Re-reads every input, decides, starts or stops the listener. Cheap: call it on every BLE wake and scene change.
    @discardableResult
    func evaluate() async -> NightSoundsStatus {
        let reading = await battery()
        let now = clock.now
        let input = NightSoundsPolicyInput(
            now: now, enabled: enabled, armedAt: armedAt, bedtime: effectiveBedtime(), windowEnd: windowEnd,
            microphone: permission(), strap: tracker, batteryLevel: reading.level, charging: reading.charging)
        switch NightSoundsPolicy.decide(input, params: params) {
        case .listen:
            return ensureListening(now)
        case .idle(let reason):
            return ensureIdle(reason, now)
        }
    }

    private func ensureListening(_ now: Date) -> NightSoundsStatus {
        if listener.isRunning {
            if let id = sessionID {
                sessions.heartbeat(id: id, at: now)
            } else {
                beginSession(now)
            }
            return publish(.listening(since: sessionStartedAt ?? now))
        }
        do {
            try listener.start()
            if sessionID == nil { beginSession(now) }
            return publish(.listening(since: sessionStartedAt ?? now))
        } catch let error as NightSoundsError where error == .microphoneNotGranted {
            return publish(.needsMicrophone)
        } catch {
            return publish(appIsActive ? .failed(String(describing: error)) : .needsForeground)
        }
    }

    private func ensureIdle(_ reason: NightSoundsIdleReason, _ now: Date) -> NightSoundsStatus {
        if listener.isRunning || sessionID != nil {
            listener.stop()
            endSession(now)
        }
        switch reason {
        case .off:
            return publish(.off)
        case .noMicrophone:
            return publish(.needsMicrophone)
        case .beforeBedtime(let startsAt):
            tracker.reset()
            return publish(.waiting(until: startsAt))
        case .windowOver:
            tracker.reset()
            if scope == .tonight && enabled {
                enabled = false
                armedAt = nil
                persist()
            }
            return publish(.finished)
        case .strapAwake(let since):
            return publish(.pausedAwake(since: since))
        case .lowBattery:
            return publish(.lowBattery)
        }
    }

    // MARK: Events

    private func listenerReported(_ st: NightSoundsListenerStatus) {
        // A failed restart after an interruption: say so; the next tick retries start().
        if case .failed(let message) = st, enabled {
            _ = publish(appIsActive ? .failed(message) : .needsForeground)
        }
    }

    private func deliver(_ event: EventRecord) async {
        undelivered.append(event)
        await flushUndelivered()
    }

    /// One flusher at a time. Events the store refuses stay queued (newest 500: labels are tiny) and are retried on the
    /// next event and on every tick.
    private func flushUndelivered() async {
        guard !flushing else { return }
        flushing = true
        defer { flushing = false }
        while !undelivered.isEmpty {
            let batch = undelivered
            undelivered = []
            var failed: [EventRecord] = []
            for e in batch {
                do {
                    try await sink.record(e)
                    await corroborateIfGroan(e)
                } catch {
                    failed.append(e)
                }
            }
            undelivered = Array((failed + undelivered).suffix(500))
            if !failed.isEmpty { break }
        }
    }

    private func corroborateIfGroan(_ event: EventRecord) async {
        guard let corroborate = corroborate, case .audio(var fields) = event.payload, fields.kind == .groan,
              fields.strapCorroboration == nil, let text = await corroborate(event) else { return }
        fields.strapCorroboration = text
        var enriched = event
        enriched.payload = .audio(fields)
        try? await sink.record(enriched)
    }

    // MARK: Sessions, status, persistence

    private func beginSession(_ now: Date) {
        sessionID = sessions.begin(at: now)
        sessionStartedAt = now
    }

    private func endSession(_ now: Date) {
        if let id = sessionID { sessions.end(id: id, at: now) }
        sessionID = nil
        sessionStartedAt = nil
    }

    @discardableResult
    private func publish(_ s: NightSoundsStatus) -> NightSoundsStatus {
        if s != status {
            status = s
            for c in subscribers.values { c.yield(s) }
        }
        return s
    }

    private func persist() {
        defaults.set(enabled, forKey: Keys.enabled)
        defaults.set(scope.rawValue, forKey: Keys.scope)
        if let armed = armedAt {
            defaults.set(armed.timeIntervalSince1970, forKey: Keys.armedAt)
        } else {
            defaults.removeObject(forKey: Keys.armedAt)
        }
    }

    /// No plan given yet: treat "now / when it was armed" as bedtime, so a switch flipped by hand still works.
    private func effectiveBedtime() -> Date {
        bedtime ?? armedAt ?? clock.now
    }

    private func nextDelaySeconds() -> Double {
        switch status {
        case .off, .finished:
            return 300
        case .waiting(let until):
            return min(max(until.timeIntervalSince(clock.now), 1), 300)
        default:
            return params.tickSeconds
        }
    }
}
