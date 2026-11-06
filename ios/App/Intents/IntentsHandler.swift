import Foundation
import MGDomain
import MGSync
import os

// WP-24 — the app side of pending-intents.jsonl: apply each line through the app's own store path, in file order.
// WP-23 wiring (after the store opens):
//     let drainer = IntentsDrainer(queue: IntentsQueue.shared!, handler: IntentsAppHandler(hooks: IntentsAppHooks(
//         isSampleMode: { … }, save: { event in /* the .saveEvent path */ }, recentEvents: { from, to in … },
//         startNap: { minutes, at in … }, syncNow: { await coordinator.syncNow() })))
//     IntentsRuntime.shared.install(drainer: drainer, syncNow: { await coordinator.syncNow() })
//     drain on launch, on foreground and on BLE wake: `await drainer.drain()`
//     when Settings change: `try IntentsCatalogue(…).save(to: location.directory)`

enum IntentsHandleResult: Equatable, Sendable {
    /// Stored / started / run: the line leaves the queue.
    case done
    /// Not now (SAMPLE mode on, store not ready): the line stays, and so does every line after it (order matters:
    /// a "finish drink" must never run before its "start drink").
    case keep(String)
    /// Never (nothing to finish, a nap that would already be over): the line moves to the rejected file.
    case rejected(String)
}

protocol IntentsRequestHandling: Sendable {
    func handle(_ line: IntentsPendingLine) async -> IntentsHandleResult
}

/// What the handler needs from the app (WP-23).
struct IntentsAppHooks: Sendable {
    /// SAMPLE mode never writes (ARCHITECTURE §4.12): lines wait until it is off.
    var isSampleMode: @Sendable () async -> Bool
    /// The `.saveEvent` path (sets loggedAt if missing, links a swallowing symptom to the meal before it, stores).
    var save: @Sendable (EventRecord) async throws -> Void
    /// Events with `at` in [from, to] (MGStore.events(from:to:types:)), for finishing a drink.
    var recentEvents: @Sendable (_ from: Date, _ to: Date) async throws -> [EventRecord]
    /// Start the nap timer as if Mo had tapped `.startNap(minutes:)`, begun at `startedAt`. false = could not.
    var startNap: @Sendable (_ minutes: Int, _ startedAt: Date) async -> Bool
    var syncNow: @Sendable () async -> SyncOutcome
}

struct IntentsAppHandler: IntentsRequestHandling {
    var hooks: IntentsAppHooks
    var clock: any MGDomain.Clock = SystemClock()

    /// Same sentence as the Log tab (UI/Log/LogIntents.swift).
    static let sampleReason = LogIntents.sampleReason

    func handle(_ line: IntentsPendingLine) async -> IntentsHandleResult {
        switch line.request {
        case .event(let event):
            if await hooks.isSampleMode() { return .keep(IntentsAppHandler.sampleReason) }
            do {
                try await hooks.save(event)
                return .done
            } catch {
                return .keep("Not saved yet: \(error.localizedDescription)")
            }

        case .finishDrink(let at):
            if await hooks.isSampleMode() { return .keep(IntentsAppHandler.sampleReason) }
            let events: [EventRecord]
            do {
                events = try await hooks.recentEvents(at.addingTimeInterval(-12 * 3600), at)
            } catch {
                return .keep("Could not read today's drinks: \(error.localizedDescription)")
            }
            guard let finished = IntentsEvents.finishing(events, at: at) else {
                return .rejected("No drink was open, so there was nothing to finish")
            }
            do {
                try await hooks.save(finished)
                return .done
            } catch {
                return .keep("Not saved yet: \(error.localizedDescription)")
            }

        case .startNap(let minutes, let at):
            // Applied late (the app was closed): a timer that would already have rung is not started now.
            if clock.now >= at.addingTimeInterval(TimeInterval(minutes) * 60) {
                return .rejected("The \(minutes)-min nap timer would already have ended when MG opened")
            }
            return await hooks.startNap(minutes, at) ? .done : .keep("The nap timer could not start yet")

        case .syncNow:
            _ = await hooks.syncNow()
            return .done
        }
    }
}

