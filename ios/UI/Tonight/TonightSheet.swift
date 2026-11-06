import SwiftUI
import MGContext
import MGDesign
import MGDomain

/// Tonight — the sheet from the dial's bedtime / wake-window callout or the "Tonight" Now row (UX-SPEC §8.1; owner WP-12).
///
/// Blocks, in the UX order: BedtimeBlock (bed → asleep → up, and the need sum) · LatestWakePicker ("must be up by" per
/// weekday) · SmartWakeBlock (toggle bound to `TonightState.smartWake`, window length, how it rings — with the plain
/// "may not wake you on Silent" sentence below iOS 26) · CaffeineAtBedtime · NightSoundsToggle · WindDownToggle.
/// Smart wake rings the iPhone; the strap buzzes with it when Settings › Alarms has the normal wake's strap buzz on
/// (CLAUDE.md rule 5 as changed 2026-10-11; `AppModel.alarmsSmartWakeRang` makes the buzz part of the same ring).
/// Pure rendering of `TonightState`; every change is a `UIIntent` through `send`. A switch or chip shows the state, plus
/// a local pick that bridges the gap until the rebuilt state arrives (cleared when it does, or after 2 s). `theme` is
/// optional: the host normally applies `.mgTheme` above the sheet.
struct TonightSheet: View {
    let state: TonightState
    let theme: ThemeName?
    let send: (UIIntent) -> Void

    init(state: TonightState, theme: ThemeName? = nil, send: @escaping (UIIntent) -> Void) {
        self.state = state
        self.theme = theme
        self.send = send
    }

    var body: some View {
        Group {
            if let theme {
                TonightSheetContent(state: state, send: send).mgTheme(theme)
            } else {
                TonightSheetContent(state: state, send: send)
            }
        }
    }
}

/// The weekday being edited in the "must be up by" picker (a modal edit, not an in-place expansion).
private struct TonightWeekdayEdit: Identifiable {
    let weekday: Int
    var id: Int { weekday }
}

private struct TonightSheetContent: View {
    let state: TonightState
    let send: (UIIntent) -> Void

