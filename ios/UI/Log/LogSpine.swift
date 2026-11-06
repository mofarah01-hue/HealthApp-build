import SwiftUI
import MGContext
import MGDesign
import MGDomain

/// Today's timeline (UX §7 DaySpine): ○ logged, ■ measured, │ vape stroke, a bar for a drink's sip time. Each entry
/// shows "happened 09:35 · logged 09:49" when the two differ (the presenter writes `timing`).
/// Tap an entry to edit its time or remove it; swipe left for Edit · Remove (UX §10).
/// Removing is soft: kept in history, hidden, with Undo for 8 s (never deleted).
struct LogSpineView: View {
    let entries: [SpineEntry]
    let canAct: Bool
    let send: (UIIntent) -> Void
    let announce: (LogToast) -> Void

    init(entries: [SpineEntry], canAct: Bool, send: @escaping (UIIntent) -> Void,
         announce: @escaping (LogToast) -> Void) {
        self.entries = entries
        self.canAct = canAct
        self.send = send
        self.announce = announce
    }
    /// Which entry's editor sheet is open (presentation only; the data changes through intents).
    @State private var editing: SpineEntry?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if entries.isEmpty {
                LogHint("Nothing logged yet today.")
                    .padding(.vertical, 12)
            }
            ForEach(entries) { entry in
                LogSwipeRow(canAct: canAct, onEdit: { open(entry) }, onRemove: { remove(entry) }) {
                    LogSpineRow(entry: entry)
                }
            }
        }
        .sheet(item: $editing) { entry in
            LogEntryEditor(entry: entry, send: send, announce: announce)
        }
    }

    private func open(_ entry: SpineEntry) {
        guard canAct else { return }
        send(.editEntry(id: entry.id))
        editing = entry
    }

    private func remove(_ entry: SpineEntry) {
        guard canAct else { return }
        send(.removeEntry(id: entry.id))
        announce(LogToast(message: "Removed \(entry.title)", undo: [.undoRemove(id: entry.id)]))
    }
}

/// One line of the spine.
struct LogSpineRow: View {
    let entry: SpineEntry

    init(entry: SpineEntry) {
        self.entry = entry
    }
    @Environment(\.mgColors) private var colors
    @Environment(\.calendar) private var calendar

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(LogText.time(entry.at, calendar))
                .mgFont(MGTextStyle(family: .mono, size: 12, lineHeight: 15, weight: .regular,
                                    relativeTo: .caption, maxScale: 2))
                .foregroundStyle(colors.ink2.color)
                .frame(width: 64, alignment: .leading)
                .padding(.top, 2)
            LogSpineMark(entry: entry)
                .frame(width: 18, alignment: .center)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title)
                    .mgFont(.body)
                    .foregroundStyle(colors.ink.color)
                    .fixedSize(horizontal: false, vertical: true)
                if entry.mark == .drinkBar, let end = entry.end {
                    LogHint("\(LogText.time(entry.at, calendar))–\(LogText.time(end, calendar))")
                }
                if let timing = entry.timing {
                    LogHint(timing)
                }
                if entry.unconfirmed {
                    Text("detected · not confirmed")
                        .mgFont(.tag)
                        .foregroundStyle(colors.ink2.color)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .overlay {
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .strokeBorder(colors.ink2.color, style: StrokeStyle(lineWidth: 1, dash: [1.5, 1.5]))
                        }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 8)
        .frame(minHeight: MGSpace.tapTarget, alignment: .top)
        .background(alignment: .leading) {
            Rectangle()
                .fill(colors.rule.color)
                .frame(width: 2)
                .padding(.leading, 80)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
    }

    private var spoken: String {
        var parts = [LogText.time(entry.at, calendar)]
        if entry.mark == .drinkBar, let end = entry.end { parts[0] += " to \(LogText.time(end, calendar))" }
        parts.append(entry.title)
        if let timing = entry.timing { parts.append(timing) }
        if entry.unconfirmed { parts.append("detected, not confirmed") }
        return parts.joined(separator: ", ")
    }
}

