import AppIntents
import Foundation
import MGDomain
import WidgetKit

// WP-27 — the buttons of the Home Screen widget, the Lock Screen widgets and the Control Center controls (APP-016
// "one tap = one event", APP-071 vape hit, APP-076 medication one-tap, APP-015 drink / symptom).
//
// WHY THESE AND NOT WP-24's INTENTS: WP-24's App Intents (App/Intents/IntentsAppIntents.swift) import MGSync and call
// IntentsRuntime (IntentsHandler.swift → MGSync, UI/Log), which the widget extension cannot link, and they always stamp
// the event `shortcut`. These intents are the thin widget-side twins: they build the SAME events with WP-24's
// `IntentsEvents` (surface `.widget` / `.control`, so source and vape trigger say where the tap came from) and write the
// SAME line with WP-24's `IntentsQueue.append`. Nothing about the queue format is repeated here; IntentsQueue.swift and
// IntentsEvents.swift are compiled into this extension unchanged. The app applies the lines when it next runs
// (IntentsDrainer: launch, foreground, BLE wake) through the same save path as the Log tab.
//
// Each intent runs in the widget extension's process (it is in this target), writes ONE line, durable before it returns.
// No dialog: widgets and controls don't show one.

enum WidgetLogError: Error, CustomLocalizedStringResourceConvertible {
    case notSaved(String)
    case unknown(String)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .notSaved(let s), .unknown(let s): return "\(s)"
        }
    }
}

enum WidgetSubmit {
    /// Only widget and Control Center are valid here; anything else counts as widget.
    static func surface(_ raw: String) -> IntentsSurface {
        IntentsSurface(rawValue: raw) == .control ? .control : .widget
    }

    /// The shared App Group folder, or nil when this install has none. A private fallback folder would swallow the tap
    /// (the app never looks there), so it is refused instead.
    static func sharedDirectory() -> URL? {
        guard let location = IntentsAppGroup.location(), location.shared else { return nil }
        return location.directory
    }

    static func append(_ request: IntentsRequest, surface: IntentsSurface, at now: Date) throws {
        guard let directory = sharedDirectory() else {
            throw WidgetLogError.notSaved("MG's shared storage isn't available in this install, so the widget can't log. Open MG and log it there.")
        }
        let line = IntentsPendingLine(createdAt: now, surface: surface, request: request)
        do {
            try IntentsQueue(directory: directory).append(line)
        } catch {
            throw WidgetLogError.notSaved("Not saved: \(error.localizedDescription)")
        }
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// The medication preset for a button: the one in the app's snapshot, else one in the app's intent catalogue, else
    /// (only for the generic control id) the app's own first medication, else the plain stand-in. nil = unknown id.
    static func medication(presetId: String) -> IntentsMedication? {
        let generic = presetId == QuickLogPresets.medication.presetId
        if let directory = sharedDirectory() {
            let snapshot = try? WidgetSnapshotFile.read(from: directory)
            let catalogue = IntentsCatalogue.load(from: directory)
            if let preset = snapshot?.med?.preset, preset.presetId == presetId { return preset }
            if let found = catalogue?.medications.first(where: { $0.presetId == presetId }) { return found }
            // T9973: the Control Center button carries no medication name; it means "the app's medication".
            if generic {
                if let preset = snapshot?.med?.preset { return preset }
                if let first = catalogue?.medications.first { return first }
            }
        }
        return generic ? QuickLogPresets.medication : nil
    }
}

// MARK: - Vape hit

struct WidgetLogVapeHitIntent: AppIntent {
    static var title: LocalizedStringResource = "Log a vape hit (widget button)"
    static var description = IntentDescription("Logs one vape hit now. For the MG widgets and Control Center.")
    static var openAppWhenRun: Bool = false
    // Logging is the point of a Lock Screen / Control Center button, so it must not wait for an unlock.
    static var authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    @Parameter(title: "Surface", default: "widget")
    var surface: String

    init() {}

    init(surface: IntentsSurface) {
        self.surface = surface.rawValue
    }

