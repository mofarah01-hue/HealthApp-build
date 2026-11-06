import Foundation
import MGDomain
#if canImport(WidgetKit)
import WidgetKit
#endif

// WP-27 — widget-snapshot.json: what the app tells the widget extension (APP-016, APP-071, APP-076).
//
// COMPILED INTO TWO TARGETS: MGApp (so WP-23a writes it with `WidgetSnapshotFile.publish`) and MGWidgets (which reads
// it). One Codable type on both sides, so the two cannot disagree about the format. Foundation + MGDomain only, plus
// WP-24's IntentsEvents.swift / IntentsQueue.swift (also compiled into both) for `IntentsMedication`, `IntentsDrink`,
// `IntentsAppGroup` and `IntentsQueueLocation`.
//
// WHERE: the same App Group folder as pending-intents.jsonl (`IntentsAppGroup.location().directory`, `<container>/MG/`),
// file name `widget-snapshot.json`. Written atomically (readers never see half a file), JSON via MGJSON (dates RFC 3339
// with an offset, keys sorted).
//
// WHAT IT IS: REAL STORED DATA ONLY. It is never built from SampleDayDataSource: widgets always log real events and
// show real counts (BRIEF "SAMPLE never applies to widgets"). While SAMPLE mode is on the app keeps queued widget lines
// waiting (IntentsAppHandler `.keep`), and the widget counts those waiting lines itself.
//
// WRITER RULES (WP-23a):
//   1. Publish after every change that moves a number or a time shown by the widget: launch, foreground, an event saved
//      or removed in the app, a Settings change (drinks, schedules, Quick-log surfaces), a theme boundary passing.
//   2. Publish AFTER `IntentsDrainer.drain()` has returned, never between a line's store write and the drain's
//      `queue.finish` (the widget adds the lines still waiting in the queue to `vape.today`; in that gap one hit would be
//      counted twice for a moment).
//   3. `vape.today` counts the same hits as the Log tab's daily count: non-removed vape events with `at` on the local day
//      `day`, summing `vape.hits ?? 1`, excluding unconfirmed / rejected detected hits (WP-16 BehaviourEvents).
//   4. `publish` skips the write (and the widget reload) when nothing but `generated_at` changed.
//
// JSON (version 1). Everything marked ? may be absent:
//   { "v": 1, "generated_at": "2026-10-11T08:15:03-07:00", "day": "2026-10-11",
//     "theme": "cream", "theme_changes": [ { "at": "2026-10-11T18:30:00-07:00", "theme": "emerald" } ],
//     "buttons_enabled": true,
//     "vape": { "today": 7, "last_at": "2026-10-11T07:58:12-07:00" },
//     "med": { "preset": { …IntentsMedication… }, "doses": [ { "due": "…", "taken_at": null } ], "last_taken_at": null },
//     "drink": { "preset": { "name": "Coffee", "caffeine_mg": 95 }, "open": { "name": "Coffee", "since": "…" } },
//     "symptom_kind": "other" }

struct WidgetSnapshot: Codable, Equatable, Sendable {
    static let fileName = "widget-snapshot.json"
    static let version = 1

    /// When the app wrote it. Ignored by `sameContent`.
    var generatedAt: Date
    /// The local calendar day `vape.today` belongs to, "yyyy-MM-dd" (`dayKey`). A widget that renders on a later day
    /// treats the stored count as 0 for that day (only waiting queue lines can be newer).
    var day: String
    /// `ThemeName.rawValue` (MGContext) the app is in now: "cream", "creamGolden", "emerald", "emeraldLow". Unknown → cream.
    var theme: String
    /// The next theme switches the app has planned (sundown, bedtime, wake), in the next 24 h, so a widget can change
    /// colours on time without the app running. Empty = keep `theme`.
    var themeChanges: [ThemeChange]
    /// Settings › Quick-log surfaces › "Home-screen widget". false = the Home / Lock Screen widgets show no log buttons.
    /// Control Center controls don't read it.
    var buttonsEnabled: Bool
    var vape: Vape
    /// The medication the widget's button logs (the first prescription schedule). nil = no schedule: the widget logs
    /// a plain "Medication" preset with no dose (QuickLogPresets.medication) and shows no dose time.
    var med: Med?
    /// The usual drink (Settings usual drink, else the first drink preset, as the Today pill) and the open one, if any.
    var drink: Drink
    /// The symptom the 4th button logs, an `IntentsSymptom` raw value: bloating, gut_pain, urgency, nausea, swallowing,
    /// headache, other. nil → "other".
    var symptomKind: String?

