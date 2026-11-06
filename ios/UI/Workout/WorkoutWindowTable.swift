import SwiftUI
import MGContext
import MGDesign
import MGDomain

// Per-window table (APP-051 "per-segment values"; ALG-047 per-window HR, zones, TRIMP; UX §14 "per-window table").
// Owner: WP-29. Collapsed: one line per window — name and time, avg · peak · TRIMP. A row opens in place
// (`.toggleRow(id:)`, state-driven) to show the full values with receipts and blanks with their reasons, the minutes
// in each zone, and the edits: window kind, split at a time, merge with the next (APP-051 trim / split / merge),
// each sent as `.editWorkout(id:edit:)`.

struct WorkoutWindowTable: View {
    let workoutId: UUID
    let windows: [WorkoutDetailWindow]
    let editable: Bool
    let editDisabledReason: String?
    let send: (UIIntent) -> Void
    @Environment(\.mgColors) private var colors
    @Environment(\.dynamicTypeSize) private var typeSize

    /// Columns up to the largest standard text size; stacked lines at accessibility sizes (decided once for the
    /// whole table, so the column heads always match the rows).
    private var wide: Bool { !typeSize.isAccessibilitySize }

    var body: some View {
        MGCard(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                if windows.isEmpty {
                    Text("No windows yet. The workout is one window until you split it.")
                        .mgFont(.detail)
                        .foregroundStyle(colors.ink2.color)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(MGSpace.cardInset)
                } else {
                    if wide { WorkoutWindowColumns() }
                    ForEach(Array(windows.enumerated()), id: \.element.id) { index, window in
                        WorkoutWindowLine(workoutId: workoutId, window: window, wide: wide, editable: editable,
                                          editDisabledReason: editDisabledReason, send: send)
                        if index < windows.count - 1 {
                            Rectangle().fill(colors.rule.color).frame(height: 1).padding(.horizontal, 16)
                                .accessibilityHidden(true)
                        }
                    }
                }
            }
        }
    }
}

/// Column heads (wide layout only).
private struct WorkoutWindowColumns: View {
    @Environment(\.mgColors) private var colors

    var body: some View {
        HStack(spacing: 0) {
            Text("Window").frame(maxWidth: .infinity, alignment: .leading)
            Text("Avg").frame(width: WorkoutWindowLine.numberWidth, alignment: .trailing)
            Text("Peak").frame(width: WorkoutWindowLine.numberWidth, alignment: .trailing)
            Text("TRIMP").frame(width: WorkoutWindowLine.numberWidth, alignment: .trailing)
            Color.clear.frame(width: 22)
        }
        .mgFont(.receipt)
        .foregroundStyle(colors.mute.color)
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 2)
        .accessibilityHidden(true)
    }
}

struct WorkoutWindowLine: View {
    let workoutId: UUID
    let window: WorkoutDetailWindow
    /// Columns (true) or stacked lines (accessibility text sizes).
    let wide: Bool
    let editable: Bool
    let editDisabledReason: String?
    let send: (UIIntent) -> Void
    @Environment(\.mgColors) private var colors
    @Environment(\.calendar) private var calendar
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let numberWidth: CGFloat = 54

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(MGMotion.expand(reduceMotion: reduceMotion)) { send(.toggleRow(id: window.id)) }
            } label: {
                Group {
                    if wide { columns } else { stacked }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .frame(minHeight: MGSpace.rowMinHeight, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(spoken)
            .accessibilityValue(window.isOpen ? "open" : "closed")
            .accessibilityHint(window.isOpen ? "Closes this window" : "Opens this window's values and edits")

            if window.isOpen {
                WorkoutWindowDetail(workoutId: workoutId, window: window, editable: editable,
                                    editDisabledReason: editDisabledReason, send: send)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 14)
                    .transition(.opacity)
            }
        }
    }

    private var columns: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            nameBlock.frame(maxWidth: .infinity, alignment: .leading)
            WorkoutCell(value: window.avgHR).frame(width: Self.numberWidth, alignment: .trailing)
            WorkoutCell(value: window.peakHR).frame(width: Self.numberWidth, alignment: .trailing)
            WorkoutCell(value: window.trimp).frame(width: Self.numberWidth, alignment: .trailing)
            chevron.frame(width: 22, alignment: .trailing)
        }
    }

    private var stacked: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                nameBlock
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("avg").mgFont(.receipt).foregroundStyle(colors.mute.color)
                    WorkoutCell(value: window.avgHR)
                    Text("peak").mgFont(.receipt).foregroundStyle(colors.mute.color)
                    WorkoutCell(value: window.peakHR)
                }
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("TRIMP").mgFont(.receipt).foregroundStyle(colors.mute.color)
                    WorkoutCell(value: window.trimp)
                }
            }
            Spacer(minLength: 0)
            chevron
        }
    }

    private var nameBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(window.label)
                .mgFont(.rowTitle)
                .foregroundStyle(colors.ink.color)
                .fixedSize(horizontal: false, vertical: true)
            Text("\(MGFormat.timeRange(window.start, window.end, calendar: calendar)) · \(MGFormat.duration(window.end.timeIntervalSince(window.start)))")
                .mgFont(.receipt)
                .foregroundStyle(colors.mute.color)
        }
    }

    private var chevron: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(colors.mute.color)
            .rotationEffect(.degrees(window.isOpen ? 90 : 0))
            .accessibilityHidden(true)
    }

    private var spoken: String {
        "\(window.label), \(MGFormat.timeRange(window.start, window.end, calendar: calendar)). "
            + "Average \(WorkoutCell.spoken(window.avgHR)), peak \(WorkoutCell.spoken(window.peakHR)), "
            + "TRIMP \(WorkoutCell.spoken(window.trimp))."
    }
}

