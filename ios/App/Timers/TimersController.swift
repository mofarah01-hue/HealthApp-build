import Combine
import Foundation
import MGBLE
import MGContext
import UserNotifications

// Timers (T153, 2026-10-12): Mo "if I say Siri set a time for 10 min it sets a phone timer AND a whoop buzz timer".
// The rules are in MGContext `TimersBook` (tested); this file only DOES what `reconcile` asks:
//   - the iPhone alert: one local notification per timer at its end (like `AlarmBackstops`: time-sensitive, default
//     sound), scheduled with the timer so it rings even when the app is dead;
//   - the strap buzz: ONE `link.buzz(1...8 pulses)` (RUN_HAPTIC_PATTERN_MAVERICK; rule 5 limited it to 1-8 pulses until Mo removed rule 5 on 2026-10-13, T87, and the app still sends that one-shot form), sent only while this app is
//     alive and the strap is connected, and only within `TimersBook.lateBuzzGrace` of the end. A timer whose stop is
//     "double tap" re-sends that same command every 8 s until `silence()` (tap / phone Silence), no time limit (D-029a).
//   - bug 2 (2026-10-14): the strap's OWN alarm in slots 2-6 (never slot 1, the wake alarm's), written when a timer starts and
//     cleared when it is cancelled, so the strap buzzes at the end with the app in the background. The rules (which slot, when
//     to write / clear / re-write) are `TimersBook.reconcile`; the bytes are MGBLE `armTimerAlarm`. The record holds at most
//     repeat 7 for 120 s, so the app's 4 / 1 s / 4 loop only runs while the app is alive (docs/features/TIMER-STRAP-ALARM.md).
// The controller owns its own file (Application Support/MG/timers.json), so a Siri intent can use it before the rest of
// the app is up. `strap` is installed by AppModel; until then (an intent that launched the app in the background)
// only the iPhone alert goes out and the buzz waits for the strap, up to the grace.

@MainActor
final class TimersController: ObservableObject {
    static let shared = TimersController()

    /// What the controller needs from the strap when it wants to buzz. nil `link` = not connected.
    struct StrapAccess {
        var link: (any StrapAlarmLinking)?
        var consentAt: Date
    }

    @Published private(set) var book: TimersBook
    /// The last one-line answer (what Siri / the page says), 12-hour times.
    @Published private(set) var notice: String?
    /// Set by AppModel: the same link + consent the alarm engine uses (`alarmLink()` / `consentAt`).
    var strap: (@MainActor () -> StrapAccess)?

    private let fileURL: URL?
    private let center = UNUserNotificationCenter.current()
    private var loop: Task<Void, Never>?
    /// Was the strap ready at the last tick (a not-ready -> ready change is a reconnect: slots are checked again).
    private var wasReady = false

    init(fileURL: URL? = TimersController.defaultFileURL) {
        self.fileURL = fileURL
        self.book = Self.load(fileURL)
    }

    var state: TimersState { TimersState.make(book, now: Date(), calendar: .current) }

    nonisolated static var defaultFileURL: URL? {
        guard let support = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                         appropriateFor: nil, create: true) else { return nil }
        let dir = support.appendingPathComponent("MG", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("timers.json")
    }

    // MARK: Running

