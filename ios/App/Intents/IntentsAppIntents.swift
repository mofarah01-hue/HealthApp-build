import AppIntents
import Foundation
import MGDomain
import MGSync

// WP-24 — the App Intents of ARCHITECTURE §4.11 (APP-016 "Siri/Shortcuts, Action Button, one tap = one event"):
// LogVapeHitIntent, StartDrinkIntent(preset), FinishDrinkIntent, LogMedicationIntent(preset), LogSymptomIntent(kind),
// LogSleepinessIntent(kss), StartNapIntent(minutes), SyncNowIntent — plus LogNoteIntent, which main's WP-24 brief
// also names (nine in all) — and the AppShortcutsProvider. All run without opening the app.
//
// Each one writes ONE line to pending-intents.jsonl first (durable), then asks the running app to apply it. The spoken
// answer says which happened: logged now, or saved to join the log when MG next opens.

enum IntentsError: Error, CustomLocalizedStringResourceConvertible {
    case outOfRange(String)
    case notSaved(String)
    case refused(String)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .outOfRange(let s), .notSaved(let s), .refused(let s): return "\(s)"
        }
    }
}

/// Write the line, then let the app apply it if it is running.
enum IntentsSubmit {
    enum Outcome: Equatable {
        case applied
        case queued
        case keptBack(String)
    }

    static func submit(_ request: IntentsRequest, at now: Date, surface: IntentsSurface = .shortcut) async throws -> Outcome {
        guard let queue = IntentsQueue.shared else {
            throw IntentsError.notSaved("MG couldn't find a place to save this. Open MG and log it there.")
        }
        let line = IntentsPendingLine(createdAt: now, surface: surface, request: request)
        do {
            try queue.append(line)
        } catch {
            throw IntentsError.notSaved("Not saved: \(error.localizedDescription)")
        }
        guard let drainer = IntentsRuntime.shared.drainer else { return .queued }
        switch await drainer.drain().results[line.id] {
        case .done?: return .applied
        case .rejected(let why)?: throw IntentsError.refused(why)
        case .keep(let why)?: return .keptBack(why)
        case nil: return .queued        // an earlier line is waiting; this one runs after it
        }
    }

    static func sentence(_ outcome: Outcome, done: String) -> String {
        switch outcome {
        case .applied: return done
        case .queued: return "\(done.dropLast()) — it joins your log when MG next opens."
        case .keptBack(let why): return "Saved for later: \(why)"
        }
    }
}

// MARK: - Entities

struct IntentsDrinkEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Drink"
    static var defaultQuery = IntentsDrinkQuery()

    var id: String
    var caffeineMg: Double

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(id)", subtitle: "\(Int(caffeineMg.rounded())) mg caffeine")
    }

    var drink: IntentsDrink { IntentsDrink(name: id, caffeineMg: caffeineMg) }
}

struct IntentsDrinkQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [IntentsDrinkEntity] {
        IntentsCatalogue.current().drinks.filter { identifiers.contains($0.name) }
            .map { IntentsDrinkEntity(id: $0.name, caffeineMg: $0.caffeineMg) }
    }

    func suggestedEntities() async throws -> [IntentsDrinkEntity] {
        IntentsCatalogue.current().drinks.map { IntentsDrinkEntity(id: $0.name, caffeineMg: $0.caffeineMg) }
    }
}

struct IntentsMedicationEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Medication"
    static var defaultQuery = IntentsMedicationQuery()

    var id: String
    var medication: IntentsMedication

    var displayRepresentation: DisplayRepresentation {
        let strength = medication.strength.map { s -> String in
            let n = s == s.rounded() ? String(Int(s)) : String(s)
            return " \(n) \(medication.strengthUnit)"
        } ?? ""
        return DisplayRepresentation(title: "\(medication.name)\(strength)")
    }
}

struct IntentsMedicationQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [IntentsMedicationEntity] {
        IntentsCatalogue.current().medications.filter { identifiers.contains($0.presetId) }
            .map { IntentsMedicationEntity(id: $0.presetId, medication: $0) }
    }

    func suggestedEntities() async throws -> [IntentsMedicationEntity] {
        IntentsCatalogue.current().medications.map { IntentsMedicationEntity(id: $0.presetId, medication: $0) }
    }
}

