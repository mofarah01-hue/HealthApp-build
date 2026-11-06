import SwiftUI
import MGContext
import MGDesign
import MGDomain

// One struct per section of the alarm page (T106): keeping each section's body in its own small type stops
// SwiftUI from building one huge nested generic in `AlarmsView.body` (stack overflow in `swift_getGenericMetadata`).
// Sections draw only the state slice they need and call back through plain `let` closures (edit / send / sheet open);
// the page owns the `@State` sheet. Prefix "Alarms" because every file under UI/ compiles into one module.

// MARK: Header

struct AlarmsHeaderView: View {
    let next: String
    /// Wave W11: which iPhone layer is armed, and why not AlarmKit.
    let iphoneLine: String?
    @Environment(\.mgColors) private var colors

    init(next: String, iphoneLine: String?) {
        self.next = next
        self.iphoneLine = iphoneLine
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Settings")          // U3: the parent's name
                .mgFont(.kicker)
                .foregroundStyle(colors.topText.color)
            Text("Alarms")
                .mgFont(.title)
                .foregroundStyle(colors.ink.color)
                .accessibilityAddTraits(.isHeader)
            Text(next)
                .mgFont(.detail)
                .foregroundStyle(colors.ink2.color)
                .fixedSize(horizontal: false, vertical: true)
            if let line = iphoneLine {
                Text(line)
                    .mgFont(.detail)
                    .foregroundStyle(colors.ink2.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: Ringing

struct AlarmsSilenceRow: View {
    let send: (UIIntent) -> Void

    init(send: @escaping (UIIntent) -> Void) {
        self.send = send
    }

    var body: some View {
        SettingsRow("Silence the buzz", detail: "Stops ringing alarms and timers on this phone and asks the strap to stop.") {
            MGButton("Silence", weight: .tonal) { send(.alarms(.silence)) }
        }
    }
}

/// An alarm that is ringing (or whose window is open) right now: the I'm-up / Stop card.
struct AlarmsRingingCard: View {
    let ringing: AlarmsState.Ringing
    let send: (UIIntent) -> Void
    @Environment(\.mgColors) private var colors

    init(ringing: AlarmsState.Ringing, send: @escaping (UIIntent) -> Void) {
        self.ringing = ringing
        self.send = send
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(ringing.title)
                .mgFont(.headline)
                .foregroundStyle(colors.ink.color)
            Text(ringing.detail)
                .mgFont(.detail)
                .foregroundStyle(colors.ink2.color)
                .fixedSize(horizontal: false, vertical: true)
            if ringing.isWake {
                if ringing.locked && ringing.askConfirm {
                    MGButton("Yes — I'm up for Fajr", style: .filled) { send(.alarms(.imUp(confirmed: true))) }
                    LogHint("The strap stops buzzing and the iPhone alarm is cancelled.")
                } else {
                    MGButton("I'm up", style: .filled) { send(.alarms(.imUp(confirmed: false))) }
                }
                MGButton("Silence", style: .ghost) { send(.alarms(.stop)) }
                LogHint("This alarm buzzes until you double-tap the strap or silence it from the phone. A double-tap "
                        + "does not count as awake; getting up (heart rate + movement) or I'm up does.")
            } else {
                MGButton("Stop", style: .filled) { send(.alarms(.stop)) }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .mgSurface(.card, radius: 14)
        .padding(.vertical, 8)
    }
}

// MARK: Strap

struct AlarmsStrapSection: View {
    let strapSlot: String
    let strapSlotOn: Bool
    let upcoming: [AlarmsState.Row]
    let skipped: [AlarmsState.Row]
    let edit: (AlarmsEdit) -> Void
    let send: (UIIntent) -> Void

    init(strapSlot: String, strapSlotOn: Bool, upcoming: [AlarmsState.Row], skipped: [AlarmsState.Row],
         edit: @escaping (AlarmsEdit) -> Void, send: @escaping (UIIntent) -> Void) {
        self.strapSlot = strapSlot
        self.strapSlotOn = strapSlotOn
        self.upcoming = upcoming
        self.skipped = skipped
        self.edit = edit
        self.send = send
    }

    var body: some View {
        SettingsSection("On the strap", note: "slot 1") {
            SettingsRow("Strap alarm", detail: strapSlot) { EmptyView() }
            SettingsToggleRow("Use the strap's own alarm", detail: "The next alarm's latest time is set on the strap, so it "
                              + "fires even with the phone off (experimental on firmware 50.42).",
                              isOn: strapSlotOn) { edit(.strapSlot($0)) }
            HStack(spacing: 8) {
                MGButton("Test buzz", style: .ghost) { send(.alarms(.testBuzz(pulses: 3))) }
                MGButton("Read strap alarm", style: .ghost) { send(.alarms(.readStrapAlarm)) }
            }
            .padding(.vertical, 6)
            ForEach(upcoming) { row in
                SettingsRow(row.title, detail: row.detail) { EmptyView() }
            }
            ForEach(skipped) { row in
                SettingsRow(row.title, detail: row.detail) { SettingsTag("not ringing") }
            }
        }
    }
}

// MARK: Fajr

struct AlarmsFajrSection: View {
    let fajr: FajrWakeSettings
    let fajrToday: String?
    let fajrNotes: [String]
    let location: String
    let match: String?
    let matchMethod: PrayerMethod?
    let edit: (AlarmsEdit) -> Void
    let send: (UIIntent) -> Void
    /// Opens the "Match Pillars" sheet (the page owns the sheet state).
    let openPillars: () -> Void
    @Environment(\.mgColors) private var colors

    init(fajr: FajrWakeSettings, fajrToday: String?, fajrNotes: [String], location: String, match: String?,
         matchMethod: PrayerMethod?, edit: @escaping (AlarmsEdit) -> Void, send: @escaping (UIIntent) -> Void,
         openPillars: @escaping () -> Void) {
        self.fajr = fajr
        self.fajrToday = fajrToday
        self.fajrNotes = fajrNotes
        self.location = location
        self.match = match
        self.matchMethod = matchMethod
        self.edit = edit
        self.send = send
        self.openPillars = openPillars
    }

    var body: some View {
        SettingsSection("Fajr wake", note: "harder locked") {
            SettingsToggleRow("Fajr wake", detail: fajrToday == nil ? "Wakes you in a window before Fajr, at the latest "
                              + "before sunrise." : nil, isOn: fajr.on) { edit(.fajrOn($0)) }
            if let fajrToday {
                Text(fajrToday)
                    .mgFont(.number)
                    .foregroundStyle(colors.ink.color)
                    .padding(.vertical, 8)
                    .frame(minHeight: MGSpace.rowMinHeight)
            }
            ForEach(fajrNotes, id: \.self) { LogHint($0).padding(.vertical, 4) }
            AlarmsWeekdayChips(selected: fajr.weekdays) { d, on in edit(.fajrWeekday(d, on)) }
            AlarmsStepperRow("Window opens before Fajr", value: fajr.minutesBeforeFajr, range: 0...120, step: 5,
                             unit: "min") { edit(.fajrBeforeFajr($0)) }
            AlarmsStepperRow("Latest time before sunrise", value: fajr.minutesBeforeSunrise, range: 0...120, step: 5,
                             unit: "min") { edit(.fajrBeforeSunrise($0)) }
            SettingsRow("Method", detail: "Pillars' times matched ISNA 15° at your location on 11 Oct.") {
                Menu {
                    ForEach(PrayerMethod.allCases, id: \.self) { m in
                        Button(m.title) { edit(.fajrMethod(m)) }
                    }
                } label: {
                    SettingsValueText(fajr.method.title)
                }
            }
            AlarmsStepperRow("Fajr adjust", value: fajr.fajrAdjustMinutes, range: -30...30, step: 1,
                             unit: "min") { edit(.fajrAdjust($0)) }
            SettingsRow("Location", detail: location) {
                MGButton("Use my location", style: .ghost) { send(.alarms(.useMyLocation)) }
            }
            SettingsLinkRow("Match Pillars", detail: match ?? "Type today's Fajr from Pillars; the method within "
                            + "2 min is picked.", action: openPillars) { EmptyView() }
            if let m = matchMethod, m != fajr.method {
                MGButton("Use \(m.title)", style: .filled) { send(.alarms(.useMethod(m))) }
                    .padding(.vertical, 6)
            }
            AlarmsStepperRow("Pulses per buzz", value: fajr.pulses, range: 1...8, step: 1, unit: "") {
                edit(.fajrPulses($0))
            }
            AlarmsStepperRow("Buzz again every", value: fajr.repeatEveryMinutes, range: 1...10, step: 1,
                             unit: "min") { edit(.fajrRepeatEvery($0)) }
            LogHint("Harder locked: it buzzes at a light-sleep moment in the window (or at the latest time), then again "
                    + "every \(fajr.repeatEveryMinutes) min until you double-tap the strap, silence it from the phone, "
                    + "the strap sees you up — walking, or heart rate up for 5 min while moving — or you tap I'm up "
                    + "twice. The iPhone alarm rings \(fajr.backstopDelayMinutes) min after the latest time unless you are up.")
                .padding(.vertical, 6)
        }
    }
}

// MARK: Normal wake

struct AlarmsNormalSection: View {
    let normalOn: Bool
    let normalNotes: [String]
    let normalWeekly: [WeekdayWake]
    let normalWindowMinutes: Int
    let normal: NormalWakeSettings
    let edit: (AlarmsEdit) -> Void
    let send: (UIIntent) -> Void
    /// Opens the per-weekday time editor sheet (the page owns the sheet state).
    let openNormalTime: (Int) -> Void
    @Environment(\.mgColors) private var colors

    init(normalOn: Bool, normalNotes: [String], normalWeekly: [WeekdayWake], normalWindowMinutes: Int,
         normal: NormalWakeSettings, edit: @escaping (AlarmsEdit) -> Void, send: @escaping (UIIntent) -> Void,
         openNormalTime: @escaping (Int) -> Void) {
        self.normalOn = normalOn
        self.normalNotes = normalNotes
        self.normalWeekly = normalWeekly
        self.normalWindowMinutes = normalWindowMinutes
        self.normal = normal
        self.edit = edit
        self.send = send
        self.openNormalTime = openNormalTime
    }

    var body: some View {
        SettingsSection("Normal wake", note: "with Tonight's smart wake") {
            SettingsToggleRow("Normal wake", detail: "The smart wake's times and window — the iPhone rings in light sleep; "
                              + "the strap buzzes with it.", isOn: normalOn) { send(.setSmartWake($0)) }
            ForEach(normalNotes, id: \.self) { LogHint($0).padding(.vertical, 4) }
            ForEach(SettingsWeekday.order, id: \.self) { d in
                let t = normalWeekly.first { $0.weekday == d }?.time
                SettingsLinkRow(SettingsWeekday.names[d] ?? "", action: { openNormalTime(d) }) {
                    Text(t.map { MGFormat.time($0) } ?? "not set")
                        .mgFont(t == nil ? MGTextStyle.detail : MGTextStyle.number)
                        .foregroundStyle(t == nil ? colors.mute.color : colors.ink.color)
                        .multilineTextAlignment(.trailing)
                }
            }
            AlarmsStepperRow("Smart window", value: normalWindowMinutes, range: 10...45, step: 5, unit: "min") {
                send(.setWakeWindow(minutes: $0))
            }
            SettingsToggleRow("Buzz the strap", isOn: normal.strapOn) { edit(.normalStrap($0)) }
            SettingsToggleRow("Again during the smart window", detail: "After the latest time it buzzes every "
                              + "\(normal.repeatEveryMinutes) min until you double-tap the strap or silence it from the "
                              + "phone.", isOn: normal.repeatUntilMoving) { edit(.normalRepeat($0)) }
            SettingsToggleRow("Skip it if I stayed up after Fajr", detail: "Uses the strap's movement and heart rate since "
                              + "the Fajr wake; with too little data it rings anyway.",
                              isOn: normal.skipIfAwakeAfterFajr) { edit(.normalSkipAfterFajr($0)) }
            AlarmsStepperRow("Pulses per buzz", value: normal.pulses, range: 1...8, step: 1, unit: "") {
                edit(.normalPulses($0))
            }
        }
    }
}

// MARK: One-day / two-day / week-long changes

struct AlarmsChangesSection: View {
    let overrides: [AlarmsState.Row]
    let send: (UIIntent) -> Void
    /// Opens the "Add a change" sheet (the page owns the sheet state).
    let openChange: () -> Void

    init(overrides: [AlarmsState.Row], send: @escaping (UIIntent) -> Void, openChange: @escaping () -> Void) {
        self.overrides = overrides
        self.send = send
        self.openChange = openChange
    }

    var body: some View {
        SettingsSection("Changes", note: "one day, two days or a week") {
            ForEach(overrides) { row in
                SettingsRow(row.title, detail: row.detail) {
                    MGButton("Remove", style: .ghost) {
                        if let id = UUID(uuidString: row.id) { send(.alarms(.deleteOverride(id))) }
                    }
                }
            }
            if overrides.isEmpty {
                LogHint("No changes: every alarm follows its weekly days.").padding(.vertical, 6)
            }
            MGButton("Add a change", style: .ghost) { openChange() }
                .padding(.vertical, 6)
        }
    }
}

// MARK: Custom alarms

struct AlarmsCustomSection: View {
    let custom: [CustomAlarm]
    let send: (UIIntent) -> Void
    /// Opens the custom-alarm editor sheet (nil = new).
    let openCustom: (CustomAlarm?) -> Void
    @Environment(\.mgColors) private var colors

    init(custom: [CustomAlarm], send: @escaping (UIIntent) -> Void, openCustom: @escaping (CustomAlarm?) -> Void) {
        self.custom = custom
        self.send = send
        self.openCustom = openCustom
    }

    var body: some View {
        SettingsSection("Alarms", note: "strap buzz + iPhone backstop") {
            ForEach(custom) { a in
                HStack(alignment: .center, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(AlarmsView.customTime(a))
                            .mgFont(.number)
                            .foregroundStyle(colors.ink.color)
                        Text(a.label.isEmpty ? "Alarm" : a.label)
                            .mgFont(.rowTitle)
                            .foregroundStyle(colors.ink.color)
                        Text(AlarmsView.customScheduleDetail(a))
                            .mgFont(.detail)
                            .foregroundStyle(colors.ink2.color)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Toggle("", isOn: Binding(get: { a.on }, set: { on in
                        var b = a
                        b.on = on
                        send(.alarms(.saveCustom(b)))
                    }))
                    .labelsHidden()
                    .tint(colors.focus.color)
                    .accessibilityLabel(a.label.isEmpty ? "Alarm" : a.label)
                    Button("Delete", role: .destructive) { send(.alarms(.deleteCustom(a.id))) }
                        .buttonStyle(.plain)
                        .mgFont(.body)
                        .foregroundStyle(colors.text(.body).color)
                }
                .padding(.vertical, 6)
                .frame(minHeight: MGSpace.rowMinHeight)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(colors.rule.color).frame(height: 1).accessibilityHidden(true)
                }
                .contentShape(Rectangle())
                // T152: long-press now opens a menu (Edit / Delete) so every row can be deleted right here; before, a
                // long-press went straight to the editor and delete was only inside it.
                .contextMenu {
                    Button("Edit") { openCustom(a) }
                    Button("Delete", role: .destructive) { send(.alarms(.deleteCustom(a.id))) }
                }
            }
            HStack(spacing: 8) {
                MGButton("Add alarm", style: .ghost) { openCustom(nil) }
                if !custom.isEmpty {
                    Menu {
                        ForEach(custom) { a in
                            Button(a.label.isEmpty ? "Alarm" : a.label) { openCustom(a) }
                        }
                        Divider()
                        ForEach(custom) { a in
                            Button("Delete \(a.label.isEmpty ? "Alarm" : a.label)", role: .destructive) {
                                send(.alarms(.deleteCustom(a.id)))
                            }
                        }
                    } label: {
                        Text("Edit…").mgFont(.button).foregroundStyle(colors.ink.color)
                            .padding(.horizontal, 16).frame(minHeight: MGSpace.tapTarget)
                    }
                }
            }
            .padding(.vertical, 6)
        }
    }
}

// Timers: retired here (T153, 2026-10-12). The one timer UI is `TimersPanel` in UI/Timers/TimersSection.swift; keeping both
// would make one timer buzz twice.

// MARK: Calendar and Reminders

struct AlarmsCalendarSection: View {
    let calendar: CalendarBuzzSettings
    let calendarAccess: String
    let remindersAccess: String
    let calendars: [AlarmsState.Source]
    let reminderLists: [AlarmsState.Source]
    let edit: (AlarmsEdit) -> Void
    let send: (UIIntent) -> Void

    init(calendar: CalendarBuzzSettings, calendarAccess: String, remindersAccess: String,
         calendars: [AlarmsState.Source], reminderLists: [AlarmsState.Source],
         edit: @escaping (AlarmsEdit) -> Void, send: @escaping (UIIntent) -> Void) {
        self.calendar = calendar
        self.calendarAccess = calendarAccess
        self.remindersAccess = remindersAccess
        self.calendars = calendars
        self.reminderLists = reminderLists
        self.edit = edit
        self.send = send
    }

    var body: some View {
        SettingsSection("Calendar and Reminders", note: "best-effort, read-only") {
            SettingsToggleRow("Buzz for calendar events", detail: "Calendar access: \(calendarAccess)",
                              isOn: calendar.eventsOn) { edit(.calendarEvents($0)) }
            if calendarAccess != "allowed" {
                MGButton("Allow reading Calendar", style: .ghost) { send(.alarms(.requestCalendarAccess)) }
                    .padding(.vertical, 4)
            }
            AlarmsSourceChips(list: calendars) { id, on in send(.alarms(.pickCalendar(id: id, on: on))) }
            SettingsToggleRow("Buzz for reminders", detail: "Reminders access: \(remindersAccess)",
                              isOn: calendar.remindersOn) { edit(.calendarReminders($0)) }
            if remindersAccess != "allowed" {
                MGButton("Allow reading Reminders", style: .ghost) { send(.alarms(.requestRemindersAccess)) }
                    .padding(.vertical, 4)
            }
            AlarmsSourceChips(list: reminderLists) { id, on in send(.alarms(.pickReminderList(id: id, on: on))) }
            AlarmsStepperRow("Pulses", value: calendar.pulses, range: 1...8, step: 1, unit: "") {
                edit(.calendarPulses($0))
            }
            AlarmsStepperRow("Before an event starts", value: calendar.leadMinutes, range: 0...60, step: 5,
                             unit: "min") { edit(.calendarLead($0)) }
            LogHint("Your dashboard's calendar: copy its ICS (webcal) link, then on the iPhone open iOS Settings › Apps › "
                    + "Calendar › Calendar Accounts › Add Account › Other › Add Subscribed Calendar and paste it. It then "
                    + "appears above to pick. Buzzes only while this app runs and the strap is connected.")
                .padding(.vertical, 6)
        }
    }
}

// MARK: Notification buzz by app and person

/// T53 (D-039): master switch, then one on/off row per app and per person Mo has added. Each row's on/off is a
/// pulses value underneath (0 = off; switching a row on stores a default of 3 pulses) — same shape as the
/// Calendar/Reminders buzz toggles above, reusing `SettingsToggleRow` / `SettingsSection`.
struct AlarmsNotificationsSection: View {
    let notifications: NotificationBuzzSettings
    let edit: (AlarmsEdit) -> Void

    init(notifications: NotificationBuzzSettings, edit: @escaping (AlarmsEdit) -> Void) {
        self.notifications = notifications
        self.edit = edit
    }

    @State private var newApp = ""
    @State private var newPerson = ""
    private let defaultPulses = 3

    var body: some View {
        SettingsSection("Notification buzz", note: "by app and person") {
            SettingsToggleRow("Buzz for notifications", detail: "Only the sending app's id and a person's name are "
                              + "read, never the message (NotificationBuzz.swift).", isOn: notifications.on) {
                edit(.notificationsOn($0))
            }
            if notifications.on {
                ForEach(notifications.apps.keys.sorted(), id: \.self) { id in
                    SettingsToggleRow(id, isOn: (notifications.apps[id] ?? 0) > 0) { on in
                        edit(.notificationApp(id: id, pulses: on ? defaultPulses : 0))
                    }
                }
                addRow("App id (e.g. personal-os)", text: $newApp) {
                    edit(.notificationApp(id: newApp, pulses: defaultPulses))
                    newApp = ""
                }
                ForEach(notifications.people.keys.sorted(), id: \.self) { name in
                    SettingsToggleRow(name, isOn: (notifications.people[name] ?? 0) > 0) { on in
                        edit(.notificationPerson(name: name, pulses: on ? defaultPulses : 0))
                    }
                }
                addRow("Person's name", text: $newPerson) {
                    edit(.notificationPerson(name: newPerson, pulses: defaultPulses))
                    newPerson = ""
                }
            }
        }
    }

    private func addRow(_ placeholder: String, text: Binding<String>, add: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            TextField(placeholder, text: text)
                .formSubmit()                  // r9v (K1)
            MGButton("Add", style: .ghost, action: add)
                .disabled(text.wrappedValue.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.vertical, 6)
    }
}

// MARK: Log and reliability

struct AlarmsLogSection: View {
    let log: [AlarmsState.Row]

    init(log: [AlarmsState.Row]) {
        self.log = log
    }

    var body: some View {
        SettingsSection("What the strap said", note: "newest first") {
            if log.isEmpty {
                LogHint("Nothing yet. Arming, buzzes and the strap's alarm events (set 56, fired 57, cleared 59, "
                        + "haptics 60 / 100, double-tap 14) show here.").padding(.vertical, 6)
            }
            ForEach(log) { row in
                SettingsRow(row.title, detail: row.detail) { EmptyView() }
            }
        }
    }
}

struct AlarmsReliabilitySection: View {
    let reliability: [String]

    init(reliability: [String]) {
        self.reliability = reliability
    }

    var body: some View {
        SettingsSection("What to rely on") {
            ForEach(reliability, id: \.self) { line in
                LogHint(line).padding(.vertical, 4)
            }
        }
    }
}

// MARK: Pieces

/// The Fajr weekdays as chips (1 = Sunday … 7 = Saturday).
struct AlarmsWeekdayChips: View {
    let selected: Set<Int>
    let toggle: (Int, Bool) -> Void

    init(selected: Set<Int>, toggle: @escaping (Int, Bool) -> Void) {
        self.selected = selected
        self.toggle = toggle
    }

    var body: some View {
        FlowLayout(spacing: 8, lineSpacing: 8) {
            ForEach(SettingsWeekday.order, id: \.self) { d in
                Chip(SettingsWeekday.short[d] ?? "", selected: selected.contains(d)) { toggle(d, !selected.contains(d)) }
            }
        }
        .padding(.vertical, 8)
    }
}

/// A calendar's / reminder list's calendars as pickable chips.
struct AlarmsSourceChips: View {
    let list: [AlarmsState.Source]
    let toggle: (String, Bool) -> Void

    init(list: [AlarmsState.Source], toggle: @escaping (String, Bool) -> Void) {
        self.list = list
        self.toggle = toggle
    }

    var body: some View {
        FlowLayout(spacing: 8, lineSpacing: 8) {
            ForEach(list) { src in
                Chip(src.title, selected: src.picked) { toggle(src.id, !src.picked) }
            }
        }
        .padding(.vertical, list.isEmpty ? 0 : 8)
    }
}