    @Environment(\.mgColors) private var colors
    @Environment(\.calendar) private var calendar
    @Environment(\.dismiss) private var dismiss
    @State private var editing: TonightWeekdayEdit?
    /// The window length just tapped, shown at once; the real state arrives after the refresh (Tonight 2).
    @State private var windowPick: Int?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                topBar
                bedtimeBlock
                latestWakePicker
                smartWakeBlock
                caffeineAtBedtime
                nightToggles
                Text("Rings your iPhone; the strap buzzes too if Settings › Alarms has it on.")
                    .mgFont(.receipt)
                    .foregroundStyle(colors.mute.color)
                    .padding(.top, MGSpace.section)
            }
            .padding(.horizontal, MGSpace.gutter)
            .padding(.top, 14)
            .padding(.bottom, 40)
        }
        .scrollIndicators(.hidden)
        .background(colors.sheet.color.ignoresSafeArea())
        .safeAreaInset(edge: .top, spacing: 0) {
            if state.sample { SampleBanner() }
        }
        .sheet(item: $editing) { edit in
            TonightWakeEditor(weekday: edit.weekday, current: time(for: edit.weekday),
                              startHint: state.latestWake.compactMap(\.time).first,
                              reference: state.bedtime, calendar: calendar, send: send)
                .mgTheme(themeName)
        }
        .environment(\.mgSend, send)
        .presentationBackground(colors.sheet.color)
        .presentationCornerRadius(MGRadius.sheet)
        .presentationDragIndicator(.visible)
    }

    /// The editor sheet does not inherit custom environment values on every iOS version, so pass the theme on.
    @Environment(\.mgTheme) private var themeName

    // MARK: Top

    private var topBar: some View {
        HStack(alignment: .firstTextBaseline) {
            // Tonight 5: no algorithm id in the title (the need's receipt names ALG-115). Tonight 3: this is a sheet, so
            // the sheet's own ink, not `topText` (which is tuned for the glow of a scrolling screen).
            Text("Tonight")
                .mgFont(.kicker)
                .foregroundStyle(colors.ink2.color)
            Spacer()
            Button("Done") { dismiss() }
                .mgFont(.button)
                .foregroundStyle(colors.ink.color)
                .frame(minWidth: MGSpace.tapTarget, minHeight: MGSpace.tapTarget, alignment: .trailing)
        }
    }

    // MARK: BedtimeBlock (APP-262, ALG-115)

    private var bedtimeBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(summary)
                .mgFont(.headline)
                .foregroundStyle(colors.ink.color)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            if let note = state.bedtimeNote {
                Text(note)
                    .mgFont(.detail)
                    .foregroundStyle(colors.ink2.color)
                    .padding(.top, 4)
            }
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(state.need.enumerated()), id: \.element.id) { index, part in
                    HStack(alignment: .firstTextBaseline) {
                        Text((part.label == "sleep debt" ? "" : Self.sign(index: index + (part.label == "your baseline need" ? 0 : 1), minutes: part.minutes)) + part.label)
                            .mgFont(.body)
                            .foregroundStyle(colors.ink.color)
                        Spacer(minLength: 8)
                        ValueView(part.value, size: .small)
                    }
                    .frame(minHeight: 52)
                    .overlay(alignment: .top) {
                        if index > 0 { Rectangle().fill(colors.rule.color).frame(height: 1) }
                    }
                    .accessibilityElement(children: .combine)
                }
                if let note = state.needNote {
                    // Tonight 4: said once, instead of three blank rows with the same sentence.
                    Text(note)
                        .mgFont(.receipt)
                        .foregroundStyle(colors.mute.color)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 8)
                        .overlay(alignment: .top) { Rectangle().fill(colors.rule.color).frame(height: 1) }
                }
                HStack(alignment: .firstTextBaseline) {
                    Text("Tonight's need").mgFont(.rowTitle).foregroundStyle(colors.ink.color)
                    Spacer(minLength: 8)
                    ValueView(state.needTotal, size: .number)
                }
                .frame(minHeight: 52)
                .overlay(alignment: .top) { Rectangle().fill(colors.ink2.color).frame(height: 1) }
                .accessibilityElement(children: .combine)
            }
            .padding(.horizontal, 14)
            .mgSurface(.card, radius: MGRadius.card)
            .padding(.top, 14)
        }
    }

    /// "Bed 10:30 PM → asleep ≈ 10:44 PM → up 6:40–7:10 AM" with the bedtime in bold (UX §8.1).
    private var summary: AttributedString {
        var s = AttributedString(state.summaryLine)
        if let r = s.range(of: MGFormat.time(state.bedtime, calendar: calendar)) {
            s[r].inlinePresentationIntent = .stronglyEmphasized
        }
        return s
    }

    /// Your baseline need · − nap credit (sleep debt is listed without a sign: it is not part of the sum).
    static func sign(index: Int, minutes: Int?) -> String {
        guard index > 0, let m = minutes, m != 0 else { return "" }
        return m < 0 ? "− " : "+ "
    }

    // MARK: LatestWakePicker (APP-262: "must be up by" per weekday; blank = no wake plan that morning)

    private var latestWakePicker: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader("Must be up by", note: "per weekday")
            FlowLayout(spacing: MGSpace.s, lineSpacing: MGSpace.s) {
                ForEach(orderedWeekdays) { day in
                    Button { editing = TonightWeekdayEdit(weekday: day.weekday) } label: {
                        weekdayCell(day)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(weekdaySpoken(day))
                    .accessibilityHint("Edits the latest wake for this weekday")
                }
            }
        }
    }

    private func weekdayCell(_ day: WeekdayWake) -> some View {
        let selected = day.weekday == tomorrowWeekday
        return VStack(alignment: .leading, spacing: 0) {
            Text(TonightWeekdays.short(day.weekday) + (selected ? " · tomorrow" : ""))
                .mgFont(.label)
                .foregroundStyle(selected ? colors.buttonText.color : colors.ink2.color)
            if let t = day.time {
                Text(MGFormat.time(t)).mgFont(.button)
                    .foregroundStyle(selected ? colors.buttonText.color : colors.ink.color)
            } else {
                Text("no wake plan").mgFont(.label)
                    .foregroundStyle(selected ? colors.buttonText.color : colors.ink2.color)
            }
        }
        .padding(.horizontal, MGSpace.m)
        .frame(minHeight: MGSpace.tapTarget, alignment: .leading)
        .background {
            Capsule().fill(selected ? colors.buttonFill.color : colors.chip.color)
        }
        .contentShape(Capsule())
    }

    /// Monday first, whatever order the state lists them in.
    private var orderedWeekdays: [WeekdayWake] {
        state.latestWake.sorted { ($0.weekday + 5) % 7 < ($1.weekday + 5) % 7 }
    }

    /// The morning after tonight: the smart-wake window's end, else half a day after bedtime.
    private var tomorrowWeekday: Int {
        calendar.component(.weekday, from: state.smartWake.windowEnd ?? state.bedtime.addingTimeInterval(12 * 3600))
    }

    private func time(for weekday: Int) -> TimeOfDay? {
        state.latestWake.first { $0.weekday == weekday }?.time
    }

    private func weekdaySpoken(_ day: WeekdayWake) -> String {
        let name = TonightWeekdays.long(day.weekday) + (day.weekday == tomorrowWeekday ? ", tomorrow" : "")
        return name + ": " + (day.time.map { "up by \(MGFormat.time($0))" } ?? "blank, no wake plan")
    }

    // MARK: SmartWakeBlock (APP-006; ALG-031 live variant, ALG-035 logic; ARCHITECTURE §4.11)

    private var smartWakeBlock: some View {
        let sw = state.smartWake
        return VStack(alignment: .leading, spacing: 8) {
            SectionHeader("Smart wake", note: windowText)
            TonightToggleRow(toggle: sw.toggle, send: send)
            Text(sw.sentence)
                .mgFont(.body)
                .foregroundStyle(colors.ink2.color)
                .fixedSize(horizontal: false, vertical: true)
            if let reason = sw.noPlanReason {
                Label {
                    Text(reason).mgFont(.body).foregroundStyle(colors.ink.color)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "calendar.badge.exclamationmark").foregroundStyle(colors.ink2.color)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .mgSurface(.card, radius: MGRadius.chip)
            }
            Text("Window length").mgFont(.detail).foregroundStyle(colors.ink2.color).padding(.top, 2)
            FlowLayout(spacing: 6) {
                ForEach(windowChoices, id: \.self) { minutes in
                    Chip("\(minutes) min", selected: minutes == (windowPick ?? sw.windowMinutes)) {
                        windowPick = minutes
                        send(.setWakeWindow(minutes: minutes))
                    }
                    .disabled(!sw.toggle.enabled)
                }
            }
            .onChange(of: sw.windowMinutes) { _, _ in windowPick = nil }
            .task(id: windowPick) {
                guard windowPick != nil else { return }
                try? await Task.sleep(for: .seconds(2))
                if !Task.isCancelled { windowPick = nil }
            }
            ringsRow(sw)
        }
    }

    /// "6:40–7:10 AM" once there is a plan.
    private var windowText: String? {
        guard let a = state.smartWake.windowStart, let b = state.smartWake.windowEnd else { return nil }
        return MGFormat.timeRange(a, b, calendar: calendar)
    }

    /// 10–45 min (UX §8.1), plus whatever Settings holds if it is something else.
    private var windowChoices: [Int] {
        Array(Set([10, 15, 20, 30, 45, state.smartWake.windowMinutes])).filter { $0 > 0 }.sorted()
    }

    private func ringsRow(_ sw: SmartWakeBlockState) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("How it rings").mgFont(.detail).foregroundStyle(colors.ink2.color)
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 1) {
                    Text(sw.ringer == .alarmKit ? "iPhone alarm (AlarmKit)" : "iPhone notification with sound")
                        .mgFont(.detail)
                        .foregroundStyle(colors.ink.color)
                    Text("strap buzz: Settings › Alarms").mgFont(.receipt).foregroundStyle(colors.mute.color)
                }
            }
            .accessibilityElement(children: .combine)
            if let warning = TonightSilentWarning.text(sw, systemHasAlarmKit: TonightSilentWarning.systemHasAlarmKit) {
                Label {
                    Text(warning).mgFont(.body).foregroundStyle(colors.text(.caffeine).color)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "bell.slash").foregroundStyle(colors.text(.caffeine).color)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .mgSurface(.card, radius: MGRadius.chip)
            }
        }
        .padding(.top, 4)
    }

    // MARK: CaffeineAtBedtime (APP-044, ALG-061)

    private var caffeineAtBedtime: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader("Caffeine at bedtime")
            HStack(alignment: .top) {
                if let sentence = state.caffeineSentence {
                    Text(sentence)
                        .mgFont(.body)
                        .foregroundStyle(colors.ink2.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                ValueView(state.caffeineAtBedtime, size: .number, showsReceipt: true)
            }
        }
    }

    // MARK: NightSoundsToggle (APP-043) + WindDownToggle (APP-024)

    private var nightToggles: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader("Tonight")
            TonightToggleRow(toggle: state.nightSounds, send: send)
            TonightToggleRow(toggle: state.windDown, send: send)
            MGButton("Breathe now", style: .ghost) { send(.startBreathe) }
                .padding(.top, 8)
        }
    }
}

