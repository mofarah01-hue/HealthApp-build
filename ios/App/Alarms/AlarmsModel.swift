import Combine
import Foundation
import MGBLE
import MGContext
import MGDomain
import MGSignal

// The alarm page's model and the alarms' runtime state (added 2026-10-11). The logic is AppModel+Alarms.swift; the
// decisions are MGContext's (AlarmPlanner, StrapSlotPolicy, RingPolicy, CalendarBuzzPlanner) and MGSignal's
// (AwakeEvidence), all tested on their own.

/// What survives an app restart mid-alarm (kv `AlarmsRuntime.storeKey`).
struct AlarmsRuntime: Codable, Equatable, Sendable {
    static let storeKey = "alarms.runtime.v1"

    struct LogItem: Codable, Equatable, Sendable {
        var id: String
        var at: Date
        var text: String
    }

    var slot = StrapSlotState()
    var slotConfirmedAt: Date?
    var lastSlotResult: String?
    var rings: [String: RingState] = [:]
    /// Occurrence id → why it ended.
    var finished: [String: String] = [:]
    var finishedAt: [String: Date] = [:]
    /// Finished on awake evidence, "I'm up" or a Stop: its iPhone backstop is cancelled. Anything else keeps it.
    var stoppedByMo: Set<String> = []
    /// Wake day → when the Fajr wake ended on awake evidence, and the sleeping heart rate before it.
    var fajrAwake: [String: Date] = [:]
    var fajrSleepingHR: [String: Double] = [:]
    /// Normal-wake id → why it is skipped ("you stayed up after Fajr …").
    var suppressed: [String: String] = [:]
    /// Normal-wake ids checked and kept (back to sleep, or not enough data).
    var keptNormal: Set<String> = []
    var backstops: [String: AlarmBackstops.Scheduled] = [:]
    /// Calendar item key → when it was buzzed.
    var calendarBuzzed: [String: Date] = [:]
    var imUpAt: [String: Date] = [:]
    var imUpAskedFor: String?
    var awakeNotes: [String: String] = [:]
    var log: [LogItem] = []
    /// Wave W11: the iPhone layer's last problems (AlarmKit's refusal in its words, the notification layer's failure),
    /// kept across launches so the page shows them and the log notes each one once.
    var alarmKitProblem: String?
    var alarmKitProblemAt: Date?
    var notificationProblem: String?

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AlarmsRuntime()
        slot = (try? c.decodeIfPresent(StrapSlotState.self, forKey: .slot)) ?? d.slot
        slotConfirmedAt = try? c.decodeIfPresent(Date.self, forKey: .slotConfirmedAt)
        lastSlotResult = try? c.decodeIfPresent(String.self, forKey: .lastSlotResult)
        rings = (try? c.decodeIfPresent([String: RingState].self, forKey: .rings)) ?? [:]
        finished = (try? c.decodeIfPresent([String: String].self, forKey: .finished)) ?? [:]
        finishedAt = (try? c.decodeIfPresent([String: Date].self, forKey: .finishedAt)) ?? [:]
        stoppedByMo = (try? c.decodeIfPresent(Set<String>.self, forKey: .stoppedByMo)) ?? []
        fajrAwake = (try? c.decodeIfPresent([String: Date].self, forKey: .fajrAwake)) ?? [:]
        fajrSleepingHR = (try? c.decodeIfPresent([String: Double].self, forKey: .fajrSleepingHR)) ?? [:]
        suppressed = (try? c.decodeIfPresent([String: String].self, forKey: .suppressed)) ?? [:]
        keptNormal = (try? c.decodeIfPresent(Set<String>.self, forKey: .keptNormal)) ?? []
        backstops = (try? c.decodeIfPresent([String: AlarmBackstops.Scheduled].self, forKey: .backstops)) ?? [:]
        calendarBuzzed = (try? c.decodeIfPresent([String: Date].self, forKey: .calendarBuzzed)) ?? [:]
        imUpAt = (try? c.decodeIfPresent([String: Date].self, forKey: .imUpAt)) ?? [:]
        imUpAskedFor = try? c.decodeIfPresent(String.self, forKey: .imUpAskedFor)
        awakeNotes = (try? c.decodeIfPresent([String: String].self, forKey: .awakeNotes)) ?? [:]
        log = (try? c.decodeIfPresent([LogItem].self, forKey: .log)) ?? []
        alarmKitProblem = try? c.decodeIfPresent(String.self, forKey: .alarmKitProblem)
        alarmKitProblemAt = try? c.decodeIfPresent(Date.self, forKey: .alarmKitProblemAt)
        notificationProblem = try? c.decodeIfPresent(String.self, forKey: .notificationProblem)
    }

    mutating func note(_ text: String, at: Date) {
        log.append(LogItem(id: UUID().uuidString, at: at, text: text))
        if log.count > 60 { log.removeFirst(log.count - 60) }
    }

    /// Forgets what is older than three days (occurrence ids carry their day; timers their own id).
    mutating func prune(now: Date) {
        let cutoff = now.addingTimeInterval(-3 * 86_400)
        let oldIds = finishedAt.filter { $0.value < cutoff }.map(\.key)
        for id in oldIds {
            finished.removeValue(forKey: id)
            finishedAt.removeValue(forKey: id)
            rings.removeValue(forKey: id)
            stoppedByMo.remove(id)
            imUpAt.removeValue(forKey: id)
            awakeNotes.removeValue(forKey: id)
        }
        backstops = backstops.filter { $0.value.at > cutoff }
        calendarBuzzed = calendarBuzzed.filter { $0.value > cutoff }
        let keepDays = Set((0...3).map { LocalDay(date: now.addingTimeInterval(-Double($0) * 86_400),
                                                  calendar: Calendar.current).iso })
        fajrAwake = fajrAwake.filter { keepDays.contains($0.key) }
        fajrSleepingHR = fajrSleepingHR.filter { keepDays.contains($0.key) }
        suppressed = suppressed.filter { k, _ in keepDays.contains(String(k.split(separator: ":").last ?? "")) }
        keptNormal = keptNormal.filter { keepDays.contains(String($0.split(separator: ":").last ?? "")) }
    }
}