    /// Starts the tick loop (idempotent). Call once at app start and again when the app comes to the foreground.
    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.tick()
                try? await Task.sleep(nanoseconds: UInt64(self.secondsToNextTick() * 1_000_000_000))
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
    }

    /// At most 15 s, but wakes right at the next end so the buzz is not up to 15 s late.
    private func secondsToNextTick(now: Date = Date()) -> Double {
        // A double-tap timer that is buzzing re-sends every `TimerRing.repeatEvery` (8 s): look often enough to keep it.
        if book.timers.contains(where: { $0.buzz == .ringing }) { return 2 }
        // T9816: a finished timer whose strap alarm we are waiting on (the app buzzes if the strap reports nothing) is looked at every second.
        if book.timers.contains(where: { $0.state == .finished && $0.buzz == .pending && $0.strapSlot != nil
            && now.timeIntervalSince($0.endsAt) < TimerStrapSlots.fireWait + 5 }) { return 1 }
        let next = book.running.map { $0.endsAt.timeIntervalSince(now) }.filter { $0 > 0 }.min() ?? 15
        return min(15, max(0.5, next))
    }

    /// Applies a tap or a spoken request, saves, and does what follows (schedules the iPhone alert) before returning.
    @discardableResult
    func apply(_ action: TimersAction) async -> String? {
        let said = book.apply(action, now: Date(), calendar: .current)
        notice = said
        save()
        await tick()
        return said
    }

    /// The single "stop buzzing" entry point for timers (D-029a / D-031): a strap double tap (event 14), a buzz that ended by
    /// a tap (event 100, cause 2) or the phone's Silence button. Ends the re-buzz loop of every ringing double-tap timer
    /// (nothing else is sent to the strap here). True when one was ringing, so a tap that did stop a timer is not also
    /// counted as a vape-hit double tap.
    @discardableResult
    func silence() -> Bool {
        let did = book.silenceAll(now: Date())
        if did {
            notice = "Timer stopped."
            save()
        }
        return did
    }

    /// Strap events 57 / 60 (its own alarm / haptics fired): records it on the timer whose strap alarm ended about then
    /// (slots 2-6 carry no number in the event, so the time decides). Bug 2.
    func strapAlarmFired(at: Date) {
        if book.strapAlarmFired(at: at) { save() }
    }

    /// Every strap alarm / haptic event (56-60, 100) goes to the diagnostics log, matched to a timer or not, so the next
    /// strap test shows exactly what the strap reported (T9816).
    func logStrapEvent(number: Int, at: Date) {
        print("timers: strap event \(number) at \(at)")
        // Every running / retrying timer gets the line, not only ones ending near the event (review fix 9).
        if book.noteStrapEventAll(number: number, at: at) { save() }
    }

    /// A foreground / BLE-woken moment: running timers whose strap arm failed try again now (rate-limited in the book).
    func retryStrapArms() async {
        if book.strapRetry(now: Date()) { save(); await tick() }
    }

    /// Reconciles now. Safe to call from anywhere and often (connection events, foreground): every effect is
    /// repeatable except the buzz, which `reconcile` hands out once.
    func tick() async {
        // Review fix 1: timer effects run ONE AT A TIME. Each tick waits for the previous one, so a SET/GET/DISABLE never
        // overlaps another and a caller still returns only after its own effects ran. Changes made by `apply` while a write
        // is in flight are reconciled by the next tick; the in-flight result is judged stale by the book (end / state tag).
        let previous = chain
        let mine = Task { @MainActor [weak self] in
            await previous?.value
            await self?.tickBody()
        }
        chain = mine
        await mine.value
    }

    private var chain: Task<Void, Never>?

    private func tickBody() async {
        let now = Date()
        let ready = strap?().link != nil
        if ready && !wasReady { book.strapReconnected(); _ = book.strapRetry(now: now) }
        wasReady = ready
        let effects = book.reconcile(now: now, strapReady: ready)
        ringAlertForFinished(now: now)
        save()
        // Round 5 review: every strap effect carries the timer's generation from this moment; `run` re-checks it right
        // before the write and again when the write completes (a cancel / extend during an earlier effect makes it stale).
        let gens: [UUID: Int] = Dictionary(uniqueKeysWithValues: book.timers.map { ($0.id, $0.strapGen) })
        for effect in effects { await run(effect, gens: gens) }
        if !effects.isEmpty { save() }
    }

    /// 0.6.0.5 "Ring lab": with Settings › Ring lab › "Ring alert when a timer ends" on and the ring connected, a timer that
    /// ended within the last minute makes the ring do its alert once (find-ring buzz, then LED). Vibration on this ring is
    /// unconfirmed (docs/features/RING-LAB.md). Off by default.
    private func ringAlertForFinished(now: Date) {
        guard RingLabModel.timerAlertOn else { return }
        for t in book.timers where t.state == .finished && now.timeIntervalSince(t.endsAt) < 60
            && !ringAlerted.contains(t.id) {
            ringAlerted.insert(t.id)
            if RingBridge.shared.isConnected { Task { await RingBridge.shared.timerAlert() } }
        }
    }

    private var ringAlerted: Set<UUID> = []

    private func run(_ effect: TimerEffect, gens: [UUID: Int]) async {
        let gen: Int?
        switch effect {
        case let .armStrap(id, _, _, _), let .disableStrap(id, _): gen = gens[id]
        default: gen = nil
        }
        if !book.strapEffectCurrent(effect, gen: gen) {
            book.strapEffectDropped(effect)
            return
        }
        switch effect {
        case let .schedulePhone(id, at, title, body):
            do {
                try await schedule(id: id, at: at, title: title, body: body)
                book.phoneScheduled(id, at: at)
            } catch {
                book.phoneFailed(id, at: at, note: Self.words(error))
            }
        case let .cancelPhone(id):
            let ids = [timerPhoneId(id)]
            center.removePendingNotificationRequests(withIdentifiers: ids)
            center.removeDeliveredNotifications(withIdentifiers: ids)
            book.phoneCancelled(id)
        case let .armStrap(id, slotNumber, at, stop):
            guard let access = strap?(), let link = access.link, let slot = TimerAlarmSlot(slotNumber) else {
                book.strapArmFailed(id, at: at, note: "strap not connected", now: Date())
                return
            }
            do {
                let r = try await link.armTimerAlarm(slot: slot, at: at, pattern: Self.pattern(stop), consentAt: access.consentAt)
                // T9816: "armed" only when GET_ALARM_TIME read the slot back holding this end. An ok write whose read-back
                // differs or could not be decoded is shown as NOT armed (and retried), never as armed.
                if r.ok, r.readbackMatches == true {
                    book.strapArmed(id, at: at, stop: stop, verifiedAt: Date(), gen: gen)
                } else if r.ok {
                    book.strapArmUnverified(id, at: at, note: "the strap took the write but the slot read-back did not "
                                            + "confirm it (\(r.result))", now: Date())
                } else {
                    book.strapArmFailed(id, at: at, note: r.result)
                }
            } catch {
                book.strapArmFailed(id, at: at, note: Self.words(error))
            }
        case let .disableStrap(id, slotNumber):
            guard let access = strap?(), let link = access.link, let slot = TimerAlarmSlot(slotNumber) else {
                book.strapDisableFailed(id, note: "strap not connected", now: Date())
                return
            }
            do {
                let r = try await link.disableTimerAlarm(slot: slot, consentAt: access.consentAt)
                if r.ok { book.strapDisabled(id) } else { book.strapDisableFailed(id, note: r.result, now: Date()) }
            } catch {
                book.strapDisableFailed(id, note: Self.words(error), now: Date())
            }
        case let .buzz(id, pulses):
            guard let access = strap?(), let link = access.link, let p = BuzzPulses(pulses) else {
                book.buzzFailed(id, now: Date(), note: "strap not connected")
                return
            }
            do {
                let r = try await link.buzz(p, consentAt: access.consentAt)
                if r.ok { book.buzzSent(id, at: Date()) } else { book.buzzFailed(id, now: Date(), note: r.result) }
            } catch {
                book.buzzFailed(id, now: Date(), note: Self.words(error))
            }
        }
    }

    // MARK: iPhone alert

    private func schedule(id: UUID, at: Date, title: String, body: String) async throws {
        let settings = await center.notificationSettings()
        if settings.authorizationStatus == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
        }
        if await center.notificationSettings().authorizationStatus == .denied {
            throw NSError(domain: "HealthApp.timers", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "notifications are off for MG (iOS Settings › MG › Notifications)"])
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, at.timeIntervalSinceNow), repeats: false)
        // Same identifier = replaces the earlier alert of this timer (extend).
        try await center.add(UNNotificationRequest(identifier: timerPhoneId(id), content: content, trigger: trigger))
    }

    /// The closest pattern the strap record can hold: "buzz x times" = x pulses; "double tap" = repeat 7 for 120 s.
    static func pattern(_ stop: TimerStop) -> TimerAlarmPattern {
        switch stop {
        case .doubleTap: return .untilDoubleTap
        case .buzzes(let n): return .pulses(BuzzPulses(TimerPulses.clamp(n)) ?? .one)
        }
    }

    private static func words(_ error: Error) -> String {
        let ns = error as NSError
        if ns.domain == "HealthApp.timers" { return ns.localizedDescription }
        if let e = error as? LocalizedError, let d = e.errorDescription { return d }
        return String(describing: error)
    }

    // MARK: File

    private static func load(_ url: URL?) -> TimersBook {
        guard let url, let data = try? Data(contentsOf: url) else { return TimersBook() }
        if let book = try? JSONDecoder().decode(TimersBook.self, from: data) { return book }
        // Unreadable: keep the bad file next to it (never lose it), start empty.
        let aside = url.deletingLastPathComponent().appendingPathComponent("timers.unreadable.json")
        if !FileManager.default.fileExists(atPath: aside.path) { try? data.write(to: aside) }
        return TimersBook()
    }

    private func save() {
        guard let fileURL, let data = try? JSONEncoder().encode(book) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