/// A compact table cell: the value text and its unit, or "—" when blank (the reason shows when the row opens).
struct WorkoutCell: View {
    let value: DisplayValue
    @Environment(\.mgColors) private var colors

    var body: some View {
        switch value {
        case let .value(text, _, _, style, _):
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(text)
                    .mgFont(.wordValue)
                    .foregroundStyle(colors.ink.color)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                if case .estimate(let u) = style {
                    Text(EstimateMark.text(u, valueText: text)).mgFont(.unit).foregroundStyle(colors.ink2.color)
                }
            }
        case .blank:
            Text("—")
                .mgFont(.wordValue)
                .foregroundStyle(colors.mute.color)
        }
    }

    static func spoken(_ value: DisplayValue) -> String {
        switch value {
        case let .value(text, unit, _, _, _): return [text, unit].compactMap { $0 }.joined(separator: " ")
        case let .blank(reason, _): return "blank, \(reason)"
        }
    }
}

/// The opened window: full values, zone minutes, then the edits.
private struct WorkoutWindowDetail: View {
    let workoutId: UUID
    let window: WorkoutDetailWindow
    let editable: Bool
    let editDisabledReason: String?
    let send: (UIIntent) -> Void
    @Environment(\.mgColors) private var colors
    /// The split time Mo is picking (form input); nil = the window's middle.
    @State private var splitAt: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let detail = window.detail {
                Text(detail)
                    .mgFont(.detail)
                    .foregroundStyle(colors.ink2.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            FlowLayout(spacing: 16, lineSpacing: 10) {
                labelled("Avg HR", window.avgHR)
                labelled("Peak", window.peakHR)
                labelled("TRIMP", window.trimp)
            }
            if let zones = window.zoneMinutes {
                Text(WorkoutZoneText.legend(zones))
                    .mgFont(.receipt)
                    .foregroundStyle(colors.mute.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            edits
        }
    }

    private func labelled(_ title: String, _ value: DisplayValue) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).mgFont(.kicker).foregroundStyle(colors.ink2.color)
            ValueView(value, size: .small, showsReceipt: true)
        }
        .frame(maxWidth: 150, alignment: .leading)
    }

    @ViewBuilder private var edits: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Kind")
                .mgFont(.kicker)
                .foregroundStyle(colors.ink2.color)
            FlowLayout(spacing: 8, lineSpacing: 8) {
                ForEach(WorkoutFields.Window.Kind.allCases, id: \.self) { kind in
                    Chip(WorkoutDetailWindow.title(for: kind), selected: window.kind == kind) {
                        send(.editWorkout(id: workoutId, edit: .setWindowKind(windowId: window.id, kind: kind)))
                    }
                }
            }
            if let range = splitRange {
                HStack(alignment: .center, spacing: 10) {
                    DatePicker("Split at", selection: splitBinding(range), in: range,
                               displayedComponents: .hourAndMinute)
                        .environment(\.locale, AlarmTimeLocale.picker)   // 12-hour AM/PM
                        .mgFont(.detail)
                        .foregroundStyle(colors.ink.color)
                    MGButton("Split", style: .ghost) {
                        let at = splitAt ?? middle(range)
                        send(.editWorkout(id: workoutId, edit: .splitWindow(windowId: window.id, at: at)))
                        splitAt = nil
                    }
                }
            } else {
                Text("Too short to split (under 2 min).")
                    .mgFont(.receipt)
                    .foregroundStyle(colors.mute.color)
            }
            if window.canMergeWithNext {
                MGButton("Merge with the next window", style: .ghost) {
                    send(.editWorkout(id: workoutId, edit: .mergeWithNext(windowId: window.id)))
                }
            }
        }
        .disabled(!editable)
        .opacity(editable ? 1 : 0.5)
        if !editable {
            Text(editDisabledReason ?? "Edits are off (no reason given).")
                .mgFont(.receipt)
                .foregroundStyle(colors.ink2.color)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// A split must leave at least a minute on each side.
    private var splitRange: ClosedRange<Date>? {
        let lo = window.start.addingTimeInterval(60)
        let hi = window.end.addingTimeInterval(-60)
        return lo <= hi ? lo...hi : nil
    }

    private func middle(_ r: ClosedRange<Date>) -> Date {
        r.lowerBound.addingTimeInterval(r.upperBound.timeIntervalSince(r.lowerBound) / 2)
    }

    private func splitBinding(_ range: ClosedRange<Date>) -> Binding<Date> {
        Binding(get: { splitAt ?? middle(range) },
                set: { splitAt = min(max($0, range.lowerBound), range.upperBound) })
    }
}

/// "Z1 4 min · Z2 2 · Z3 0 · Z4 0 · Z5 0" (same wording as Live's zone bar legend).
enum WorkoutZoneText {
    static func legend(_ minutes: [Double]) -> String {
        let five = (0..<5).map { i in i < minutes.count && minutes[i].isFinite ? max(0, minutes[i]) : 0 }
        if five.allSatisfy({ $0 == 0 }) { return "No time in a zone." }
        return five.enumerated().map { i, m in
            let n = Int(m.rounded())
            return i == 0 ? "Z1 \(n) min" : "Z\(i + 1) \(n)"
        }.joined(separator: " · ")
    }
}
