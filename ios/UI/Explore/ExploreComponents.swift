import Foundation
import SwiftUI
import MGContext
import MGDomain
import MGDesign

// Small building blocks shared by the Explore screens (WP-19). Everything here is drawn from state; taps are
// `UIIntent`s sent through the closure the screen passes in. Expansion is state-driven (BRIEF interface table).

// MARK: - Segmented chips (period picker, Number · Graph · Trend, lag)

/// A row of equal segments on the chip wash; the selected one is filled. Falls back to a horizontal scroll when the
/// labels no longer fit (large Dynamic Type), so no label is ever cut off.
struct ExploreSegmentedChips<Item: Hashable>: View {
    @Environment(\.mgColors) private var colors
    private let items: [Item]
    private let selected: Item
    private let accessibilityName: String
    private let title: (Item) -> String
    private let onSelect: (Item) -> Void

    init(items: [Item], selected: Item, accessibilityName: String, title: @escaping (Item) -> String,
         onSelect: @escaping (Item) -> Void) {
        self.items = items
        self.selected = selected
        self.accessibilityName = accessibilityName
        self.title = title
        self.onSelect = onSelect
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            row
            ScrollView(.horizontal, showsIndicators: false) { row }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityName)
    }

    private var row: some View {
        HStack(spacing: 2) {
            ForEach(items, id: \.self) { item in
                segment(item)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: MGRadius.chip + 2, style: .continuous).fill(colors.chip.color))
    }

    private func segment(_ item: Item) -> some View {
        let isSelected = item == selected
        return Button {
            onSelect(item)
        } label: {
            Text(title(item))
                .mgFont(.button)
                .foregroundStyle(isSelected ? colors.buttonText.color : colors.ink.color)
                .lineLimit(1)
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, minHeight: MGSpace.tapTarget)
                .background {
                    RoundedRectangle(cornerRadius: MGRadius.chip, style: .continuous)
                        .fill(isSelected ? colors.buttonFill.color : Color.clear)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// UX §9 component 2. The selection comes from state; a tap sends `.setPeriod`.
struct ExplorePeriodPicker: View {
    @Environment(\.mgColors) private var colors
    @Environment(\.calendar) private var calendar
    private let selected: ExplorePeriod
    private let send: (UIIntent) -> Void
    /// T9822: the Custom chip opens the start / end sheet.
    @State private var pickingRange = false
    /// r8h E9: the chip just tapped, highlighted at once; cleared when the presenter's state arrives.
    @State private var tappedPeriod: ExplorePeriod?

    private let periods = ExplorePeriod.pickerChips

    init(selected: ExplorePeriod, send: @escaping (UIIntent) -> Void) {
        self.selected = selected
        self.send = send
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(periods, id: \.key) { period in
                        periodButton(period)
                            .id(period.key)
                    }
                }
                .padding(2)
            }
            .mask {
                HStack(spacing: 0) {
                    Rectangle().fill(.black)
                    LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: 24)
                }
            }
            .background(Capsule().fill(colors.chip.color))
            .frame(height: MGSpace.tapTarget)
            .clipShape(Capsule())
            .onAppear {
                DispatchQueue.main.async { proxy.scrollTo(selected.key, anchor: .center) }
            }
        }
        .onChange(of: selected) { _, _ in tappedPeriod = nil }
        .task(id: tappedPeriod) {      // a local highlight never outlives a presenter that said no
            guard tappedPeriod != nil else { return }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if !Task.isCancelled { tappedPeriod = nil }
        }
        .sheet(isPresented: $pickingRange) {
            CustomRangeSheet(current: selected.customRange, today: LocalDay(date: Date(), calendar: calendar),
                             calendar: calendar) { range in
                send(.setPeriod(.custom(range)))
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Period")
    }

    private func periodButton(_ period: ExplorePeriod) -> some View {
        let shown = tappedPeriod ?? selected
        let isSelected = period.isCustom ? shown.isCustom : period == shown
        // The Custom chip shows the picked range once Custom is selected, else just "Custom".
        let title = period.isCustom ? selected.isCustom ? selected.title : "Custom" : period.title
        return Button {
            if period.isCustom {
                // r8h E9: the sheet opens at once (nothing waits for the presenter). Nothing is sent until Apply, so
                // Cancel leaves the period as it was and no flag is left behind.
                pickingRange = true
            } else {
                tappedPeriod = period
                send(.setPeriod(period))
            }
        } label: {
            Text(title)
                .mgFont(.button)
                .foregroundStyle(isSelected ? colors.buttonText.color : colors.ink2.color)
                .lineLimit(1)
                .padding(.horizontal, 14)
                .frame(minHeight: MGSpace.tapTarget)
                .background {
                    if isSelected { Capsule().fill(colors.buttonFill.color) }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// T9822: two date pickers, Apply refused with the reason (end before start, after today, over 3 years).
struct CustomRangeSheet: View {
    @Environment(\.dismiss) private var dismiss
    private let today: LocalDay
    private let calendar: Calendar
    private let apply: (CustomRange) -> Void
    @State private var start: Date
    @State private var end: Date

    init(current: CustomRange?, today: LocalDay, calendar: Calendar, apply: @escaping (CustomRange) -> Void) {
        self.today = today
        self.calendar = calendar
        self.apply = apply
        let zone = calendar.timeZone
        let noon: (LocalDay) -> Date = { $0.start(in: zone).addingTimeInterval(43_200) }
        _start = State(initialValue: noon(current?.start ?? today.adding(days: -29)))
        _end = State(initialValue: noon(current?.end ?? today))
    }

    private var startDay: LocalDay { LocalDay(date: start, calendar: calendar) }
    private var endDay: LocalDay { LocalDay(date: end, calendar: calendar) }
    private var problem: String? { CustomRange.problem(start: startDay, end: endDay, today: today) }

    var body: some View {
        NavigationStack {
            Form {
                DatePicker("Start", selection: $start, in: ...Date(), displayedComponents: .date)
                DatePicker("End", selection: $end, in: ...Date(), displayedComponents: .date)
                if let problem {
                    Text(problem).foregroundStyle(.red)
                } else if let r = try? CustomRange.make(start: startDay, end: endDay, today: today).get() {
                    Text("\(r.days) days: \(r.label)")
                }
            }
            .environment(\.calendar, calendar)
            .navigationTitle("Custom range")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        if case .success(let r) = CustomRange.make(start: startDay, end: endDay, today: today) {
                            apply(r)
                            dismiss()
                        }
                    }
                    .disabled(problem != nil)
                }
            }
        }
        .presentationDetents([.medium])
    }
}

// MARK: - Search

/// "Find a metric…" (UX §9 component 1). Typing keeps a local draft so the caret never jumps, and sends
/// `.search(text)` on every change; the presenter filters the catalogue (names, ALG ids, codenames like Loop)
/// and the filtered sections come back in `ExploreState`.
struct ExploreSearchField: View {
    @Environment(\.mgColors) private var colors
    private let query: String
    private let send: (UIIntent) -> Void
    @State private var draft: String

    init(query: String, send: @escaping (UIIntent) -> Void) {
        self.query = query
        self.send = send
        _draft = State(initialValue: query)
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(colors.ink2.color)
                .accessibilityHidden(true)
            TextField(text: $draft, prompt: Text("Find a metric, an ALG id, a codename…")
                .foregroundStyle(colors.ink2.color)) {
                Text("Search metrics")
            }
            .mgFont(.body)
            .foregroundStyle(colors.ink.color)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .submitLabel(.search)
            .onSubmit { KeyboardFocus.resign() }    // r8h E11: Return closes the keyboard
            if !draft.isEmpty {
                Button {
                    draft = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(colors.ink2.color)
                        .frame(width: MGSpace.tapTarget, height: MGSpace.tapTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.leading, 12)
        .frame(height: 48)
        .background(RoundedRectangle(cornerRadius: MGRadius.tile, style: .continuous).fill(colors.chip.color))
        // r8h E1: wait ~150 ms after the last keystroke before the presenter filters (a task keyed on the text is
        // cancelled by the next keystroke). A cleared field sends at once.
        .task(id: draft) {
            guard draft != query else { return }
            if !draft.isEmpty {
                try? await Task.sleep(nanoseconds: 150_000_000)
                if Task.isCancelled { return }
            }
            send(.search(draft))
        }
        .onChange(of: query) { _, new in
            if new != draft { draft = new }
        }
    }
}

// MARK: - Local filter + pick list (R9f, UI-SCRUB-B E7)

/// A search box that only filters the list beside it on this screen (no intent, no presenter work): Compare's second-metric
/// list and the Matrix picker. Same look as `ExploreSearchField`.
struct ExploreFilterField: View {
    @Binding var text: String
    var prompt: String = "Find a metric…"
    @Environment(\.mgColors) private var colors

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(colors.ink2.color)
                .accessibilityHidden(true)
            TextField(text: $text, prompt: Text(prompt).foregroundStyle(colors.ink2.color)) {
                Text("Filter metrics")
            }
            .mgFont(.body)
            .foregroundStyle(colors.ink.color)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .submitLabel(.search)
            .onSubmit { KeyboardFocus.resign() }
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(colors.ink2.color)
                        .frame(width: MGSpace.tapTarget, height: MGSpace.tapTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear filter")
            }
        }
        .padding(.leading, 12)
        .frame(height: 48)
        .background(RoundedRectangle(cornerRadius: MGRadius.tile, style: .continuous).fill(colors.chip.color))
    }
}

enum ExploreMetricFilter {
    /// Metrics whose name or key contains `query` (case and accent blind); everything when the query is blank. Order kept.
    static func apply(_ metrics: [MatrixMetric], query: String) -> [MatrixMetric] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return metrics }
        return metrics.filter { $0.name.localizedStandardContains(q) || $0.key.localizedStandardContains(q) }
    }
}