/// The symptoms a single tap can log (UX §7 Symptom row without the ones that need the form: stool needs its
/// Bristol word; groan / breath-hold come from night sounds).
enum IntentsSymptom: String, AppEnum {
    case bloating = "bloating"
    case gutPain = "gut_pain"
    case urgency = "urgency"
    case nausea = "nausea"
    case swallowing = "swallowing"
    case headache = "headache"
    case other = "other"

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Symptom"
    static var caseDisplayRepresentations: [IntentsSymptom: DisplayRepresentation] = [
        .bloating: "Bloating",
        .gutPain: "Gut pain",
        .urgency: "Urgency",
        .nausea: "Nausea",
        .swallowing: "Swallowing",
        .headache: "Headache",
        .other: "Other",
    ]

    var kind: SymptomFields.Kind {
        switch self {
        case .bloating: return .bloating
        case .gutPain: return .gutPain
        case .urgency: return .urgency
        case .nausea: return .nausea
        case .swallowing: return .swallowing
        case .headache: return .headache
        case .other: return .other
        }
    }
}

// MARK: - The intents

struct LogVapeHitIntent: AppIntent {
    static var title: LocalizedStringResource = "Log a vape hit"
    static var description = IntentDescription("Logs one vape hit now.")
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let now = Date()
        let o = try await IntentsSubmit.submit(.event(IntentsEvents.vapeHit(at: now, surface: .shortcut)), at: now)
        return .result(dialog: "\(IntentsSubmit.sentence(o, done: "Vape hit logged."))")
    }
}

struct StartDrinkIntent: AppIntent {
    static var title: LocalizedStringResource = "Start a drink"
    static var description = IntentDescription("Logs that you started a caffeinated drink now. Finish it later.")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Drink")
    var preset: IntentsDrinkEntity

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let now = Date()
        let event = IntentsEvents.drinkStart(preset.drink, at: now, surface: .shortcut)
        let o = try await IntentsSubmit.submit(.event(event), at: now)
        return .result(dialog: "\(IntentsSubmit.sentence(o, done: "\(preset.id) started."))")
    }
}

struct FinishDrinkIntent: AppIntent {
    static var title: LocalizedStringResource = "Finish my drink"
    static var description = IntentDescription("Marks the drink you're sipping as finished now.")
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let now = Date()
        let o = try await IntentsSubmit.submit(.finishDrink(at: now), at: now)
        return .result(dialog: "\(IntentsSubmit.sentence(o, done: "Drink finished."))")
    }
}

struct LogMedicationIntent: AppIntent {
    static var title: LocalizedStringResource = "Log a medication dose"
    static var description = IntentDescription("Logs a dose of a saved medication, taken now.")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Medication")
    var preset: IntentsMedicationEntity

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let now = Date()
        let event = IntentsEvents.medicationTaken(preset.medication, at: now, surface: .shortcut)
        let o = try await IntentsSubmit.submit(.event(event), at: now)
        return .result(dialog: "\(IntentsSubmit.sentence(o, done: "\(preset.medication.name) taken."))")
    }
}

struct LogSymptomIntent: AppIntent {
    static var title: LocalizedStringResource = "Log a symptom"
    static var description = IntentDescription("Logs a symptom now, with an optional severity from 0 to 3.")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Symptom")
    var kind: IntentsSymptom

    @Parameter(title: "Severity (0–3)")
    var severity: Int?

    func perform() async throws -> some IntentResult & ProvidesDialog {
        if let severity, !(0...3).contains(severity) {
            throw IntentsError.outOfRange("Severity goes from 0 (none) to 3 (severe).")
        }
        let now = Date()
        let o = try await IntentsSubmit.submit(.event(IntentsEvents.symptom(kind.kind, severity: severity, at: now,
                                                                           surface: .shortcut)), at: now)
        return .result(dialog: "\(IntentsSubmit.sentence(o, done: "Symptom logged."))")
    }
}

struct LogSleepinessIntent: AppIntent {
    static var title: LocalizedStringResource = "Log how sleepy I am"
    static var description = IntentDescription("Karolinska sleepiness, 1 (extremely alert) to 9 (fighting sleep).")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Sleepiness (1–9)")
    var kss: Int

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard (1...9).contains(kss) else {
            throw IntentsError.outOfRange("Sleepiness goes from 1 (extremely alert) to 9 (fighting sleep).")
        }
        let now = Date()
        let o = try await IntentsSubmit.submit(.event(IntentsEvents.sleepiness(kss: kss, at: now, surface: .shortcut)),
                                               at: now)
        return .result(dialog: "\(IntentsSubmit.sentence(o, done: "Sleepiness \(kss) logged."))")
    }
}

