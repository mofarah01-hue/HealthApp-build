import Foundation
import MGDomain

// WP-27 — what the widgets show, as plain values. Pure: no WidgetKit, no file access, no clock (the caller passes the
// moment and the calendar), so every number here can be checked by hand.
//
// A widget shows, for a moment `date`:
//   count today  = the app's stored count for that local day  +  the vape lines still waiting in pending-intents.jsonl
//   last hit     = the later of the app's last hit and the newest waiting line
//   next dose    = the earliest scheduled dose not yet taken, skipping one dose per medication line still waiting
//   open drink   = the app's open drink, then the waiting lines applied in file order (a start opens, a finish closes)
// The waiting lines are real events Mo tapped; the app hasn't stored them yet (it applies them on launch, foreground,
// BLE wake). SAMPLE mode keeps them waiting, so the widget keeps counting them: widgets never run on sample data.

enum QuickLogTheme: String, Equatable {
    case cream = "cream"
    case creamGolden = "creamGolden"
    case emerald = "emerald"
    case emeraldLow = "emeraldLow"

    /// `ThemeName.rawValue` from the snapshot; anything unknown draws as cream.
    init(snapshotValue: String) {
        self = QuickLogTheme(rawValue: snapshotValue) ?? .cream
    }
}

struct QuickLogModel: Equatable {
    var theme: QuickLogTheme
    var buttonsEnabled: Bool
    var vapeCount: Int
    /// true = the waiting queue couldn't be read, so `vapeCount` is a lower bound and is shown with a "+".
    var vapeCountIsPartial: Bool
    var lastVapeAt: Date?
    var med: Med
    var drink: Drink
    /// An `IntentsSymptom` raw value (QuickLogBuild.symptomKinds).
    var symptomKind: String

    struct Med: Equatable {
        var preset: IntentsMedication
        var nextDue: Date?
        var lastTakenAt: Date?
    }

    struct Drink: Equatable {
        var preset: IntentsDrink
        var openName: String?
    }

    var vapeCountText: String {
        "\(vapeCount)" + (vapeCountIsPartial ? "+" : "")
    }

    /// Gallery / redacted stand-in. The system draws it as grey blocks, so none of these values is ever readable.
    static let placeholder = QuickLogModel(
        theme: .cream, buttonsEnabled: true, vapeCount: 0, vapeCountIsPartial: false, lastVapeAt: nil,
        med: Med(preset: QuickLogPresets.medication, nextDue: nil, lastTakenAt: nil),
        drink: Drink(preset: IntentsDrink(name: "Drink", caffeineMg: 0), openName: nil),
        symptomKind: "other")
}

/// The fixed presets the widgets know without the app telling them.
enum QuickLogPresets {
    /// T9973: the stand-in medication when the app has told the widget none: a plain "Medication" with no dose (a
    /// strength nil writes no dose). The real one comes from the app's snapshot or intent catalogue.
    static let medication = IntentsMedication(name: "Medication", strength: nil, strengthUnit: "mg", units: 1,
                                              unitKind: .pill, category: .prescription)
}

/// What a widget read from the App Group folder.
struct QuickLogLoaded {
    var snapshot: WidgetSnapshot
    /// Lines in pending-intents.jsonl, file order. Empty when `pendingReadable` is false.
    var pending: [IntentsPendingLine]
    var pendingReadable: Bool
}

enum QuickLogLoad {
    case ready(QuickLogLoaded)
    /// No snapshot yet, or one this build can't read: "Open MG once".
    case openMG
    /// No shared App Group folder in this install: the widget can neither read nor log.
    case noSharedStorage
}

enum QuickLogState: Equatable {
    case ready(QuickLogModel)
    case openMG
    case noSharedStorage
}

enum QuickLogBuild {
    /// What the 4th button may log: IntentsSymptom's cases (App/Intents/IntentsAppIntents.swift), the symptoms a single
    /// tap can log. Anything else in the snapshot is treated as "other".
    static let symptomKinds: [String] = ["bloating", "gut_pain", "urgency", "nausea", "swallowing", "headache", "other"]

    static func state(_ load: QuickLogLoad, at date: Date, calendar: Calendar) -> QuickLogState {
        switch load {
        case .openMG: return .openMG
        case .noSharedStorage: return .noSharedStorage
        case .ready(let loaded): return .ready(model(loaded, at: date, calendar: calendar))
        }
    }