    func perform() async throws -> some IntentResult {
        let now = Date()
        let from = WidgetSubmit.surface(surface)
        try WidgetSubmit.append(.event(IntentsEvents.vapeHit(at: now, surface: from)), surface: from, at: now)
        return .result()
    }
}

// MARK: - Medication

struct WidgetLogMedicationIntent: AppIntent {
    static var title: LocalizedStringResource = "Log a medication dose (widget button)"
    static var description = IntentDescription("Logs a dose of a saved medication, taken now. For the MG widgets and Control Center.")
    static var openAppWhenRun: Bool = false
    static var authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    /// `IntentsMedication.presetId` (lowercase name), e.g. "medication" for the generic control.
    @Parameter(title: "Medication preset")
    var presetId: String

    @Parameter(title: "Surface", default: "widget")
    var surface: String

    init() {}

    init(presetId: String, surface: IntentsSurface) {
        self.presetId = presetId
        self.surface = surface.rawValue
    }

    func perform() async throws -> some IntentResult {
        guard let preset = WidgetSubmit.medication(presetId: presetId) else {
            throw WidgetLogError.unknown("MG doesn't know the medication \"\(presetId)\" yet. Open MG once, then try again.")
        }
        let now = Date()
        let from = WidgetSubmit.surface(surface)
        try WidgetSubmit.append(.event(IntentsEvents.medicationTaken(preset, at: now, surface: from)), surface: from, at: now)
        return .result()
    }
}

// MARK: - Drink

struct WidgetStartDrinkIntent: AppIntent {
    static var title: LocalizedStringResource = "Start a drink (widget button)"
    static var description = IntentDescription("Logs that you started a caffeinated drink now. For the MG widgets.")
    static var openAppWhenRun: Bool = false
    static var authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    @Parameter(title: "Drink")
    var name: String

    @Parameter(title: "Caffeine (mg)")
    var caffeineMg: Double

    @Parameter(title: "Surface", default: "widget")
    var surface: String

    init() {}

    init(name: String, caffeineMg: Double, surface: IntentsSurface) {
        self.name = name
        self.caffeineMg = caffeineMg
        self.surface = surface.rawValue
    }

    func perform() async throws -> some IntentResult {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, caffeineMg >= 0 else {
            throw WidgetLogError.unknown("This drink button has no drink set. Open MG once, then try again.")
        }
        let now = Date()
        let from = WidgetSubmit.surface(surface)
        let drink = IntentsDrink(name: clean, caffeineMg: caffeineMg)
        try WidgetSubmit.append(.event(IntentsEvents.drinkStart(drink, at: now, surface: from)), surface: from, at: now)
        return .result()
    }
}

struct WidgetFinishDrinkIntent: AppIntent {
    static var title: LocalizedStringResource = "Finish my drink (widget button)"
    static var description = IntentDescription("Marks the drink you're sipping as finished now. For the MG widgets.")
    static var openAppWhenRun: Bool = false
    static var authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    @Parameter(title: "Surface", default: "widget")
    var surface: String

    init() {}

    init(surface: IntentsSurface) {
        self.surface = surface.rawValue
    }

    func perform() async throws -> some IntentResult {
        let now = Date()
        try WidgetSubmit.append(.finishDrink(at: now), surface: WidgetSubmit.surface(surface), at: now)
        return .result()
    }
}

// MARK: - Symptom

struct WidgetLogSymptomIntent: AppIntent {
    static var title: LocalizedStringResource = "Log a symptom (widget button)"
    static var description = IntentDescription("Logs a symptom now, with no severity. For the MG widgets.")
    static var openAppWhenRun: Bool = false
    static var authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    /// An `IntentsSymptom` raw value: bloating, gut_pain, urgency, nausea, swallowing, headache, other.
    @Parameter(title: "Symptom")
    var kind: String

    @Parameter(title: "Surface", default: "widget")
    var surface: String

    init() {}

    init(kind: String, surface: IntentsSurface) {
        self.kind = kind
        self.surface = surface.rawValue
    }

    func perform() async throws -> some IntentResult {
        guard QuickLogBuild.symptomKinds.contains(kind), let symptom = SymptomFields.Kind(rawValue: kind) else {
            throw WidgetLogError.unknown("This symptom button isn't set up. Open MG once, then try again.")
        }
        let now = Date()
        let from = WidgetSubmit.surface(surface)
        try WidgetSubmit.append(.event(IntentsEvents.symptom(symptom, severity: nil, at: now, surface: from)),
                                surface: from, at: now)
        return .result()
    }
}
