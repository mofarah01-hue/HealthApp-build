import Foundation
import MGContext
import MGDomain
import MGStore
import MGSync

// WP-23a — Settings edits (UX §14; BRIEF WP-18 row: profile ids birth_date, sex, height_cm, weight_kg, hr_max (also
// "hrmax"), hr_rest; a text that can't be parsed is refused with a reason), SAMPLE mode, and the composition's side of
// a settings change (catalogues for the Log and for Shortcuts, a recompute, smart wake re-planned).
//
// WRITTEN, NOT COMPILED.

extension AppModel {
    /// T9841: tell the notification centre which kinds Mo skips (at launch and after each change).
    func applySkippedNotifications() async {
        await services.notifyCenter.setSkipped(Set(settings.skippedNotifications))
    }

    /// R8e (S4): a setting that only changes how something looks or what a list offers: saved, nothing recomputed.
    func lookChanged() async {
        rebuildLogCatalogue()
        await saveState()
        writeIntentsCatalogue()
    }

    /// After any setting that changes what is computed or planned.
    func modelInputsChanged() async {
        lastSmartWakeRequest = nil
        rebuildLogCatalogue()
        await saveState()
        writeIntentsCatalogue()
        await services.compute.request(.settingsChanged)
        await publishWidgetSnapshot()
    }

    func rebuildLogCatalogue() {
        logCatalogue = LogCatalogue(
            drinks: PresetLists.drinkChoices(settings.presetLists,
                                             legacy: settings.effectiveDrinks.map { (name: $0.name, caffeineMg: $0.caffeineMg) })
                .map { LogDrink(name: $0.name, caffeineMg: $0.caffeineMg) },
            medications: loggableMedications(),
            supplements: loggableSupplements(),
            alcohol: LogCatalogue.standard.alcohol,
            presetLists: settings.presetLists)
    }

    /// Round 5 (C21): the Log forms read Mo's own lists. Medications: his list (none before the list was
    /// ever seeded, T9973: no medication name is written in source). Supplements: his list plus the supplement schedules, no name twice; none is invented.
    func loggableMedications() -> [LogMedication] {
        let lists = settings.presetLists
        guard lists.seeded || !lists.medications.isEmpty else { return LogCatalogue.standard.medications }
        return lists.medications.map {
            LogMedication(name: $0.name, strength: $0.amount, strengthUnit: $0.unit, units: 1, unitKind: .capsule,
                          category: .prescription)
        }
    }

    func loggableSupplements() -> [LogSupplement] {
        var out = settings.presetLists.supplements.map {
            LogSupplement(name: $0.name, strength: $0.amount, strengthUnit: $0.amount == nil ? nil : $0.unit,
                          defaultPills: 1)
        }
        for s in settings.schedules where s.kind == .supplement
            && !out.contains(where: { $0.name.caseInsensitiveCompare(s.name) == .orderedSame }) {
            out.append(LogSupplement(name: s.name, strength: s.dose, strengthUnit: s.unit, defaultPills: 1))
        }
        return out
    }

    /// Sample data (ARCHITECTURE §4.12): off by default; while on every screen shows the banner, nothing is written,
    /// nothing syncs, no alarm is armed. The only control that works in SAMPLE mode is this switch.
    func setSampleData(_ on: Bool) async {
        settings.sampleData = on
        lastSmartWakeRequest = nil
        await saveState()
        showNotice(on ? "Sample data is on: every screen shows the prototype day. Nothing is saved or sent."
                      : "Sample data is off: your own data again.")
    }

