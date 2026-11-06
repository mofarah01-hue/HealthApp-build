import SwiftUI
import MGContext
import MGDesign
import MGDomain

/// The month (UX §7 MonthGrid, APP-078): collapsed by default; one row per item, one mark per day.
/// Open or closed is state-driven (`MonthGridState.isCollapsed`, `.openMonthGrid`), never local.
/// r8h G4: marks are rounded squares: filled = done, outlined = scheduled and missed, pale = nothing expected, dark outline = today.
/// The grid opens scrolled to today.
/// R9f (G4): a tap on a day's cell opens that day: every item's status for it (from the grid, no extra read).
struct LogMonthGridView: View {
    let grid: MonthGridState?
    let send: (UIIntent) -> Void

    init(grid: MonthGridState?, send: @escaping (UIIntent) -> Void) {
        self.grid = grid
        self.send = send
    }
    @Environment(\.mgColors) private var colors
    @Environment(\.mgNow) private var envNow
    @Environment(\.calendar) private var calendar
    @State private var picked: LogPickedDay?

    private var isOpen: Bool {
        guard let grid else { return false }
        return !grid.isCollapsed
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { send(.openMonthGrid) } label: {
                HStack(alignment: .firstTextBaseline) {
                    Text(grid?.title ?? "This month")
                        .mgFont(.headline)
                        .foregroundStyle(colors.ink.color)
                    Spacer(minLength: 8)
                    Text(isOpen ? "close" : "intake calendar ›")
                        .mgFont(.detail)
                        .foregroundStyle(colors.ink2.color)
                }
                .padding(.top, MGSpace.section - 2)
                .frame(minHeight: MGSpace.tapTarget)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            .accessibilityValue(isOpen ? "open" : "closed")
            .accessibilityHint(isOpen ? "Closes the month" : "Opens the month: one row per item")

            if let grid, !grid.isCollapsed {
                if grid.rows.isEmpty {
                    LogHint("Nothing to show for this month yet.")
                } else {
                    ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        VStack(alignment: .leading, spacing: MGSpace.m) {
                            LogDayAxis(days: grid.days)
                            ForEach(grid.rows) { row in
                                HStack(spacing: MGSpace.s) {
                                    Text(row.title)
                                        .mgFont(.label)
                                        .foregroundStyle(colors.ink.color)
                                        .lineLimit(1)
                                        .frame(width: 88, alignment: .leading)
                                    LogMarkStrip(days: grid.days, marks: row.marks,
                                                 tone: LogItemStyle.tone(row.item), today: today,
                                                 onPick: { picked = LogPickedDay(day: $0) })
                                        .accessibilityElement(children: .ignore)
                                        .accessibilityLabel(LogMonthGridView.summary(row))
                                }
                            }
                            LogHint("filled square logged · outlined square scheduled, missed · pale none · dark outline today")
                        }
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(MGSpace.cardInset)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onAppear {
                        // Mid-month, today is off screen to the right: bring it to the middle.
                        DispatchQueue.main.async { proxy.scrollTo(today, anchor: .center) }
                    }
                    }
                    .mgSurface(.tile, radius: MGRadius.tile)
                }
            }
        }
        .sheet(item: $picked) { pick in
            if let grid {
                LogMonthDaySheet(day: pick.day, grid: grid, today: today)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
        }
    }

    private var today: LocalDay {
        LocalDay(date: envNow ?? Date(), calendar: calendar)
    }

    /// "MedA 20 mg: 9 of 10 scheduled days done."
    static func summary(_ row: MonthGridRow) -> String {
        let done = row.marks.filter { $0 == true }.count
        let missed = row.marks.filter { $0 == false }.count
        if done + missed == 0 { return "\(row.title): nothing scheduled yet." }
        return "\(row.title): \(done) of \(done + missed) scheduled days done."
    }
}

/// Day numbers above the 12 pt cells.
struct LogDayAxis: View {
    let days: [LocalDay]

    init(days: [LocalDay]) {
        self.days = days
    }
    @Environment(\.mgColors) private var colors

    var body: some View {
        HStack(spacing: MGSpace.s) {
            Color.clear.frame(width: 88, height: 12)
            HStack(spacing: MGSpace.xs) {
                ForEach(days, id: \.self) { day in
                    Text(day.day == 1 || day.day % 5 == 0 ? "\(day.day)" : "")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(colors.mute.color)
                        .frame(width: 12, height: 15)
                        .id(day)
                }
            }
        }
        .accessibilityHidden(true)
    }
}

/// One item's marks across the month.
struct LogMarkStrip: View {
    let days: [LocalDay]
    let marks: [Bool?]
    let tone: InkTone
    let today: LocalDay
    /// R9f (G4): a tap on a cell; nil = cells do nothing.
    let onPick: ((LocalDay) -> Void)?

