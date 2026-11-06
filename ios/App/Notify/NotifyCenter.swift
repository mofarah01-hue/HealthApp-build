import Foundation
import MGContext
import MGDomain
import MGSync
import os

// WP-24 — the app's `Notifier` (ARCHITECTURE §4.2: SyncNotifying, declared in MGDomain, implemented by the app).
// Owns the ledger (what went out, for the cap and the spacing), the open receipt batch and the reachability clock.
// Every post goes through `NotifyPolicy.decide`. Posting itself is behind `NotifyPosting` (NotifySystem in the app,
// a recorder in tests).

/// Posts and withdraws notifications. A request with an id already pending or delivered is replaced.
protocol NotifyPosting: Sendable {
    /// `at` nil = now. Throws when iOS refuses the request (not authorised, bad trigger).
    func post(_ spec: NotifyContentSpec, id: String, at: Date?) async throws
    /// Removes pending and delivered notifications with these ids.
    func remove(ids: [String]) async
}

/// Where NotifyCenter keeps its state between launches (JSON bytes).
protocol NotifyStateStoring: Sendable {
    func load() -> Data?
    func save(_ data: Data)
}

/// UserDefaults of the app (not the App Group: only the app posts notifications).
struct NotifyDefaultsStore: NotifyStateStoring, @unchecked Sendable {
    var defaults: UserDefaults = .standard
    var key = "mg.notify.state.v1"
    func load() -> Data? { defaults.data(forKey: key) }
    func save(_ data: Data) { defaults.set(data, forKey: key) }
}

struct NotifyState: Codable, Equatable, Sendable {
    var ledger: [NotifyLedgerEntry] = []
    /// The receipt batch still open (not yet fired).
    var receipt: NotifyReceiptBatch?
    /// First failed reach of the PC since it was last reachable (from `reachabilityChanged`).
    var unreachableSince: Date?
    /// Latest quiet hours the app pushed (nil until the first push → `NotifyQuietWindow.beforeFirstAnchors`).
    var quiet: NotifyQuietWindow?
    var wokeAt: Date?
    var extraQuiet: [NotifySpan] = []
    /// Wave W11: everything the PC confirmed (union of receipt ranges, last 60 days), so a re-sent day adds nothing;
    /// the newest delivery for Settings › Usage; the problem-notice state. Optional so older saved state still decodes.
    var received: [SyncNotice.Span]?
    var lastDelivery: NotifyDeliveryNote?
    var noticeState: SyncNotice.State?
}

/// The newest delivery, for Settings › Usage (wave W11: no longer a banner).
struct NotifyDeliveryNote: Codable, Equatable, Sendable {
    var at: Date
    var newSeconds: TimeInterval
    var resentSeconds: TimeInterval
    var bytes: Int
    var drops: Int
    var pcName: String?
}