    func editSetting(_ edit: SettingEdit) async {
        guard !isSample else { return showNotice(SettingsIntents.sampleReason) }
        var lookOnly = false           // R8e (S4): preset lists only change what the Log offers
        switch edit {
        case .profileField(let id, let text):
            let before = effectiveProfile                       // P9745: a typed value recomputes the days it changes
            switch ProfileParsing.apply(id: id, text: text, to: profile) {
            case .success(let p):
                do {
                    try await services.store.setProfile(p)
                    profile = p
                } catch { return showNotice("Not saved: \(error)") }
                await recomputeAfterProfileArrived(from: before)
            case .failure(let why):
                return showNotice(why.message)
            }
        case .profileFromPC:
            guard await fillProfileFromPC() else { return }
        case .needOverride(let minutes):
            if let m = minutes, !(180...720).contains(m) {
                return showNotice("A sleep need between 3 h and 12 h, please.")
            }
            settings.needOverrideMinutes = minutes
        case .calorieGoalKcal(let kcal):
            if let kcal {
                guard kcal.isFinite, kcal > 0 else { return showNotice("A calorie goal above zero, please.") }
            }
            settings.calorieGoalKcal = kcal
        case .saveSchedule(let schedule):
            if let i = settings.schedules.firstIndex(where: { $0.id == schedule.id }) {
                settings.schedules[i] = schedule
            } else {
                settings.schedules.append(schedule)
            }
        case .removeSchedule(let id):
            settings.schedules.removeAll { $0.id == id }
        case .saveDrinkPreset(let preset):
            guard preset.caffeineMg.isFinite, preset.caffeineMg >= 0, preset.caffeineMg <= 1000 else {
                return showNotice("Caffeine per drink between 0 and 1000 mg, please.")
            }
            let stored = StoredDrinkPreset(name: preset.name, caffeineMg: preset.caffeineMg)
            if settings.drinkPresets.isEmpty { settings.drinkPresets = settings.effectiveDrinks }
            if let i = settings.drinkPresets.firstIndex(where: { $0.name == preset.name }) {
                settings.drinkPresets[i] = stored
            } else {
                settings.drinkPresets.append(stored)
            }
            lookOnly = true
        case .savePresetEntry(let list, let entry):
            guard settings.presetLists.save(entry, in: list) else {
                return showNotice("A name, and a strength above zero if you enter one, please.")
            }
            lookOnly = true
        case .saveDrinkEntry(let drink):
            guard settings.presetLists.save(drink) else {
                return showNotice("A name, and caffeine between 0 and 1000 mg if you enter it, please.")
            }
            lookOnly = true
        case .removePresetEntry(let list, let id):
            settings.presetLists.remove(id: id, from: list)
            lookOnly = true
        case .removeDrinkPreset(let name):
            if settings.drinkPresets.isEmpty { settings.drinkPresets = settings.effectiveDrinks }
            settings.drinkPresets.removeAll { $0.name == name }
            lookOnly = true
        case .skinTypeQuiz(let answers):
            if let answers {
                guard let type = SkinTypeQuiz.type(for: answers) else {
                    return showNotice("Answer all six skin-type questions before saving.")
                }
                settings.fitzpatrickSkinType = type.rawValue
            } else {
                settings.fitzpatrickSkinType = nil
            }
        case .smartWake(let mode, let gateMinutes, let restPercent):
            // T9841: stored as given when valid; the plan reads them (a time-gate mode with no gate runs as "open").
            guard SmartWakeModes.isValid(mode) else { return showNotice("That smart-wake mode is not one of the options.") }
            if let g = gateMinutes, !(0..<1440).contains(g) { return showNotice("A time of day for the gate, please.") }
            settings.smartWakeMode = mode
            settings.smartWakeGateMinutes = gateMinutes
            settings.smartWakeRestPercent = min(max(restPercent, SmartWakeModes.restPercentRange.lowerBound),
                                                SmartWakeModes.restPercentRange.upperBound)
        case .notificationSkip(let kind, let skip):
            // T9841: an alarm can't be skipped here; every other kind can, and the centre drops it before it posts.
            guard NotificationSkips.canSkip(kind) else { return showNotice(NotificationSkips.alarmReason) }
            var set = Set(settings.skippedNotifications)
            if skip { set.insert(kind) } else { set.remove(kind) }
            settings.skippedNotifications = set.sorted()
            await applySkippedNotifications()
            lookOnly = true
        case .vitaminDLocation(let name, let latitude, let longitude):
            if name == nil, latitude == nil, longitude == nil {
                settings.vitaminDLocation = nil
                break
            }
            guard let place = name?.trimmingCharacters(in: .whitespacesAndNewlines), !place.isEmpty,
                  let latitude, latitude.isFinite, (-90...90).contains(latitude),
                  let longitude, longitude.isFinite, (-180...180).contains(longitude) else {
                return showNotice("Enter a place name, latitude from -90 to 90, and longitude from -180 to 180.")
            }
            settings.vitaminDLocation = VitaminDRoughLocation(
                name: place, latitude: (latitude * 10).rounded() / 10, longitude: (longitude * 10).rounded() / 10)
        }
        if lookOnly { await lookChanged() } else { await modelInputsChanged() }
    }