    struct ThemeChange: Codable, Equatable, Sendable {
        var at: Date
        var theme: String

        enum CodingKeys: String, CodingKey {
            case at = "at"
            case theme = "theme"
        }
    }

    struct Vape: Codable, Equatable, Sendable {
        /// Hits today (see writer rule 3).
        var today: Int
        /// The latest counted hit, on any day (so "last hit: 1 d" works on a day with no hit yet). nil = none on record.
        var lastAt: Date?

        init(today: Int, lastAt: Date? = nil) {
            self.today = today
            self.lastAt = lastAt
        }

        enum CodingKeys: String, CodingKey {
            case today = "today"
            case lastAt = "last_at"
        }
    }

    struct Med: Codable, Equatable, Sendable {
        var preset: IntentsMedication
        /// Scheduled doses of the preset for the local day `day` and the next one, any order. A dose with `taken_at`
        /// is done. Expanded from `MedSchedule.times` / `days` by the app.
        var doses: [Dose]
        /// The latest taken dose of the preset on any day.
        var lastTakenAt: Date?

        init(preset: IntentsMedication, doses: [Dose] = [], lastTakenAt: Date? = nil) {
            self.preset = preset
            self.doses = doses
            self.lastTakenAt = lastTakenAt
        }

        enum CodingKeys: String, CodingKey {
            case preset = "preset"
            case doses = "doses"
            case lastTakenAt = "last_taken_at"
        }
    }

    struct Dose: Codable, Equatable, Sendable {
        var due: Date
        var takenAt: Date?

        init(due: Date, takenAt: Date? = nil) {
            self.due = due
            self.takenAt = takenAt
        }

        enum CodingKeys: String, CodingKey {
            case due = "due"
            case takenAt = "taken_at"
        }
    }

    struct Drink: Codable, Equatable, Sendable {
        var preset: IntentsDrink
        /// The caffeine drink that is still open (no `finished_at`, started in the last 12 h): the widget then offers
        /// "Finish" instead of "Start".
        var open: Open?

        init(preset: IntentsDrink, open: Open? = nil) {
            self.preset = preset
            self.open = open
        }

        struct Open: Codable, Equatable, Sendable {
            var name: String
            var since: Date

            enum CodingKeys: String, CodingKey {
                case name = "name"
                case since = "since"
            }
        }

        enum CodingKeys: String, CodingKey {
            case preset = "preset"
            case open = "open"
        }
    }

    init(generatedAt: Date, day: String, theme: String, themeChanges: [ThemeChange] = [], buttonsEnabled: Bool = true,
         vape: Vape, med: Med? = nil, drink: Drink, symptomKind: String? = nil) {
        self.generatedAt = generatedAt
        self.day = day
        self.theme = theme
        self.themeChanges = themeChanges
        self.buttonsEnabled = buttonsEnabled
        self.vape = vape
        self.med = med
        self.drink = drink
        self.symptomKind = symptomKind
    }

    enum CodingKeys: String, CodingKey {
        case v = "v"
        case generatedAt = "generated_at"
        case day = "day"
        case theme = "theme"
        case themeChanges = "theme_changes"
        case buttonsEnabled = "buttons_enabled"
        case vape = "vape"
        case med = "med"
        case drink = "drink"
        case symptomKind = "symptom_kind"
    }

