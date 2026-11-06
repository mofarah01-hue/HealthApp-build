import SwiftUI
import MGContext
import MGDesign
import MGDomain

/// Workout — the pushed detail screen (UX-SPEC §14 "Workout (push)"; Today's "Open workout" and the dial's workout
/// arc, UX §10; Mo asked for "workouts with time windows and an HR map"). Owner: WP-29.
///
/// Scroll order: kicker + title · What / Where chips Mo sets (APP-058; the detector's guess kept beside, ALG-041) ·
/// summary (time, avg / peak HR, HR recovery 1 min — APP-231) · HR map with zone bands across the windows + time in
/// zones (APP-051, ALG-106) · per-window table that opens in place to edit kind / split / merge (ALG-047) · edit the
/// workout's times · breathing where two estimators agree (APP-031) · training load G-LOAD (APP-284) · calories G-CAL
/// (APP-057) · note.
/// Pure rendering of `WorkoutDetailState`; every tap is a `UIIntent` through `send`: edits → `.editWorkout(id:edit:)`,
/// row expansion → `.toggleRow(id:)`, methods → MethodsStrip's own intents. Draws no back button: WP-23 pushes it
/// inside a NavigationStack on `.openWorkout(id:)` and applies `.mgTheme(...)` above (or passes `theme`).
struct WorkoutDetailView: View {
    let state: WorkoutDetailState
    let theme: ThemeName?
    let send: (UIIntent) -> Void

    init(state: WorkoutDetailState, theme: ThemeName? = nil, send: @escaping (UIIntent) -> Void) {
        self.state = state
        self.theme = theme
        self.send = send
    }

    var body: some View {
        Group {
            if let theme {
                WorkoutDetailContent(state: state, send: send).mgTheme(theme)
            } else {
                WorkoutDetailContent(state: state, send: send)
            }
        }
    }
}

private struct WorkoutDetailContent: View {
    let state: WorkoutDetailState
    let send: (UIIntent) -> Void
    @Environment(\.mgColors) private var colors
    @Environment(\.calendar) private var calendar