// MARK: - Pieces

/// A switch row bound to its `ToggleState`: it shows the state's value and, when flipped, sends the intent for the new
/// value. The state is rebuilt after a full refresh, so the switch used to snap back and then forward; it now shows the
/// flipped value at once (`pick`) until the real state arrives (then `pick` clears) or 2 s pass (Tonight 2).
struct TonightToggleRow: View {
    let toggle: ToggleState
    let send: (UIIntent) -> Void

    @Environment(\.mgColors) private var colors
    @State private var pick: Bool?

    var body: some View {
        Toggle(isOn: Binding(get: { pick ?? toggle.isOn },
                             set: { newValue in
                                 pick = newValue
                                 send(TonightToggleIntent.intent(for: toggle, newValue: newValue))
                             })) {
            VStack(alignment: .leading, spacing: 2) {
                Text(toggle.title).mgFont(.rowTitle).foregroundStyle(colors.ink.color)
                if let detail = toggle.detail {
                    Text(detail).mgFont(.detail).foregroundStyle(colors.ink2.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !toggle.enabled, let why = toggle.disabledReason {
                    Text(why).mgFont(.receipt).foregroundStyle(colors.mute.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .tint(colors.focus.color)
        .disabled(!toggle.enabled)
        .onChange(of: toggle.isOn) { _, _ in pick = nil }
        .task(id: pick) {
            guard pick != nil else { return }
            try? await Task.sleep(for: .seconds(2))
            if !Task.isCancelled { pick = nil }
        }
        .frame(minHeight: MGSpace.rowMinHeight)
        .overlay(alignment: .top) { Rectangle().fill(colors.rule.color).frame(height: 1) }
    }
}

enum TonightToggleIntent {
    /// The intent for the switch's NEW value. MGContext's ToggleState carries "the intent to send" (its previews hold
    /// the flipped value, e.g. isOn true → `.setSmartWake(false)`); the Bool intents are rebuilt with `newValue` so the
    /// switch is right whichever way a presenter fills it. Anything else goes as given.
    static func intent(for toggle: ToggleState, newValue: Bool) -> UIIntent {
        switch toggle.intent {
        case .setSmartWake: return .setSmartWake(newValue)
        case .setNightSounds: return .setNightSounds(newValue)
        case .setWindDown: return .setWindDown(newValue)
        case .setBroadcast: return .setBroadcast(newValue)
        case .setSampleData: return .setSampleData(newValue)
        case .setResearchRows: return .setResearchRows(newValue)
        case .setQuickLogSurface(let id, _): return .setQuickLogSurface(id: id, enabled: newValue)
        default: return toggle.intent
        }
    }
}

enum TonightSilentWarning {
    static let fallback = "A notification may not wake you on Silent."

    /// UX §8.1: below iOS 26 smart wake is a notification + sound, which may not wake Mo on Silent — say so plainly.
    /// The presenter's sentence wins; if it left it out while the ringer is a notification (or this iPhone has no
    /// AlarmKit), the sheet still says it.
    static func text(_ sw: SmartWakeBlockState, systemHasAlarmKit: Bool) -> String? {
        if let w = sw.silentWarning, !w.isEmpty { return w }
        if sw.ringer == .notification || !systemHasAlarmKit { return fallback }
        return nil
    }

    static var systemHasAlarmKit: Bool {
        if #available(iOS 26, *) { return true }
        return false
    }
}

/// English weekday names, independent of the phone's language (the app's copy is English, like MGFormat).
enum TonightWeekdays {
    private static let longNames = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
    private static let shortNames = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]

    /// 1 = Sunday … 7 = Saturday (Calendar convention, as `WeekdayWake`).
    static func long(_ weekday: Int) -> String { longNames[((weekday - 1) % 7 + 7) % 7] }
    static func short(_ weekday: Int) -> String { shortNames[((weekday - 1) % 7 + 7) % 7] }
}

/// The "must be up by" editor for one weekday: a 24-hour wheel, Save sends `.setLatestWake`, Clear sends nil
/// (blank = no wake plan that morning, BRIEF default 3). Nothing is written until Save or Clear.
struct TonightWakeEditor: View {
    let weekday: Int
    let current: TimeOfDay?
    let reference: Date
    let send: (UIIntent) -> Void

    @Environment(\.mgColors) private var colors
    @Environment(\.calendar) private var calendar
    @Environment(\.dismiss) private var dismiss
    @State private var draft: Date

    /// `startHint` only places the wheel when the day is blank (another weekday's time, else 07:00); it is never saved
    /// unless Mo taps Save.
    init(weekday: Int, current: TimeOfDay?, startHint: TimeOfDay?, reference: Date, calendar cal: Calendar,
         send: @escaping (UIIntent) -> Void) {
        self.weekday = weekday
        self.current = current
        self.reference = reference
        self.send = send
        let start = current ?? startHint ?? TimeOfDay(hour: 7, minute: 0)
        _draft = State(initialValue: cal.date(bySettingHour: start.hour, minute: start.minute, second: 0, of: reference)
                       ?? reference)
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text("Up by, \(TonightWeekdays.long(weekday))s")
                    .mgFont(.headline)
                    .foregroundStyle(colors.ink.color)
                DatePicker("Up by", selection: $draft, displayedComponents: .hourAndMinute)
                    .datePickerStyle(.wheel)
                    .labelsHidden()
                    .environment(\.locale, AlarmTimeLocale.picker)   // 12-hour AM/PM wheel
                    .frame(maxWidth: .infinity)
                Text("Smart wake's window ends here, and bedtime is planned back from it. Blank means no wake plan that morning.")
                    .mgFont(.detail)
                    .foregroundStyle(colors.ink2.color)
                    .fixedSize(horizontal: false, vertical: true)
                if current != nil {
                    MGButton("Clear — no wake plan", style: .ghost) {
                        send(.setLatestWake(weekday: weekday, time: nil))
                        dismiss()
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(MGSpace.gutter)
            .background(colors.sheet.color.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        send(.setLatestWake(weekday: weekday, time: TimeOfDay(of: draft, calendar: calendar)))
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationBackground(colors.sheet.color)
        .presentationCornerRadius(MGRadius.sheet)
        .presentationDragIndicator(.visible)
    }
}