/// Compare's "second metric" list (it was a chip for every metric in the catalogue): the chosen one first, a filter box, then
/// at most `limit` rows, with a line saying how many more a longer search would show. One tap = `onPick(key)`.
struct ExploreMetricPickList: View {
    let options: [MatrixMetric]
    let selectedKey: String?
    let onPick: (String) -> Void
    var limit: Int = 12
    @State private var query = ""
    @Environment(\.mgColors) private var colors

    var body: some View {
        let matches = ExploreMetricFilter.apply(options, query: query)
        let shown = Array(matches.prefix(limit))
        VStack(alignment: .leading, spacing: 8) {
            if let key = selectedKey, let chosen = options.first(where: { $0.key == key }) {
                Chip(chosen.name, selected: true) { onPick(chosen.key) }
                    .accessibilityHint("The metric chosen now")
            }
            ExploreFilterField(text: $query, prompt: "Find a metric to compare with…")
            if shown.isEmpty {
                ExploreBlankNote("No metric matches “\(query)”.")
            } else {
                VStack(spacing: 0) {
                    ForEach(shown) { metric in
                        let isOn = metric.key == selectedKey
                        Button { onPick(metric.key) } label: {
                            HStack(spacing: 10) {
                                Text(metric.name)
                                    .mgFont(.rowTitle)
                                    .foregroundStyle(colors.ink.color)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                if isOn {
                                    Image(systemName: "checkmark").foregroundStyle(colors.ink.color).accessibilityHidden(true)
                                }
                            }
                            .frame(minHeight: MGSpace.tapTarget)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(isOn ? .isSelected : [])
                        .overlay(alignment: .bottom) {
                            Rectangle().fill(colors.rule.color).frame(height: 1).accessibilityHidden(true)
                        }
                    }
                }
                if matches.count > shown.count {
                    Text("\(matches.count - shown.count) more. Type to narrow the list.")
                        .mgFont(.receipt)
                        .foregroundStyle(colors.mute.color)
                }
            }
        }
    }
}

// MARK: - Rows

/// A row that pushes another screen: title, one line of detail, chevron. At least 56 pt tall.
struct ExploreNavRow: View {
    @Environment(\.mgColors) private var colors
    private let title: String
    private let detail: String?
    private let action: () -> Void