    var body: some View {
        MGScreen {
            VStack(alignment: .leading, spacing: 0) {
                header
                    .padding(.top, 12)

                WorkoutChoiceChips(row: state.typeRow, editable: state.editable) { value in
                    send(.editWorkout(id: state.id, edit: .setType(value)))
                }
                .padding(.top, 14)
                WorkoutChoiceChips(row: state.placeRow, editable: state.editable) { value in
                    send(.editWorkout(id: state.id, edit: .setPlace(value)))
                }
                .padding(.top, 10)
                WorkoutChoiceChips(row: state.wearRow, editable: state.editable) { value in
                    send(.editWorkout(id: state.id, edit: .setWearLocation(value.flatMap { WearLocation(rawValue: $0) })))
                }
                .padding(.top, 10)
                ForEach(Array(state.wearLines.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .mgFont(.receipt)
                        .foregroundStyle(colors.mute.color)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 4)
                }
                if let auto = state.autoTypeNote {
                    Text(auto)
                        .mgFont(.receipt)
                        .foregroundStyle(colors.mute.color)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 8)
                }
                if !state.editable, let why = state.editDisabledReason {
                    Text(why)
                        .mgFont(.detail)
                        .foregroundStyle(colors.ink2.color)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 8)
                }

                WorkoutSummaryGrid(items: state.summary)
                    .padding(.top, 16)

                SectionHeader("Heart rate map", note: state.isLive ? "so far" : "zones shaded")
                WorkoutHRMapChart(map: state.hrMap, windows: state.windows, end: state.end)
                LiveZoneBar(minutes: state.hrMap.zoneMinutes, basis: state.hrMap.zoneBasis)
                    .padding(.top, 12)

                SectionHeader("Windows", note: "tap one to edit · split · merge")
                WorkoutWindowTable(workoutId: state.id, windows: state.windows, editable: state.editable,
                                   editDisabledReason: state.editDisabledReason, send: send)
                windowFootnotes
                    .padding(.top, 8)

                if !state.isLive {
                    WorkoutTimesEditor(state: state, send: send)
                        .padding(.top, 8)
                }

                breathing
                    .padding(.top, 8)

                if let load = state.load {
                    SectionHeader("Training load")
                    MethodsStrip(state: load, send: send)
                }
                if let effort = state.effort {
                    SectionHeader("Effort and fluid")
                    WorkoutEffortCard(workoutId: state.id, effort: effort, editable: state.editable, send: send)
                }
                if let calories = state.calories {
                    SectionHeader("Calories burned")
                    MethodsStrip(state: calories, send: send)
                }

                SectionHeader("Note")
                WorkoutNoteEditor(workoutId: state.id, note: state.note, editable: state.editable, send: send)
            }
            .padding(.bottom, 40)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if state.sample { SampleBanner() }
        }
        .environment(\.mgSend, send)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            // In the Emerald glow: `topText` (WP-07 contrast rule).
            Text(state.kicker)
                .mgFont(.kicker)
                .foregroundStyle(colors.topText.color)
            Text(state.title)
                .mgFont(.title)
                .foregroundStyle(colors.ink.color)
                .accessibilityAddTraits(.isHeader)
        }
    }

    @ViewBuilder private var windowFootnotes: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let hint = state.doubleTapHint {
                HStack(alignment: .center, spacing: 10) {
                    LetterBadge("2×", accent: .ink2)
                    Text(hint)
                        .mgFont(.detail)
                        .foregroundStyle(colors.ink2.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
            }
            if let note = state.windowNote {
                Text(note)
                    .mgFont(.receipt)
                    .foregroundStyle(colors.mute.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Breathing per minute only where two estimators agree (APP-031); otherwise blank with the reason.
    private var breathing: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Breathing")
                    .mgFont(.rowTitle)
                    .foregroundStyle(colors.ink.color)
                Text("1-min values, only where two estimators agree")
                    .mgFont(.receipt)
                    .foregroundStyle(colors.mute.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            ValueView(state.breathing, size: .number, showsReceipt: true)
                .frame(maxWidth: 180, alignment: .trailing)
        }
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) {
            Rectangle().fill(colors.rule.color).frame(height: 1).accessibilityHidden(true)
        }
        .accessibilityElement(children: .contain)
    }
}

// MARK: - What / Where chips (APP-058)

/// Option chips plus Mo's own words. Tapping the chosen chip clears it (nil); "Other…" takes free text.
struct WorkoutChoiceChips: View {
    let row: WorkoutChoiceRow
    let editable: Bool
    let choose: (String?) -> Void
    @Environment(\.mgColors) private var colors
    /// Mo's own words being typed (form input).
    @State private var other = ""
    @FocusState private var typing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(row.title)
                .mgFont(.kicker)
                .foregroundStyle(colors.ink2.color)
            FlowLayout(spacing: 8, lineSpacing: 8) {
                ForEach(row.options) { option in
                    let on = row.selected == option.id
                    Chip(option.label, selected: on) { choose(on ? nil : option.id) }
                        .accessibilityHint(on ? "Clears your choice" : "Sets \(row.title.lowercased()) to \(option.label)")
                }
                if let own = row.otherValue {
                    Chip(own, selected: true) { choose(nil) }
                        .accessibilityHint("Clears your choice")
                }
                if row.allowsOther {
                    TextField("Other…", text: $other)
                        .mgFont(.detail)
                        .foregroundStyle(colors.ink.color)
                        .textInputAutocapitalization(.never)
                        .submitLabel(.done)
                        .focused($typing)
                        .onSubmit(submitOther)
                        .padding(.horizontal, 12)
                        .frame(width: 140, height: MGSpace.tapTarget)
                        .background {
                            RoundedRectangle(cornerRadius: MGRadius.chip, style: .continuous)
                                .strokeBorder(colors.rule.color, lineWidth: 1)
                        }
                        .accessibilityLabel("Other \(row.title.lowercased()), your own words")
                }
            }
        }
        .disabled(!editable)
        .opacity(editable ? 1 : 0.5)
    }

    private func submitOther() {
        let text = other.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        choose(text)
        other = ""
        typing = false
    }
}

// MARK: - Summary (APP-231)

/// Time · Avg HR · Peak · HR recovery — four across when they fit, two per line otherwise.
struct WorkoutSummaryGrid: View {
    let items: [LabeledValue]
    @Environment(\.mgColors) private var colors

    private let columns = [GridItem(.adaptive(minimum: 76), spacing: 10, alignment: .topLeading)]