struct StartNapIntent: AppIntent {
    static var title: LocalizedStringResource = "Start a nap"
    static var description = IntentDescription("Starts MG's nap timer for the minutes you choose.")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Minutes")
    var minutes: Int

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard (1...240).contains(minutes) else {
            throw IntentsError.outOfRange("A nap timer runs from 1 to 240 minutes.")
        }
        let now = Date()
        let o = try await IntentsSubmit.submit(.startNap(minutes: minutes, at: now), at: now)
        return .result(dialog: "\(IntentsSubmit.sentence(o, done: "Nap timer started, \(minutes) min."))")
    }
}

struct LogNoteIntent: AppIntent {
    static var title: LocalizedStringResource = "Add a note"
    static var description = IntentDescription("Adds a note to your log now.")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Note")
    var text: String

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw IntentsError.outOfRange("The note is empty.") }
        let now = Date()
        let o = try await IntentsSubmit.submit(.event(IntentsEvents.note(clean, at: now, surface: .shortcut)), at: now)
        return .result(dialog: "\(IntentsSubmit.sentence(o, done: "Note added."))")
    }
}

struct SyncNowIntent: AppIntent {
    static var title: LocalizedStringResource = "Sync with my PC"
    static var description = IntentDescription("Sends waiting data to your PC Lab now (Tailscale must be on).")
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        if let run = IntentsRuntime.shared.syncNow {
            return .result(dialog: "\(IntentsText.sync(await run()))")
        }
        _ = try await IntentsSubmit.submit(.syncNow, at: Date())
        return .result(dialog: "MG will sync when it next opens.")
    }
}

enum IntentsText {
    /// What Siri says after "Sync with my PC".
    static func sync(_ o: SyncOutcome) -> String {
        switch o.result {
        case .synced, .partial:
            var batch = NotifyReceiptBatch(id: "intent")
            if let d = o.delivered { batch.add(d) }
            let sent = o.delivered == nil ? "Synced." : NotifyText.receiptBody(batch)
            return o.result == .partial ? "\(sent) Some is still waiting; MG tries again later." : sent
        case .nothingToSend: return "Already up to date."
        case .offline: return o.detail ?? SyncMessages.unreachable(nil)
        case .notSetUp: return SyncMessages.notPaired
        case .error, .skipped: return o.detail ?? "Sync didn't run."
        }
    }
}

// MARK: - Siri / Shortcuts / Spotlight (no setup needed; at most 10)

struct IntentsShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: LogVapeHitIntent(),
                    phrases: ["Log a vape hit in \(.applicationName)", "\(.applicationName) vape hit"],
                    shortTitle: "Vape hit", systemImageName: "smoke")
        AppShortcut(intent: StartDrinkIntent(),
                    phrases: ["Start a drink in \(.applicationName)"],
                    shortTitle: "Start drink", systemImageName: "cup.and.saucer")
        AppShortcut(intent: FinishDrinkIntent(),
                    phrases: ["Finish my drink in \(.applicationName)"],
                    shortTitle: "Finish drink", systemImageName: "cup.and.saucer.fill")
        AppShortcut(intent: LogMedicationIntent(),
                    phrases: ["Log my medication in \(.applicationName)"],
                    shortTitle: "Medication", systemImageName: "pills")
        AppShortcut(intent: LogSymptomIntent(),
                    phrases: ["Log a symptom in \(.applicationName)"],
                    shortTitle: "Symptom", systemImageName: "bandage")
        AppShortcut(intent: LogSleepinessIntent(),
                    phrases: ["Log how sleepy I am in \(.applicationName)"],
                    shortTitle: "Sleepy", systemImageName: "zzz")
        AppShortcut(intent: StartNapIntent(),
                    phrases: ["Start a nap in \(.applicationName)"],
                    shortTitle: "Nap", systemImageName: "bed.double")
        AppShortcut(intent: LogNoteIntent(),
                    phrases: ["Add a note in \(.applicationName)"],
                    shortTitle: "Note", systemImageName: "note.text")
        AppShortcut(intent: SyncNowIntent(),
                    phrases: ["Sync \(.applicationName) with my PC"],
                    shortTitle: "Sync now", systemImageName: "arrow.triangle.2.circlepath")
        // Timers (T153): phone alert + strap buzz. 10th of at most 10.
        AppShortcut(intent: StartTimerIntent(),
                    phrases: ["Start a \(\.$length) timer in \(.applicationName)", "Start a timer in \(.applicationName)"],
                    shortTitle: "Timer", systemImageName: "timer")
    }
}