    static func model(_ loaded: QuickLogLoaded, at date: Date, calendar: Calendar) -> QuickLogModel {
        let snapshot = loaded.snapshot
        let startOfToday = calendar.startOfDay(for: date)
        let preset = snapshot.med?.preset ?? QuickLogPresets.medication

        var vapeCount = snapshot.day == WidgetSnapshot.dayKey(date, calendar: calendar) ? snapshot.vape.today : 0
        var lastVape = snapshot.vape.lastAt
        var lastMed = snapshot.med?.lastTakenAt
        var openName = snapshot.drink.open?.name
        var dosesTaken = 0

        for item in loaded.pending {
            switch item.request {
            case .event(let event):
                switch event.payload {
                case .substance(let fields):
                    if fields.kind == .vapeTick || fields.kind == .vape {
                        if calendar.isDate(event.at, inSameDayAs: date) { vapeCount += fields.vape?.hits ?? 1 }
                        lastVape = later(lastVape, event.at)
                    } else if fields.kind == .caffeine {
                        openName = fields.product ?? snapshot.drink.preset.name
                    }
                case .medication(let fields):
                    if fields.presetId == preset.presetId && fields.status == .taken {
                        dosesTaken += 1
                        lastMed = later(lastMed, event.at)
                    }
                default:
                    break
                }
            case .finishDrink:
                openName = nil
            case .startNap, .syncNow:
                break
            }
        }

        // Doses from earlier days can't be acted on any more; each waiting "taken" line uses up the earliest open dose.
        let openDoses = (snapshot.med?.doses ?? [])
            .filter { $0.takenAt == nil && $0.due >= startOfToday }
            .sorted { $0.due < $1.due }
        let nextDue = openDoses.dropFirst(dosesTaken).first?.due

        var themeName = snapshot.theme
        for change in snapshot.themeChanges.sorted(by: { $0.at < $1.at }) where change.at <= date {
            themeName = change.theme
        }

        var kind = "other"
        if let wanted = snapshot.symptomKind, symptomKinds.contains(wanted) { kind = wanted }

        return QuickLogModel(
            theme: QuickLogTheme(snapshotValue: themeName),
            buttonsEnabled: snapshot.buttonsEnabled,
            vapeCount: vapeCount,
            vapeCountIsPartial: !loaded.pendingReadable,
            lastVapeAt: lastVape,
            med: QuickLogModel.Med(preset: preset, nextDue: nextDue, lastTakenAt: lastMed),
            drink: QuickLogModel.Drink(preset: snapshot.drink.preset, openName: openName),
            symptomKind: kind)
    }

    private static func later(_ a: Date?, _ b: Date) -> Date {
        guard let a else { return b }
        return max(a, b)
    }
}

/// Words and times. 24-hour clock, durations "42 min" / "1 h 05" (UX: times 24 h, durations "7 h 08").
enum QuickLogFormat {
    /// "08:00" in `calendar`'s time zone.
    static func clock(_ date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02ld:%02ld", c.hour ?? 0, c.minute ?? 0)
    }

    /// Elapsed time since `from`, rounded down: under a minute "just now" (also for a clock that runs a little behind),
    /// then "42 min", "1 h 05", and from 24 h "1 d".
    static func age(from: Date, to now: Date) -> String {
        let seconds = now.timeIntervalSince(from)
        if seconds < 60 { return "just now" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60
        if hours < 24 { return String(format: "%ld h %02ld", hours, minutes % 60) }
        return "\(hours / 24) d"
    }

    /// "last 42 min" · "just now" · "no hit on record".
    static func lastVape(_ last: Date?, now: Date) -> String {
        guard let last else { return "no hit on record" }
        let elapsed = age(from: last, to: now)
        return elapsed == "just now" ? elapsed : "last \(elapsed)"
    }

    /// Next dose of the medication button, or nil when there is nothing to say.
    ///   a dose today still ahead   "08:00"
    ///   a dose today, time passed  "due 08:00"
    ///   none left today, one taken "taken 08:12"
    ///   none left today            "tmrw 08:00"
    static func medDetail(_ med: QuickLogModel.Med, at date: Date, calendar: Calendar) -> String? {
        if let due = med.nextDue, calendar.isDate(due, inSameDayAs: date) {
            let time = clock(due, calendar: calendar)
            return due <= date ? "due \(time)" : time
        }
        if let taken = med.lastTakenAt, calendar.isDate(taken, inSameDayAs: date) {
            return "taken \(clock(taken, calendar: calendar))"
        }
        if let due = med.nextDue { return "tmrw \(clock(due, calendar: calendar))" }
        return nil
    }

    /// The 4th button's name.
    static func symptomTitle(_ kind: String) -> String {
        switch kind {
        case "bloating": return "Bloating"
        case "gut_pain": return "Gut pain"
        case "urgency": return "Urgency"
        case "nausea": return "Nausea"
        case "swallowing": return "Swallowing"
        case "headache": return "Headache"
        default: return "Symptom"
        }
    }
}

/// When a widget needs a new entry. Ages are drawn as text from the entry date, so entries are what keeps "42 min" true.
enum QuickLogTimeline {
    /// Entries run this far ahead; the timeline then asks to be rebuilt.
    static let horizon: TimeInterval = 3 * 3600

    /// `now`, then ticks while an age is on screen (every minute for the first hour after the last hit, every 5 min up
    /// to 24 h), then the `specials` (theme switch, dose time) and the next local midnight (the count restarts), all
    /// within 24 h. Sorted, no two within a second, at most 120.
    static func entryDates(now: Date, lastVapeAt: Date?, specials: [Date], calendar: Calendar) -> [Date] {
        var dates: [Date] = [now]
        if let last = lastVapeAt {
            let end = now.addingTimeInterval(horizon)
            var t = now
            while true {
                let age = t.timeIntervalSince(last)
                if age >= 24 * 3600 { break }
                t = t.addingTimeInterval(age < 3600 ? 60 : 300)
                if t > end { break }
                dates.append(t)
            }
        }
        let limit = now.addingTimeInterval(24 * 3600)
        var extra = specials
        if let midnight = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) {
            extra.append(midnight)
        }
        dates.append(contentsOf: extra.filter { $0 > now && $0 <= limit })

        var out: [Date] = []
        for d in dates.sorted() {
            if let l = out.last, d.timeIntervalSince(l) < 1 { continue }
            out.append(d)
        }
        return Array(out.prefix(120))
    }
}