struct IntentsDrainReport: Equatable, Sendable {
    var results: [UUID: IntentsHandleResult] = [:]
    var unreadable = 0
    /// A file problem (couldn't read or rewrite the queue) — the lines are still there.
    var problem: String?
}

/// Drains the queue one line at a time, in file order. One drain at a time.
actor IntentsDrainer {
    private let queue: IntentsQueue
    private let handler: any IntentsRequestHandling
    private let log = Logger(subsystem: "mgapp", category: "intents")

    init(queue: IntentsQueue, handler: any IntentsRequestHandling) {
        self.queue = queue
        self.handler = handler
    }

    @discardableResult
    func drain() async -> IntentsDrainReport {
        var report = IntentsDrainReport()
        let snap: IntentsQueue.Snapshot
        do {
            snap = try queue.read()
        } catch {
            report.problem = "Could not read \(IntentsQueue.fileName): \(error.localizedDescription)"
            log.error("\(report.problem ?? "", privacy: .public)")
            return report
        }
        var handled = Set<String>()
        var rejected: [(raw: String, reason: String)] = snap.unreadable.map { (raw: $0.raw, reason: "unreadable: \($0.reason)") }
        handled.formUnion(snap.unreadable.map { $0.raw })
        report.unreadable = snap.unreadable.count

        for item in snap.lines {
            let result = await handler.handle(item.line)
            report.results[item.line.id] = result
            switch result {
            case .done:
                handled.insert(item.raw)
            case .rejected(let why):
                handled.insert(item.raw)
                rejected.append((raw: item.raw, reason: why))
            case .keep(let why):
                log.notice("intent \(item.line.id.uuidString.lowercased(), privacy: .public) kept: \(why, privacy: .public)")
            }
            if case .keep = result { break }
        }
        do {
            try queue.finish(removing: handled, rejected: rejected)
        } catch {
            // The handled lines stay in the file and run again next time; events are idempotent by id.
            report.problem = "Could not update \(IntentsQueue.fileName): \(error.localizedDescription)"
            log.error("\(report.problem ?? "", privacy: .public)")
        }
        return report
    }
}

/// The running app's drainer, so an intent performed in-process applies its line at once. Empty when iOS launched
/// the app only to run the intent before WP-23 set it up: the line then waits in the file.
final class IntentsRuntime: @unchecked Sendable {
    static let shared = IntentsRuntime()

    private let lock = NSLock()
    private var drainerRef: IntentsDrainer?
    private var syncRef: (@Sendable () async -> SyncOutcome)?

    func install(drainer: IntentsDrainer, syncNow: @escaping @Sendable () async -> SyncOutcome) {
        lock.lock()
        drainerRef = drainer
        syncRef = syncNow
        lock.unlock()
    }

    var drainer: IntentsDrainer? {
        lock.lock()
        defer { lock.unlock() }
        return drainerRef
    }

    var syncNow: (@Sendable () async -> SyncOutcome)? {
        lock.lock()
        defer { lock.unlock() }
        return syncRef
    }
}

extension IntentsCatalogue {
    /// Before the app has written `intent-catalogue.json`: the Log tab's standard presets (UI/Log/LogCatalogue.swift,
    /// WP-18: UX §7 drinks, APP-076 MedA 20 mg capsule), so there is one list, not two.
    static var standard: IntentsCatalogue {
        let base = LogCatalogue.standard
        return IntentsCatalogue(
            drinks: base.drinks.map { IntentsDrink(name: $0.name, caffeineMg: $0.caffeineMg) },
            medications: base.medications.map {
                IntentsMedication(name: $0.name, strength: $0.strength, strengthUnit: $0.strengthUnit, units: $0.units,
                                  unitKind: $0.unitKind, category: $0.category)
            })
    }

    /// What the intents offer right now.
    static func current() -> IntentsCatalogue {
        IntentsAppGroup.location().flatMap { IntentsCatalogue.load(from: $0.directory) } ?? .standard
    }
}