/// The glyph: shape carries the meaning, colour only adds to it.
struct LogSpineMark: View {
    let entry: SpineEntry

    init(entry: SpineEntry) {
        self.entry = entry
    }
    @Environment(\.mgColors) private var colors

    var body: some View {
        switch entry.mark {
        case .logged:
            Circle()
                .strokeBorder(colors.ink.color, lineWidth: 1.5)
                .frame(width: 10, height: 10)
                .padding(.top, 3)
        case .measured:
            Rectangle()
                .fill(colors.ink.color)
                .frame(width: 9, height: 9)
                .padding(.top, 3)
        case .vapeStroke:
            if entry.unconfirmed {
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .strokeBorder(colors.mark(.body).color, style: StrokeStyle(lineWidth: 1.5, dash: [2, 2]))
                    .frame(width: 4, height: 16)
            } else {
                Capsule().fill(colors.mark(.body).color).frame(width: 3, height: 16)
            }
        case .drinkBar:
            Capsule().fill(colors.mark(.caffeine).color).frame(width: 6, height: 24)
        }
    }
}

/// Swipe left to reveal Edit · Remove (UX §10). A custom gesture because the spine sits inside the screen's scroll view,
/// not a List. Only a mostly horizontal drag moves it, so vertical scrolling is untouched. VoiceOver gets the same two
/// actions as accessibility actions, and a tap opens the editor.
struct LogSwipeRow<Content: View>: View {
    let canAct: Bool
    let onEdit: () -> Void
    let onRemove: () -> Void
    let content: Content

    init(canAct: Bool, onEdit: @escaping () -> Void, onRemove: @escaping () -> Void,
         @ViewBuilder content: () -> Content) {
        self.canAct = canAct
        self.onEdit = onEdit
        self.onRemove = onRemove
        self.content = content()
    }
    @Environment(\.mgColors) private var colors
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var offset: CGFloat = 0
    @State private var isOpen = false

    private let revealWidth: CGFloat = 156

    var body: some View {
        ZStack(alignment: .trailing) {
            HStack(spacing: 0) {
                actionButton("Edit", destructive: false) { onEdit() }
                actionButton("Remove", destructive: true) { onRemove() }
            }
            .frame(width: revealWidth)
            .opacity(offset < -4 ? 1 : 0)
            .accessibilityHidden(true)

            content
                .offset(x: offset)
                .contentShape(Rectangle())
                .onTapGesture {
                    guard canAct else { return }
                    if isOpen { settle(open: false) } else { onEdit() }
                }
                .simultaneousGesture(drag)
        }
        .clipped()
        .accessibilityAddTraits(canAct ? .isButton : [])
        .accessibilityHint(canAct ? "Opens this entry to change its time or remove it" : "")
        .accessibilityAction(named: "Edit") { if canAct { onEdit() } }
        .accessibilityAction(named: "Remove") { if canAct { onRemove() } }
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 16)
            .onChanged { value in
                guard canAct, abs(value.translation.width) > abs(value.translation.height) else { return }
                let start: CGFloat = isOpen ? -revealWidth : 0
                offset = min(0, max(-revealWidth - 24, start + value.translation.width))
            }
            .onEnded { _ in
                guard canAct else { return }
                settle(open: offset < -revealWidth / 2)
            }
    }

    private func settle(open: Bool) {
        isOpen = open
        let target: CGFloat = open ? -revealWidth : 0
        if reduceMotion {
            offset = target
        } else {
            withAnimation(.easeOut(duration: 0.2)) { offset = target }
        }
    }

    private func actionButton(_ title: String, destructive: Bool, action: @escaping () -> Void) -> some View {
        Button {
            settle(open: false)
            action()
        } label: {
            Text(title)
                .mgFont(.button)
                .foregroundStyle(destructive ? colors.buttonText.color : colors.ink.color)
                .frame(maxWidth: .infinity, minHeight: MGSpace.tapTarget)
                .background(destructive ? colors.body.color : colors.chip.color)
        }
        .buttonStyle(.plain)
    }
}