/// Live stager + the golden-tested fire rule (MGSignal SmartWakeSession) for the Fajr window: finds the light-sleep
/// moment to buzz in, heart-only (the live stream has no motion). Runs only while the app is alive and beats arrive.
@MainActor
final class FajrWatcher {
    let occurrenceId: String
    let stager: LiveStager
    var session: SmartWakeSession
    private(set) var rangAt: Date?

    init(occurrence o: AlarmOccurrence, startedAt: Date, strapOffset: Double) {
        occurrenceId = o.id
        let off = Int64(strapOffset.rounded())
        let start = Int64(o.windowStart.timeIntervalSince1970) + off
        let end = Int64(o.latest.timeIntervalSince1970) + off
        let plan = SmartWakePlan(windowStart: start, windowEnd: end, backstopAt: end,
                                 setWindowMinutes: Int((end - start) / 60), windowMinutes: Double(end - start) / 60,
                                 narrowed: false, narrowReason: nil, armedLate: false, expectedOnset: start)
        stager = LiveStager(start: Int64(startedAt.timeIntervalSince1970) + off)
        session = SmartWakeSession(plan: plan, needMinutes: nil)
    }

    func take(_ b: LiveBeat) {
        let ts = Int64(b.at.timeIntervalSince1970.rounded(.down))
        stager.addHeartRate(ts: ts, bpm: b.bpm)
        if !b.rrMs.isEmpty { stager.addBeats(ts: ts, rrMs: b.rrMs) }
    }

    /// Closes epochs up to `strapNow` − 5 s; returns true the first time the fire rule rings.
    func tick(strapNow: Int64, now: Date) -> Bool {
        guard rangAt == nil else { return false }
        for ep in stager.close(through: min(strapNow - 5, session.plan.windowEnd)) where !session.hasRung {
            if session.observe(ep) {
                rangAt = now
                return true
            }
        }
        return false
    }
}

/// The page's model: AppModel+Alarms.swift fills it; UI/Alarms/AlarmsView.swift observes `state`.
@MainActor
final class AlarmsModel: ObservableObject {
    @Published var state: AlarmsState?

    var settings = AlarmsSettings()
    var runtime = AlarmsRuntime()
    var plan = AlarmPlan(occurrences: [], refusals: [], skipped: [:])
    var loaded = false
    var match: PrayerTimesCalculator.MethodMatch?
    var locationNote: String?
    var calendars: [AlarmsSource] = []
    var reminderLists: [AlarmsSource] = []
    /// One number per connection: starts at this launch's unix time (so it never equals a number a slot stored in an
    /// earlier run) and counts handshakes; slot 1 is re-armed on each new one.
    var connection = Int(Date().timeIntervalSince1970)
    var wantsRealtime = false
    var watcher: FajrWatcher?
    var ticker: Task<Void, Never>?
    var ticking = false
    var tickAgain = false
    var lastHistoryPull: Date?
    var lastAwakeCheck: [String: Date] = [:]
    var lastCalendarCheck: Date?
    var lastBuzzProblem: Date?
    /// T53: when each app+person last buzzed the strap (the cooldown). Not saved: a relaunch may buzz once more.
    var notificationBuzzed: [String: Date] = [:]
    var lastBackstopProblem: String?
    /// The last refused arm (target, connection, when): not retried on the same connection for 5 min.
    var lastArmFailure: (id: String, connection: Int, at: Date)?

    let backstops = AlarmBackstops()
    let location = AlarmsLocation()
    let calendarReader = AlarmsCalendarReader()

    var finishedIds: Set<String> { Set(runtime.finished.keys) }
}