    var body: some View {
        if !items.isEmpty {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                ForEach(items) { item in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.label)
                            .mgFont(.kicker)
                            .foregroundStyle(colors.ink2.color)
                        ValueView(item.value, size: .number)
                        if let caption = item.caption {
                            Text(caption)
                                .mgFont(.receipt)
                                .foregroundStyle(colors.mute.color)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }
}

// MARK: - Edit times (APP-051 trim)

/// "Edit times" opens in place (`.toggleRow(id: WorkoutDetailState.timesRowId)`); Save sends `.setTimes`.
struct WorkoutTimesEditor: View {
    let state: WorkoutDetailState
    let send: (UIIntent) -> Void
    @Environment(\.mgColors) private var colors
    @Environment(\.calendar) private var calendar
    /// Times being picked (form input); nil = unchanged.
    @State private var start: Date?
    @State private var end: Date?

    var body: some View {
        ExpandableRow(title: "Edit times", detail: detail, receipt: nil,
                      isOpen: Binding(get: { state.timesOpen },
                                      set: { _ in send(.toggleRow(id: WorkoutDetailState.timesRowId)) })) {
            VStack(alignment: .leading, spacing: 10) {
                DatePicker("Started", selection: binding($start, fallback: state.start),
                           displayedComponents: [.date, .hourAndMinute])
                DatePicker("Ended", selection: binding($end, fallback: state.end ?? state.start),
                           displayedComponents: [.date, .hourAndMinute])
                if !valid {
                    Text("The end must come after the start.")
                        .mgFont(.receipt)
                        .foregroundStyle(colors.text(.body).color)
                }
                Text("Your times become the detector's label (ALG-041). The windows are trimmed to fit.")
                    .mgFont(.receipt)
                    .foregroundStyle(colors.mute.color)
                    .fixedSize(horizontal: false, vertical: true)
                MGButton("Save times", style: .filled) {
                    send(.editWorkout(id: state.id, edit: .setTimes(start: chosenStart, end: chosenEnd)))
                    start = nil
                    end = nil
                }
                .disabled(!valid || !changed || !state.editable)
                .opacity(valid && changed && state.editable ? 1 : 0.5)
                if !state.editable, let why = state.editDisabledReason {
                    Text(why)
                        .mgFont(.receipt)
                        .foregroundStyle(colors.ink2.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .mgFont(.detail)
            .foregroundStyle(colors.ink.color)
            .environment(\.locale, AlarmTimeLocale.picker)   // 12-hour AM/PM
        }
    }

    private var detail: String {
        guard let e = state.end else { return "still running" }
        return MGFormat.timeRange(state.start, e, calendar: calendar) + " · trim the start or the end"
    }

    private var chosenStart: Date { start ?? state.start }
    private var chosenEnd: Date { end ?? state.end ?? state.start }
    private var valid: Bool { chosenEnd > chosenStart }
    private var changed: Bool { chosenStart != state.start || chosenEnd != state.end }

    private func binding(_ draft: Binding<Date?>, fallback: Date) -> Binding<Date> {
        Binding(get: { draft.wrappedValue ?? fallback }, set: { draft.wrappedValue = $0 })
    }
}

// MARK: - Note

/// Mo's note on the workout (eventBase `note`). Typing is local; Save sends `.setNote` (empty clears it).
struct WorkoutNoteEditor: View {
    let workoutId: UUID
    let note: String?
    let editable: Bool
    let send: (UIIntent) -> Void
    @Environment(\.mgColors) private var colors
    /// The text being typed; nil = showing the saved note.
    @State private var draft: String?
    @FocusState private var typing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("What you did, how it felt…", text: textBinding, axis: .vertical)
                .lineLimit(2...6)
                .mgFont(.body)
                .foregroundStyle(colors.ink.color)
                .focused($typing)
                .padding(12)
                .background {
                    RoundedRectangle(cornerRadius: MGRadius.chip, style: .continuous)
                        .strokeBorder(colors.rule.color, lineWidth: 1)
                }
            if dirty {
                HStack(spacing: 10) {
                    MGButton("Save note", style: .filled) {
                        let text = (draft ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                        send(.editWorkout(id: workoutId, edit: .setNote(text.isEmpty ? nil : text)))
                        draft = nil
                        typing = false
                    }
                    MGButton("Cancel", style: .ghost) {
                        draft = nil
                        typing = false
                    }
                }
            }
        }
        .disabled(!editable)
        .opacity(editable ? 1 : 0.5)
    }

    private var textBinding: Binding<String> {
        Binding(get: { draft ?? note ?? "" }, set: { draft = $0 })
    }

    private var dirty: Bool {
        guard let draft else { return false }
        return draft != (note ?? "")
    }
}