    init(title: String, detail: String?, action: @escaping () -> Void) {
        self.title = title
        self.detail = detail
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).mgFont(.rowTitle).foregroundStyle(colors.ink.color)
                    if let detail {
                        Text(detail)
                            .mgFont(.detail)
                            .foregroundStyle(colors.ink2.color)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(colors.mute.color)
                    .accessibilityHidden(true)
            }
            .padding(.vertical, 8)
            .frame(minHeight: MGSpace.rowMinHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .overlay(alignment: .bottom) {
            Rectangle().fill(colors.rule.color).frame(height: 1).accessibilityHidden(true)
        }
    }
}

/// "Coverage — 26 of 30 days": a label left, the value right, a hairline above.
struct ExploreInfoRow: View {
    @Environment(\.mgColors) private var colors
    private let label: String
    private let value: String

    init(label: String, value: String) {
        self.label = label
        self.value = value
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label).mgFont(.detail).foregroundStyle(colors.ink2.color)
            Spacer(minLength: 8)
            Text(value)
                .mgFont(.rowTitle)
                .foregroundStyle(colors.ink.color)
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 10)
        .frame(minHeight: MGSpace.tapTarget)
        .accessibilityElement(children: .combine)
        .overlay(alignment: .top) {
            Rectangle().fill(colors.rule.color).frame(height: 1).accessibilityHidden(true)
        }
    }
}

/// Blank with its reason (UX §13, R6): a dash and the sentence that says why. Never a number.
struct ExploreBlankNote: View {
    @Environment(\.mgColors) private var colors
    private let reason: String

    init(_ reason: String) {
        self.reason = reason
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("—").mgFont(.number).foregroundStyle(colors.mute.color).accessibilityHidden(true)
            Text(reason)
                .mgFont(.detail)
                .foregroundStyle(colors.ink2.color)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("No value. \(reason)")
    }
}

// MARK: - Headers

/// The top of a pushed Explore screen: kicker, serif title, optional receipt. Sits in the Emerald glow, so its
/// secondary text uses `topText` (never `mute`, UX §1.2).
struct ExplorePushHeader: View {
    @Environment(\.mgColors) private var colors
    @Environment(\.mgNow) private var now
    @Environment(\.calendar) private var calendar
    private let kicker: String
    private let title: String
    private let receipt: Receipt?

    init(kicker: String, title: String, receipt: Receipt? = nil) {
        self.kicker = kicker
        self.title = title
        self.receipt = receipt
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(kicker).mgFont(.kicker).foregroundStyle(colors.topText.color)
            Text(title)
                .mgFont(.title)
                .foregroundStyle(colors.ink.color)
                .fixedSize(horizontal: false, vertical: true)
            if let receipt {
                let line = [receipt.method, receipt.text(calendar: calendar, now: now)]
                    .compactMap { $0 }
                    .joined(separator: " · ")
                Text(line)
                    .mgFont(.receipt)
                    .foregroundStyle(colors.topText.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(ExploreText.spoken(line))
            }
        }
        .padding(.top, 12)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}