actor NotifyCenter: SyncNotifying {
    /// Ledger entries older than this are dropped (the longest rule looks back 6 h; the cap one calendar day).
    static let ledgerKeep: TimeInterval = 48 * 3600

    private let poster: any NotifyPosting
    private let store: any NotifyStateStoring
    private let clock: any MGDomain.Clock
    private let calendar: Calendar
    let policy: NotifyPolicy
    private var state: NotifyState
    private let log = Logger(subsystem: "mgapp", category: "notify")
    /// T53: called after a notification of this kind went out NOW (not one scheduled for later), so the app can buzz the strap.
    private let onPosted: (@Sendable (NotifyKind) async -> Void)?
    /// Last decisions, newest last, for a diagnostics screen (WP-23 may show them; nothing is swallowed silently).
    private(set) var recent: [String] = []
    /// T9841: kinds that are dropped before they are posted (see `setSkipped`).
    private var skipped: Set<NotifyKind> = []

    init(poster: any NotifyPosting, store: any NotifyStateStoring = NotifyDefaultsStore(),
         clock: any MGDomain.Clock = SystemClock(), calendar: Calendar = .current,
         policy: NotifyPolicy = .placeholder, onPosted: (@Sendable (NotifyKind) async -> Void)? = nil) {
        self.onPosted = onPosted
        self.poster = poster
        self.store = store
        self.clock = clock
        self.calendar = calendar
        self.policy = policy
        if let data = store.load(), let s = try? JSONDecoder().decode(NotifyState.self, from: data) {
            state = s
        } else {
            state = NotifyState()
        }
    }

    // MARK: Context the app pushes in (WP-23: on foreground, after a compute, when a nap timer starts / ends)

    /// Quiet hours for tonight (`NotifyQuietWindow.placeholder(anchors:policy:calendar:)`), today's DETECTED wake
    /// (nil if assumed) and extra quiet spans (nap timer, strap says asleep).
    /// T9841: the kinds Mo skips (`NotifyKind` raw values from Settings); a kind that is unknown or an alarm is ignored.
    func setSkipped(_ rawKinds: Set<String>) {
        skipped = Set(rawKinds.compactMap(NotifyKind.init(rawValue:)).filter { $0.priority != .alarm })
    }

    func setQuietContext(window: NotifyQuietWindow, wokeAt: Date?, extraQuiet: [DateInterval]) {
        state.quiet = window
        state.wokeAt = wokeAt
        state.extraQuiet = extraQuiet.map { NotifySpan(start: $0.start, end: $0.end) }
        persist()
    }

    var context: NotifyContext {
        NotifyContext(quiet: state.quiet ?? .beforeFirstAnchors, wokeAt: state.wokeAt,
                      extraQuiet: state.extraQuiet.map { DateInterval(start: $0.start, end: max($0.start, $0.end)) },
                      skipped: skipped)
    }

    // MARK: SyncNotifying (MGSync calls these)

    /// One sync delivered drops (§5.5). CHANGED 2026-10-11 (wave W11, Mo 10:03 PM "PC got 71 h 59 of data" — a bug):
    /// it used to merge the delivery into a receipt batch and post "Synced with … PC got … of data" for every routine
    /// sync, counting re-sent versions of days the PC already had. Now nothing is posted; what is new (measured
    /// against everything the PC confirmed before, SyncNotice) is kept for Settings › Usage.
    func delivered(summary: DeliverySummary) async {
        let now = clock.now
        prune(now)
        var sent: [SyncNotice.Span] = []
        if let a = summary.rangeStart, let b = summary.rangeEnd, b > a { sent = [SyncNotice.Span(start: a, end: b)] }
        let keepFrom = now.addingTimeInterval(-60 * 86_400)
        let r = SyncNotice.newCoverage(received: (state.received ?? []).filter { $0.end > keepFrom }, delivered: sent)
        state.received = r.received
        state.lastDelivery = NotifyDeliveryNote(at: now, newSeconds: r.seconds,
                                                resentSeconds: max(0, SyncNotice.seconds(sent) - r.seconds),
                                                bytes: summary.bytes, drops: summary.drops, pcName: summary.pcName)
        // A receipt banner an older build scheduled and that has not shown yet is withdrawn.
        if let pending = state.receipt {
            if let at = pending.scheduledFor, at > now { await poster.remove(ids: [pending.id]) }
            state.receipt = nil
        }
        persist()
    }

    /// Settings › Usage: the newest delivery in words.
    var lastDeliveryLine: String? {
        guard let d = state.lastDelivery else { return nil }
        return SyncNotice.deliveryLine(at: d.at, newSeconds: d.newSeconds, resentSeconds: d.resentSeconds,
                                       bytes: Int64(d.bytes), drops: d.drops, pcName: d.pcName, calendar: calendar)
    }

    /// Wave W11: after every sync attempt (BackgroundSyncCoordinator). Tells Mo only about problems (SyncNotice): the PC
    /// unreachable over 12 h with data waiting (once per outage), uploads failing 3 times in a row, storage low.
    func syncAttempted(_ outcome: SyncOutcome, status: SyncStatus, freeBytes: Int64?) async {
        let now = clock.now
        prune(now)
        if status.state != .offline && status.state != .error { state.unreachableSince = nil }
        if outcome.result == .offline, state.unreachableSince == nil { state.unreachableSince = now }
        let attempt: SyncNotice.Attempt
        switch outcome.result {
        case .synced, .nothingToSend: attempt = .ok
        case .offline: attempt = .offline
        case .error: attempt = .failed(outcome.detail)
        case .partial: attempt = outcome.failures.isEmpty ? .other : .failed(outcome.detail)   // budget ran out ≠ failed
        case .skipped, .notSetUp: attempt = .other
        }
        let r = SyncNotice.afterAttempt(attempt, state: state.noticeState ?? SyncNotice.State(),
                                        unreachableSince: state.unreachableSince,
                                        dataWaiting: (status.unsyncedDays ?? 0) > 0, freeBytes: freeBytes, now: now)
        state.noticeState = r.state
        for n in r.notices {
            let spec: NotifyContentSpec
            let id: String
            switch n {
            case .pcUnreachable(let since, _):
                spec = NotifyContent.pcUnreachable(since: since, lastSynced: status.lastSynced, pcName: status.pcName,
                                                   now: now)
                id = "mg.sync.unreachable.\(Int(since.timeIntervalSince1970))"
            case .uploadsFailing(let times, let last):
                spec = NotifyContent.uploadsFailing(times: times, last: last, pcName: status.pcName)
                id = "mg.sync.failing.\(Int(now.timeIntervalSince1970))"
            case .storageLow(let free):
                spec = NotifyContent.storageLow(freeBytes: free)
                id = "mg.sync.storage.\(Int(now.timeIntervalSince1970))"
            }
            let decision = NotifyPolicy.decide(kind: .tailscaleReminder, id: id, now: now,
                                               expiresAt: now.addingTimeInterval(policy.reminderLifetime),
                                               context: context, ledger: state.ledger, policy: policy,
                                               calendar: calendar)
            _ = await apply(decision, spec: spec, id: id, kind: .tailscaleReminder, now: now)
        }
        persist()
    }

    func reachabilityChanged(_ reachable: Bool) async {
        if reachable {
            state.unreachableSince = nil
        } else if state.unreachableSince == nil {
            state.unreachableSince = clock.now
        }
        persist()
    }

    // MARK: Tailscale reminder

    /// Call after every sync attempt (BackgroundSyncCoordinator does). Posts "Turn on Tailscale to sync" when
    /// `NotifyReminderRule.tailscaleDue` holds and the policy lets it out now; otherwise nothing (checked again next time).
    @discardableResult
    func evaluateTailscaleReminder(status: SyncStatus) async -> NotifyDecision? {
        let now = clock.now
        prune(now)
        if status.state != .offline && status.state != .error { state.unreachableSince = nil }
        guard NotifyReminderRule.tailscaleDue(now: now, status: status, unreachableSince: state.unreachableSince,
                                              policy: policy),
              let last = status.lastSynced else {
            persist()
            return nil
        }
        let id = "mg.tailscale.\(Int(now.timeIntervalSince1970))"
        let decision = NotifyPolicy.decide(kind: .tailscaleReminder, id: id, now: now,
                                           expiresAt: now.addingTimeInterval(policy.reminderLifetime),
                                           context: context, ledger: state.ledger, policy: policy, calendar: calendar)
        let spec = NotifyContent.tailscaleReminder(lastSynced: last, pcName: status.pcName, now: now)
        _ = await apply(decision, spec: spec, id: id, kind: .tailscaleReminder, now: now)
        persist()
        return decision
    }

    // MARK: Everything else (questions, alerts, caffeine limit, medication, smart-wake ring)

    /// Decide and post. For a question pass its `expiresAt`; for a medication time or a backstop ring pass `wanted`.
    /// Returns the decision (a drop is logged with its reason).
    @discardableResult
    func offer(_ spec: NotifyContentSpec, id: String, wanted: Date? = nil, expiresAt: Date? = nil) async -> NotifyDecision {
        let now = clock.now
        prune(now)
        let decision = NotifyPolicy.decide(kind: spec.kind, id: id, now: now, wanted: wanted, expiresAt: expiresAt,
                                           context: context, ledger: state.ledger, policy: policy, calendar: calendar)
        _ = await apply(decision, spec: spec, id: id, kind: spec.kind, now: now)
        persist()
        return decision
    }

    // MARK: Wake chain (T9993)

    /// The PC's numbers for `day` are on the phone `seconds` after the wake. Silent, through the policy like the rest.
    @discardableResult
    func pcNumbersIn(day: String, seconds: TimeInterval) async -> NotifyDecision {
        await offer(NotifyContent.pcNumbersIn(seconds: seconds), id: NotifyContent.pcNumbersRequestID(day: day),
                    expiresAt: clock.now.addingTimeInterval(3600))
    }

    /// Nov 6 2026: "Last night is ready", once per day, naming the device.
    @discardableResult
    func lastNightReady(day: String, deviceName: String) async -> NotifyDecision {
        await offer(NotifyContent.lastNightReady(deviceName: deviceName), id: NotifyContent.lastNightReadyRequestID(day: day),
                    expiresAt: clock.now.addingTimeInterval(6 * 3600))
    }

    // MARK: Workout? (r9q)

    /// "Workout?" Yes / No for a likely workout; expires with the question (20 min). Replaces an earlier one.
    @discardableResult
    func workoutLikely(onset: Date) async -> NotifyDecision {
        await offer(NotifyContent.workoutLikely(onset: onset, calendar: calendar), id: NotifyContent.workoutLikelyRequestID,
                    expiresAt: clock.now.addingTimeInterval(20 * 60))
    }

    func withdrawWorkoutLikely() async {
        await withdraw(id: NotifyContent.workoutLikelyRequestID)
    }

    // MARK: Night sounds (WP-26, main's OK 2026-10-11)

    /// Listening is armed for tonight but WP-26's status is `.waiting` / `.needsForeground` at the window start:
    /// post the silent "Open MG to start night sounds" (through the policy: a strap "asleep" span holds it, the
    /// quiet-hours window does not — see `NotifyPriority.silent`). `windowEnd` = end of tonight's listening window;
    /// after it the prompt is pointless.
    @discardableResult
    func nightSoundsNeedsForeground(windowEnd: Date) async -> NotifyDecision {
        await offer(NotifyContent.nightSoundsNeedsForeground(), id: NotifyContent.nightSoundsRequestID,
                    expiresAt: windowEnd)
    }

    /// Listening started (or was switched off): remove the prompt.
    func cancelNightSoundsPrompt() async {
        await withdraw(id: NotifyContent.nightSoundsRequestID)
    }

    // MARK: Nap timer and strap-off reminder (for WP-23's NotifyHook)

    /// Rings when the nap timer Mo started ends (an alarm: quiet hours don't hold it). Replaces any earlier timer ring.
    /// Returns nil when scheduled, else why not.
    func napTimerEnds(at end: Date, minutes: Int) async -> String? {
        await offer(NotifyContent.napTimerRing(minutes: minutes), id: NotifyContent.napTimerRequestID, wanted: end).whyNot
    }

    func cancelNapTimerRing() async {
        await withdraw(id: NotifyContent.napTimerRequestID)
    }

    /// "Remind me in 30 min" on the strap-off card: a reminder at `at`, useful for an hour after. Nil when scheduled.
    func remindStrapOff(at: Date, offSince: Date?) async -> String? {
        let spec = NotifyContent.strapOffReminder(offSince: offSince, now: at)
        return await offer(spec, id: NotifyContent.strapOffRequestID, wanted: at,
                           expiresAt: at.addingTimeInterval(3600)).whyNot
    }

    /// The strap went back on: drop a pending strap-off reminder.
    func cancelStrapOffReminder() async {
        await withdraw(id: NotifyContent.strapOffRequestID)
    }

    /// The question was answered in the app, or the alert seen: remove the notification and its ledger slot if it
    /// had not fired yet (a withdrawn future notification does not use up the cap).
    func withdraw(id: String) async {
        let now = clock.now
        await poster.remove(ids: [id])
        state.ledger.removeAll { $0.id == id && $0.at > now }
        persist()
    }

    // MARK: Internals

    /// Posts per the decision; returns the fire time when posted, nil when not.
    private func apply(_ decision: NotifyDecision, spec: NotifyContentSpec, id: String, kind: NotifyKind,
                       now: Date) async -> Date? {
        let fireAt: Date
        switch decision {
        case .drop(let reason):
            await poster.remove(ids: [id])          // a re-decided request that may no longer go out
            state.ledger.removeAll { $0.id == id && $0.at > now }
            note("\(kind.rawValue) \(id): not posted (\(reason.rawValue))")
            return nil
        case .now:
            fireAt = now
        case .at(let t):
            fireAt = t
        }
        do {
            try await poster.post(spec, id: id, at: fireAt > now ? fireAt : nil)
        } catch {
            note("\(kind.rawValue) \(id): iOS refused the request — \(error.localizedDescription)")
            return nil
        }
        state.ledger.removeAll { $0.id == id }
        state.ledger.append(NotifyLedgerEntry(id: id, kind: kind, at: fireAt))
        note("\(kind.rawValue) \(id): \(fireAt > now ? "scheduled \(fireAt)" : "posted")")
        if fireAt <= now { await onPosted?(kind) }
        return fireAt
    }

    private func prune(_ now: Date) {
        state.ledger.removeAll { now.timeIntervalSince($0.at) > NotifyCenter.ledgerKeep }
        state.extraQuiet.removeAll { $0.end <= now }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(state) { store.save(data) }
    }

    private func note(_ line: String) {
        log.notice("\(line, privacy: .public)")
        recent.append(line)
        if recent.count > 30 { recent.removeFirst(recent.count - 30) }
    }
}