    init(days: [LocalDay], marks: [Bool?], tone: InkTone, today: LocalDay, onPick: ((LocalDay) -> Void)? = nil) {
        self.days = days
        self.marks = marks
        self.tone = tone
        self.today = today
        self.onPick = onPick
    }
    @Environment(\.mgColors) private var colors

    var body: some View {
        HStack(spacing: MGSpace.xs) {
            ForEach(Array(days.enumerated()), id: \.element) { index, day in
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(mark(at: index) == true ? colors.mark(tone).color : colors.trackPale.color)
                    .frame(width: 12, height: 12)
                    .overlay {
                        ZStack {
                            if mark(at: index) == false {
                                RoundedRectangle(cornerRadius: 3, style: .continuous)
                                    .strokeBorder(colors.mark(tone).color, lineWidth: 1)
                            }
                            if day == today {
                                RoundedRectangle(cornerRadius: 3, style: .continuous)
                                    .strokeBorder(colors.ink.color, lineWidth: 1.5)
                            }
                        }
                    }
            }
        }
        .padding(.vertical, 6)                      // a 24 pt tall touch area, the marks stay 12 pt
        .contentShape(Rectangle())
        .gesture(SpatialTapGesture().onEnded { tap in
            guard let onPick else { return }
            let pitch = 12 + MGSpace.xs
            let index = Int((tap.location.x / pitch).rounded(.down))
            if days.indices.contains(index) { onPick(days[index]) }
        }, including: onPick == nil ? .subviews : .all)
    }

    private func mark(at index: Int) -> Bool? {
        marks.indices.contains(index) ? marks[index] : nil
    }
}

/// The day a cell tap picked (R9f, G4).
struct LogPickedDay: Identifiable, Equatable {
    let day: LocalDay
    var id: String { day.iso }
}

/// One day of the month grid: each item's status on that day, as the grid already holds it.
struct LogMonthDaySheet: View {
    let day: LocalDay
    let grid: MonthGridState
    let today: LocalDay
    @Environment(\.mgColors) private var colors
    @Environment(\.calendar) private var calendar
    @Environment(\.dismiss) private var dismiss

    private var title: String {
        let name = MGFormat.shortDate(day.start(in: calendar.timeZone), calendar: calendar)
        return day == today ? "\(name) · today" : name
    }

    var body: some View {
        MGScreen {
            VStack(alignment: .leading, spacing: MGSpace.s) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title)
                        .mgFont(.headline)
                        .foregroundStyle(colors.ink.color)
                        .accessibilityAddTraits(.isHeader)
                    Spacer(minLength: 8)
                    MGButton("Done", style: .ghost, action: { dismiss() })
                }
                .padding(.top, 20)
                if let index = grid.days.firstIndex(of: day) {
                    ForEach(grid.rows) { row in
                        HStack {
                            Text(row.title)
                                .mgFont(.rowTitle)
                                .foregroundStyle(colors.ink.color)
                            Spacer(minLength: 8)
                            Text(Self.status(row.marks.indices.contains(index) ? row.marks[index] : nil))
                                .mgFont(.detail)
                                .foregroundStyle(colors.ink2.color)
                        }
                        .frame(minHeight: MGSpace.tapTarget)
                        .accessibilityElement(children: .combine)
                    }
                } else {
                    LogHint("That day is not in this month's grid.")
                }
                entriesSection
            }
            .padding(.bottom, 32)
        }
    }

    /// r9v (UI-SCRUB G4): what was logged that day, oldest first, with the time.
    @ViewBuilder private var entriesSection: some View {
        let list = grid.entries[day.iso] ?? []
        VStack(alignment: .leading, spacing: 0) {
            Text("Entries")
                .mgFont(.headline)
                .foregroundStyle(colors.ink.color)
                .padding(.top, MGSpace.m)
                .accessibilityAddTraits(.isHeader)
            if list.isEmpty {
                LogHint("Nothing was logged on this day.")
            } else {
                ForEach(list) { entry in
                    HStack(alignment: .firstTextBaseline, spacing: MGSpace.s) {
                        Text(MGFormat.time(entry.at, calendar: calendar))
                            .mgFont(.detail)
                            .foregroundStyle(colors.ink2.color)
                            .frame(width: 72, alignment: .leading)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.title)
                                .mgFont(.body)
                                .foregroundStyle(colors.ink.color)
                                .fixedSize(horizontal: false, vertical: true)
                            if let timing = entry.timing {
                                Text(timing).mgFont(.receipt).foregroundStyle(colors.mute.color)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, MGSpace.xs)
                    .frame(minHeight: MGSpace.tapTarget, alignment: .leading)
                    .accessibilityElement(children: .combine)
                }
                if let total = grid.entryTotals[day.iso] {
                    LogHint("Showing the first \(list.count) of \(total) entries.")
                }
            }
        }
    }

    static func status(_ mark: Bool?) -> String {
        switch mark {
        case .some(true): return "logged"
        case .some(false): return "scheduled, not done"
        case .none: return "nothing expected"
        }
    }
}