    /// T27 (2026-10-12): at launch and on foreground, fill the empty profile fields from the PC without a tap. Only
    /// while a fillable field is empty; says nothing unless something was filled (a PC that is off is not news).
    func autoFillProfileFromPC() async {
        guard !isSample, ProfileFill.hasGaps(profile) else { return }
        _ = await fillProfileFromPC(quiet: true)
    }

    /// Tracker #90 (2026-10-11): GET /v1/profile, then only the empty fields filled (ProfileFill). True = saved.
    /// `quiet` (T27): no notice unless the profile changed, no "asking" line, no failure lines.
    func fillProfileFromPC(quiet: Bool = false) async -> Bool {
        if !quiet { showNotice("Asking your PC for the profile values…") }
        switch await PCLabProfile.fetch(credentials: KeychainCredentialStore()) {
        case .notPaired:
            if !quiet { showNotice("No PC paired — pair PC Lab in Settings › PC Lab first.") }
        case .unreachable(let why):
            if !quiet { showNotice("PC not reachable (\(why)). Nothing changed.") }
        case .refused(let why):
            if !quiet { showNotice("The PC didn't give the profile: \(why)") }
        case .profile(let pc):
            let v = pc.profile
            // P9745: keep the PC's profile (every model reads Me + this, `effectiveProfile`), and remember what the
            // models saw before, to recompute the days a late value changes.
            let before = effectiveProfile
            let snapshot = PCProfileSnapshot(birthDate: v.birthDate, sex: v.sex, heightCm: v.heightCm, weightKg: v.weightKg,
                                             hrMaxMeasured: v.hrMaxMeasured, hrRestBaseline: v.hrRestBaseline,
                                             fatFreeMassKg: v.fatFreeMassKg, sources: pc.sources)
            if snapshot != pcProfile {
                do {
                    try await services.store.setPCProfile(snapshot)
                    pcProfile = snapshot
                } catch {
                    if !quiet { showNotice("The PC's profile couldn't be kept on the phone: \(error)") }
                }
            }
            let values = PCProfileValues(birthDate: v.birthDate, sex: v.sex, heightCm: v.heightCm, weightKg: v.weightKg,
                                         hrMaxMeasured: v.hrMaxMeasured, hrRestBaseline: v.hrRestBaseline,
                                         sources: pc.sources)
            let outcome = ProfileFill.fill(profile, from: values, today: LocalDay(date: clock.now, calendar: calendar))
            var text = ProfileFill.notice(outcome)
            if let problem = pc.problem { text += " (PC: \(problem))" }
            guard outcome.profile != profile else {
                await recomputeAfterProfileArrived(from: before)        // PC value arrived but Me already holds it
                if !quiet { showNotice(text) }
                return false
            }
            do {
                try await services.store.setProfile(outcome.profile)
                profile = outcome.profile
            } catch {
                if !quiet { showNotice("Not saved: \(error)") }
                return false
            }
            // B-1 (round 2, 2026-10-14): Tanaka max HR (and age-based calories, VO2 max, fitness age) are stored with the
            // reason "profile has no birth date" when the day was computed before the birth date arrived. The quiet
            // launch / foreground fill (T27) saved the profile but never asked for a recompute, and the hourly and
            // foreground runs skip days with no new strap data, so the blank stayed all day. Recompute today and yesterday.
            // P9745: not only today and yesterday: every stored day that carries a blank "needs ... profile" reason.
            await recomputeAfterProfileArrived(from: before)
            showNotice(text)
            return true
        }
        return false
    }

    /// P9745: a profile field arrived later (from the PC, or typed): recompute the days it changes. A fill recomputes today,
    /// yesterday and every stored day (newest 60) whose blank names a missing profile field; a changed existing value
    /// recomputes the newest 60 stored days (`EffectiveProfile.affectedDays`).
    func recomputeAfterProfileArrived(from before: Profile) async {
        let after = effectiveProfile
        guard !EffectiveProfile.changedFields(from: before, to: after).isEmpty else { return }
        let today = LocalDay(date: clock.now, calendar: calendar)
        var rows: [(day: LocalDay, metric: Metric)] = []          // every stored day of the last 120, not the newest per name
        for k in 0..<120 {
            let d = today.adding(days: -k)
            for m in (try? await services.store.metrics(on: d)) ?? [] { rows.append((d, m)) }
        }
        let days = EffectiveProfile.affectedDays(rows: rows, today: today,
                                                 filledOnly: EffectiveProfile.onlyFills(from: before, to: after))
        await services.compute.request(.settingsChanged, days: days)
    }