/// Edit one spine entry: move its "happened at" (chips and wheel, APP-082) or remove it (soft, Undo for 8 s).
/// First build: time + remove only; changing what was logged (dose, tags) comes later (approved clarification c).
struct LogEntryEditor: View {
    let entry: SpineEntry
    let send: (UIIntent) -> Void
    let announce: (LogToast) -> Void

    init(entry: SpineEntry, send: @escaping (UIIntent) -> Void, announce: @escaping (LogToast) -> Void) {
        self.entry = entry
        self.send = send
        self.announce = announce
    }
    @Environment(\.dismiss) private var dismiss
    @Environment(\.mgColors) private var colors
    @Environment(\.calendar) private var calendar
    @State private var minutesEarlier = 0
    @State private var clock: Date?
    @State private var wheelOpen = false

    private let offsets = [0, 5, 15, 30, 60]

    private var newAt: Date {
        if let clock { return LogTime.moving(entry.at, toClockOf: clock, calendar: calendar) }
        return entry.at.addingTimeInterval(-Double(minutesEarlier) * 60)
    }
    private var delta: Int { LogTime.minutes(from: entry.at, to: newAt) }

    var body: some View {
        // r8h G6: a ScrollView so Save is reachable at the medium detent with large text.
        ScrollView {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.title)
                    .mgFont(.headline)
                    .foregroundStyle(colors.ink.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                LogHint(entry.timing ?? "happened \(LogText.time(entry.at, calendar))")
            }

            LogFormLabel("Move it earlier · minutes")
            FlowLayout(spacing: 8, lineSpacing: 8) {
                ForEach(offsets, id: \.self) { minutes in
                    Chip(minutes == 0 ? "as is" : "−\(minutes)", selected: clock == nil && minutesEarlier == minutes) {
                        clock = nil
                        minutesEarlier = minutes
                        wheelOpen = false
                    }
                }
                Chip("time…", selected: clock != nil || wheelOpen) {
                    wheelOpen.toggle()
                    if wheelOpen, clock == nil { clock = entry.at }
                }
            }
            if wheelOpen {
                DatePicker("Time it happened", selection: Binding(get: { clock ?? entry.at }, set: { clock = $0 }),
                           displayedComponents: .hourAndMinute)
                    .datePickerStyle(.wheel)
                    .labelsHidden()
                    .environment(\.locale, AlarmTimeLocale.picker)
                    .frame(maxWidth: .infinity, maxHeight: 120)
            }
            LogHint(delta == 0 ? "stays at \(LogText.time(entry.at, calendar))"
                               : "moves to \(LogText.time(newAt, calendar)) · \(abs(delta)) min \(delta < 0 ? "earlier" : "later")")

            VStack(spacing: 10) {      // r8h G6: stacked, never three buttons squeezed into one row
                MGButton("Save time", style: .filled, action: saveTime)
                    .disabled(delta == 0)
                    .opacity(delta == 0 ? 0.4 : 1)
                MGButton("Cancel", style: .ghost) { dismiss() }
                MGButton("Remove", style: .ghost, action: remove)
            }
            LogHint("Remove hides this entry. It is kept in your history, never deleted, and Undo stays for 8 seconds.")
        }
        .padding(MGSpace.gutter)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .presentationDetents([.medium, .large])
        .presentationBackground(colors.sheet.color)
    }

    private func saveTime() {
        let minutes = delta
        guard minutes != 0 else { return }
        let message = "Time changed to \(LogText.time(newAt, calendar))"
        send(LogIntents.shift(id: entry.id, minutes: minutes))
        announce(LogToast(message: message, undo: [LogIntents.shift(id: entry.id, minutes: -minutes)]))
        dismiss()
    }

    private func remove() {
        send(.removeEntry(id: entry.id))
        announce(LogToast(message: "Removed \(entry.title)", undo: [.undoRemove(id: entry.id)]))
        dismiss()
    }
}
