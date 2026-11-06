import Foundation
import MGContext
import MGDomain
import MGSignal
import MGStore

// WP-23a — the widget snapshot (WP-27, Widgets/Shared/WidgetSnapshot.swift): published on launch, foreground, after an
// event is saved or removed in the app, after a Settings change and when the theme changes — always AFTER the intents
// queue's `drain()` has returned (writer rule 2), and built from the REAL store only, never from SAMPLE (widgets always
// log real events; while SAMPLE is on their queued lines wait). A `.notShared` / `.failed` result is reported once per
// session on the notice line and every time in the diagnostics log.
//
// WRITTEN, NOT COMPILED.

extension AppModel {
    func publishWidgetSnapshot() async {
        // Writer rule 2: never while this app's own drain is between a line's store write and the queue update.
        guard !intentsDraining else {
            widgetPublishWanted = true
            return
        }
        let snapshot: WidgetSnapshot
        do {
            snapshot = try await buildWidgetSnapshot()
        } catch {
            return reportWidget(.failed("widget snapshot not built: \(error)"))
        }
        reportWidget(WidgetSnapshotFile.publish(snapshot))
    }

    private func reportWidget(_ result: WidgetSnapshotFile.PublishResult) {
        switch result {
        case .written, .unchanged:
            return
        case .notShared(let why):
            // Wave W11 (2026-10-11): this signature has no App Group, so there are no widgets to feed (the xtool build
            // cannot build a widget extension, xtool #145 / #313). Expected, not an error: the diagnostics log only — it
            // was a "Widgets: …" notice on every launch (Mo: "a widget error every time").
            services.strap.noteExternal("widgets: \(why)")
        case .failed(let why):
            services.strap.noteExternal("widgets: \(why)")
            if !widgetProblemShown {
                widgetProblemShown = true
                showNotice("Widgets: \(why)")
            }
        }
    }

    private func buildWidgetSnapshot() async throws -> WidgetSnapshot {
        let store = services.store
        let now = clock.now
        let cal = calendar
        let dayStart = cal.startOfDay(for: now)
        let tomorrowEnd = cal.date(byAdding: .day, value: 2, to: dayStart) ?? now

        // Writer rule 3: the Log tab's daily count (BehaviourEvents leaves out removed and unconfirmed detections).
        let recent = try await store.events(from: now.addingTimeInterval(-30 * 86400), to: now,
                                            types: [.substance, .medication])
        let hits = BehaviourEvents.vapeHits(from: recent)
        let today = hits.filter { $0.at >= dayStart }.reduce(0) { $0 + $1.hits }
        let vape = WidgetSnapshot.Vape(today: today, lastAt: hits.last?.at)

        // The medication button: the first prescription schedule (nil → the widget's fixed APP-076 preset).
        var med: WidgetSnapshot.Med?
        if let schedule = settings.schedules.first(where: { $0.kind == .prescription }) {
            let preset = Self.widgetPreset(for: schedule)
            let taken = recent.filter { e in
                guard !e.removed, case .medication(let f) = e.payload, f.status != .skipped else { return false }
                return f.scheduleId == schedule.id
                    || (f.name ?? "").caseInsensitiveCompare(schedule.name) == .orderedSame
            }
            var doses: [WidgetSnapshot.Dose] = []
            for due in Self.dueTimes(schedule, from: dayStart, to: tomorrowEnd, calendar: cal) {
                let takenAt = taken.first { abs($0.at.timeIntervalSince(due)) < 3 * 3600 }?.at
                doses.append(WidgetSnapshot.Dose(due: due, takenAt: takenAt))
            }
            med = WidgetSnapshot.Med(preset: preset, doses: doses, lastTakenAt: taken.last?.at)
        }

        // The drink button: the usual drink (else the first preset), and the open one, if any (IntentsEvents rule).
        let drinks = settings.effectiveDrinks
        let usual = drinks.first { $0.name.caseInsensitiveCompare(settings.usualDrink ?? "") == .orderedSame }
            ?? drinks.first ?? StoredDrinkPreset(name: "Coffee", caffeineMg: 95)
        var open: WidgetSnapshot.Drink.Open?
        if let o = IntentsEvents.finishing(recent, at: now), case .substance(let f) = o.payload {
            open = WidgetSnapshot.Drink.Open(name: f.product ?? "Drink", since: o.at)
        }
        let drink = WidgetSnapshot.Drink(preset: IntentsDrink(name: usual.name, caffeineMg: usual.caffeineMg), open: open)

        return WidgetSnapshot(generatedAt: now, day: WidgetSnapshot.dayKey(now, calendar: cal),
                              theme: theme.rawValue, themeChanges: themeChanges(now: now),
                              buttonsEnabled: settings.surfaceOn("widget"), vape: vape, med: med, drink: drink,
                              symptomKind: nil)
    }

    /// The theme switches the context engine has planned for the next 24 h (UX §1.1), so widgets change colour on time.
    private func themeChanges(now: Date) -> [WidgetSnapshot.ThemeChange] {
        guard let ctx = lastContext else { return [] }
        let bounds = ctx.boundaries
        let preference = settings.theme.preference(systemIsDark: systemIsDark)
        var out: [WidgetSnapshot.ThemeChange] = []
        var current = ctx.theme
        for at in bounds.changeInstants where at > now && at < now.addingTimeInterval(24 * 3600) {
            let t = PhaseClock.theme(at: at, phase: bounds.phase(at: at), boundaries: bounds, preference: preference)
            if t != current {
                out.append(WidgetSnapshot.ThemeChange(at: at, theme: t.rawValue))
                current = t
            }
        }
        return out
    }

    /// A schedule as the widget's medication preset: the Log catalogue's preset when the name matches (APP-076
    /// MedA 20 mg capsule), else the schedule's own dose as one unit. MedSchedule has no form field, so a schedule
    /// without a catalogue preset is labelled "pill" (stated here; the dose and unit are the schedule's).
    static func widgetPreset(for s: MedSchedule) -> IntentsMedication {
        if let p = LogCatalogue.standard.medication(matching: s.name) {
            return IntentsMedication(name: p.name, strength: p.strength, strengthUnit: p.strengthUnit, units: p.units,
                                     unitKind: p.unitKind, category: p.category)
        }
        return IntentsMedication(name: s.name, strength: s.dose, strengthUnit: s.unit ?? "mg", units: 1,
                                 unitKind: .pill, category: .prescription)
    }

    /// Scheduled times ("HH:MM", MedSchedule.times) on the days in [from, to) the schedule covers (days nil = daily).
    static func dueTimes(_ s: MedSchedule, from: Date, to: Date, calendar: Calendar) -> [Date] {
        var out: [Date] = []
        var day = from
        while day < to {
            let weekday = calendar.component(.weekday, from: day)
            let covered = s.days.map { days in
                ComputeSettings.contractWeekday(weekday).map { days.contains($0) } ?? false
            } ?? true
            if covered {
                for text in s.times ?? [] {
                    let parts = text.split(separator: ":").compactMap { Int($0) }
                    guard parts.count >= 2, (0..<24).contains(parts[0]), (0..<60).contains(parts[1]) else { continue }
                    out.append(PhaseClock.instant(TimeOfDay(hour: parts[0], minute: parts[1]), onDayOf: day,
                                                  calendar: calendar))
                }
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return out.sorted()
    }
}