    // MARK: Export (APP-114, ARCHITECTURE §4.12)

    func exportEverything() async {
        guard !isSample else { return showNotice(SettingsIntents.sampleReason) }
        let today = LocalDay(date: clock.now, calendar: calendar)
        var first = today
        if let e = try? await services.store.events(from: Date(timeIntervalSince1970: 0), to: clock.now).first {
            first = min(first, LocalDay(date: e.at, calendar: calendar))
        }
        if let ts = try? await services.store.historyJournal(limit: 100_000).compactMap(\.firstTs).min() {
            first = min(first, LocalDay(date: Date(timeIntervalSince1970: TimeInterval(ts)), calendar: calendar))
        }
        await export(from: max(first, today.adding(days: -365)), to: today)
    }

    func export(from: LocalDay, to: LocalDay) async {
        guard !isSample else { return showNotice(SettingsIntents.sampleReason) }
        guard from <= to else { return showNotice("The export range ends before it starts.") }
        guard from.days(to: to) <= 366 else { return showNotice("Export at most a year at a time.") }
        do {
            let folder = try await ExportBuilder.build(store: services.store, from: from, to: to, calendar: calendar)
            exportDocument = ExportFolderDocument(name: "MG export \(from.iso) to \(to.iso)", folder: folder)
        } catch {
            showNotice("Export failed: \(error)")
        }
    }

    func exportFinished(_ result: Result<URL, Error>) {
        let size = exportDocument.map { ByteCountFormatter.string(fromByteCount: Int64($0.byteCount), countStyle: .file) }
        exportDocument = nil
        switch result {
        case .success: showNotice(size.map { "Exported \($0)." } ?? "Exported.")     // r9v (S8): the measured size
        case .failure(let error): showNotice("Export not saved: \(error.localizedDescription)")
        }
    }
}

/// Profile rows by `LabeledValue.id` (BRIEF WP-18 row). A blank text clears the field.
enum ProfileParsing {
    struct Refusal: Error, Equatable {
        var message: String
    }

    static func apply(id: String, text: String?, to profile: Profile) -> Result<Profile, Refusal> {
        var p = profile
        let t = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let clear = t.isEmpty
        func number(_ range: ClosedRange<Double>, _ what: String) -> Result<Double?, Refusal> {
            if clear { return .success(nil) }
            guard let v = Double(t.replacingOccurrences(of: ",", with: ".")), range.contains(v) else {
                return .failure(Refusal(message: "\(what): a number from \(Int(range.lowerBound)) to \(Int(range.upperBound)), please."))
            }
            return .success(v)
        }
        switch id {
        case "birth_date":
            if clear { p.birthDate = nil; break }
            guard let d = LocalDay(iso: t) else {
                return .failure(Refusal(message: "Birth date as YYYY-MM-DD, please."))
            }
            p.birthDate = d
        case "sex":
            if clear { p.sex = nil; break }
            guard let s = Profile.Sex(rawValue: t.lowercased()) else {
                return .failure(Refusal(message: "Sex: male, female or other."))
            }
            p.sex = s
        case "height_cm":
            // T3/T111: typed as feet-inches (or "172 cm"), stored in cm.
            if clear { p.heightCm = nil; break }
            guard let cm = ProfileUnits.parseHeightCm(t) else {
                return .failure(Refusal(message: "Height like 5'8 or 172 cm, please."))
            }
            p.heightCm = cm
        case "weight_kg":
            // T3/T111: typed in pounds (or "70 kg"), stored in kg.
            if clear { p.weightKg = nil; break }
            guard let kg = ProfileUnits.parseWeightKg(t) else {
                return .failure(Refusal(message: "Weight like 155 lb or 70 kg, please."))
            }
            p.weightKg = kg
        case "hr_max", "hrmax":
            // ALG-106 accepts a measured max of 100…240 bpm.
            switch number(100...240, "Max heart rate") {
            case .success(let v): p.hrMaxMeasured = v
            case .failure(let r): return .failure(r)
            }
        case "hr_rest":
            switch number(25...120, "Resting heart rate") {
            case .success(let v): p.hrRestBaseline = v
            case .failure(let r): return .failure(r)
            }
        default:
            return .failure(Refusal(message: "Unknown profile field \(id)."))
        }
        return .success(p)
    }
}