    struct UnsupportedVersion: Error, CustomStringConvertible {
        var found: Int
        var description: String { "\(WidgetSnapshot.fileName) is version \(found); this build reads version \(WidgetSnapshot.version)" }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let v = try c.decode(Int.self, forKey: .v)
        guard v == WidgetSnapshot.version else { throw UnsupportedVersion(found: v) }
        generatedAt = try c.decode(Date.self, forKey: .generatedAt)
        day = try c.decode(String.self, forKey: .day)
        theme = try c.decode(String.self, forKey: .theme)
        themeChanges = try c.decodeIfPresent([ThemeChange].self, forKey: .themeChanges) ?? []
        buttonsEnabled = try c.decodeIfPresent(Bool.self, forKey: .buttonsEnabled) ?? true
        vape = try c.decode(Vape.self, forKey: .vape)
        med = try c.decodeIfPresent(Med.self, forKey: .med)
        drink = try c.decode(Drink.self, forKey: .drink)
        symptomKind = try c.decodeIfPresent(String.self, forKey: .symptomKind)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(WidgetSnapshot.version, forKey: .v)
        try c.encode(generatedAt, forKey: .generatedAt)
        try c.encode(day, forKey: .day)
        try c.encode(theme, forKey: .theme)
        try c.encode(themeChanges, forKey: .themeChanges)
        try c.encode(buttonsEnabled, forKey: .buttonsEnabled)
        try c.encode(vape, forKey: .vape)
        try c.encodeIfPresent(med, forKey: .med)
        try c.encode(drink, forKey: .drink)
        try c.encodeIfPresent(symptomKind, forKey: .symptomKind)
    }

    /// The `day` key for a moment: the local calendar date in `calendar`, "yyyy-MM-dd". Writer and widget both use this.
    static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04ld-%02ld-%02ld", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// Equal in everything except `generated_at`.
    func sameContent(as other: WidgetSnapshot) -> Bool {
        var copy = self
        copy.generatedAt = other.generatedAt
        return copy == other
    }
}

/// Reading and writing the file. The app calls `publish`; the widget calls `read`.
enum WidgetSnapshotFile {
    enum PublishResult: Equatable {
        case written
        /// Same content as the file already there: nothing written, widgets not reloaded.
        case unchanged
        /// The App Group isn't provisioned in this signature, so the widget can't see anything the app writes.
        case notShared(String)
        case failed(String)
    }

    static func fileURL(in directory: URL) -> URL {
        directory.appendingPathComponent(WidgetSnapshot.fileName)
    }

    /// nil = no file yet (the app has never published). Throws when the file is there but unreadable.
    static func read(from directory: URL) throws -> WidgetSnapshot? {
        guard let data = FileManager.default.contents(atPath: fileURL(in: directory).path) else { return nil }
        return try MGJSON.decoder().decode(WidgetSnapshot.self, from: data)
    }

    static func write(_ snapshot: WidgetSnapshot, to directory: URL) throws {
        let data = try MGJSON.encoder().encode(snapshot)
        // Readable on the Lock Screen before the first unlock after a restart too.
        try data.write(to: fileURL(in: directory), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    /// App side: write into the shared folder and ask WidgetKit to redraw. Never throws; the result says what happened
    /// (WP-23a surfaces `.notShared` / `.failed` like it does the intents queue problem).
    @discardableResult
    static func publish(_ snapshot: WidgetSnapshot, location: IntentsQueueLocation? = IntentsAppGroup.location()) -> PublishResult {
        guard let location else { return .failed("no writable folder for \(WidgetSnapshot.fileName)") }
        guard location.shared else {
            return .notShared(location.problem ?? "App Group not provisioned in this signature: widgets can't see MG's data")
        }
        if let existing = try? read(from: location.directory), existing.sameContent(as: snapshot) { return .unchanged }
        do {
            try write(snapshot, to: location.directory)
        } catch {
            return .failed("\(WidgetSnapshot.fileName) not written: \(error.localizedDescription)")
        }
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadAllTimelines()
        #endif
        return .written
    }
}
