import SwiftUI
import MGContext
import MGDomain
import MGDesign

// Wave 2 (2026-10-11): the views for outputs that had no screen — "Computed on PC", "Today's other outputs", a metric's
// "Every source", a group's measures, and the root's "Working on…" line. Pure rendering of MGContext states; every tap
// is a UIIntent; expansion is state (`.toggleRow`).

/// A labelled value: label, caption, the value with its receipt; a tap sends the item's intent when it has one.
struct ExploreLabeledValueRow: View {
    @Environment(\.mgColors) private var colors
    let item: LabeledValue
    let showsRule: Bool
    let send: (UIIntent) -> Void

    var body: some View {
        let content = HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.label)
                    .mgFont(.detail)
                    .foregroundStyle(colors.ink.color)
                    .fixedSize(horizontal: false, vertical: true)
                if let caption = item.caption {
                    Text(caption)
                        .mgFont(.receipt)
                        .foregroundStyle(colors.mute.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            ValueView(item.value, size: .small, showsReceipt: false)
                .frame(maxWidth: 170, alignment: .trailing)
        }
        .padding(.vertical, 7)
        .frame(minHeight: MGSpace.tapTarget)
        .contentShape(Rectangle())
        .overlay(alignment: .top) {
            if showsRule { Rectangle().fill(colors.rule.color).frame(height: 1).accessibilityHidden(true) }
        }
        if let intent = item.intent {
            Button { send(intent) } label: { content }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
        } else {
            content.accessibilityElement(children: .combine)
        }
    }
}

/// "Computed on PC": every PC model's newest result — status, why it didn't run, its values, the PC's own words.
struct ExplorePCLabSection: View {
    @Environment(\.mgColors) private var colors
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let rows: [PCModelRow]
    let send: (UIIntent) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader("Computed on PC", note: rows.isEmpty ? nil : "\(rows.count) models · newest result each")
            if rows.isEmpty {
                ExploreBlankNote("No PC result on this phone yet: they arrive with the next sync over Tailscale.")
            } else {
                VStack(spacing: 0) {
                    ForEach(rows) { row in
                        ExpandableRow(title: row.title, detail: row.reason.map { "\(row.status) — \($0)" } ?? row.status,
                                      receipt: nil, badge: RowBadge("PC", accent: row.tone == .good ? .ink2 : .mute),
                                      isOpen: Binding(get: { row.isOpen }, set: { _ in send(.toggleRow(id: row.rowId)) }),
                                      hasContent: !row.values.isEmpty || !row.notes.isEmpty) {
                            VStack(alignment: .leading, spacing: 0) {
                                ForEach(Array(row.values.enumerated()), id: \.element.id) { i, v in
                                    ExploreLabeledValueRow(item: v, showsRule: i > 0, send: send)
                                }
                                ForEach(Array(row.notes.enumerated()), id: \.offset) { _, note in
                                    Text(note)
                                        .mgFont(.detail)
                                        .foregroundStyle(colors.ink2.color)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .padding(.vertical, 4)
                                }
                            }
                        }
                        .animation(MGMotion.expand(reduceMotion: reduceMotion), value: row.isOpen)
                    }
                }
                .overlay(alignment: .top) {
                    Rectangle().fill(colors.rule.color).frame(height: 1).accessibilityHidden(true)
                }
            }
        }
    }
}

/// "Today's other outputs": pipeline outputs that are not metrics (movement, medication level, nicotine response,
/// adherence, social jetlag, habits, raw step ticks).
struct ExploreExtrasSection: View {
    @Environment(\.mgColors) private var colors
    let rows: [ExtraRow]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader("Today's other outputs", note: "computed on the phone")
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { i, row in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.title).mgFont(.rowTitle).foregroundStyle(colors.ink.color)
                                .fixedSize(horizontal: false, vertical: true)
                            if let d = row.detail {
                                Text(d).mgFont(.receipt).foregroundStyle(colors.mute.color)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        ValueView(row.value, size: .small)
                            .frame(maxWidth: 170, alignment: .trailing)
                    }
                    .padding(.vertical, 8)
                    .overlay(alignment: .top) {
                        if i > 0 { Rectangle().fill(colors.rule.color).frame(height: 1).accessibilityHidden(true) }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(.horizontal, 14)
            .mgSurface(.card, radius: MGRadius.card)
        }
    }
}

/// A metric's "Every source": ours, the PC's and imported history, each with where it came from.
struct MetricSourcesBlock: View {
    @Environment(\.mgColors) private var colors
    @Environment(\.calendar) private var calendar
    let sources: [SourceRow]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader("Every source", note: sources.isEmpty ? nil : "newest value each")
            if sources.isEmpty {
                ExploreBlankNote("No source has a value yet: waiting for the first night or the first PC result.")
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(sources.enumerated()), id: \.element.id) { i, src in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(src.label).mgFont(.detail).foregroundStyle(colors.ink.color)
                                    .fixedSize(horizontal: false, vertical: true)
                                Text(src.origin + (src.day.map { " · \($0.iso)" } ?? ""))
                                    .mgFont(.receipt).foregroundStyle(colors.mute.color)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            ValueView(src.value, size: .small, showsReceipt: true)
                                .frame(maxWidth: 170, alignment: .trailing)
                        }
                        .padding(.vertical, 8)
                        .overlay(alignment: .top) {
                            if i > 0 { Rectangle().fill(colors.rule.color).frame(height: 1).accessibilityHidden(true) }
                        }
                    }
                }
                .padding(.horizontal, 14)
                .mgSurface(.card, radius: MGRadius.card)
            }
        }
    }
}

/// A group's measures (G-HRV: all 13), each with its members' values.
struct GroupMeasuresBlock: View {
    @Environment(\.mgColors) private var colors
    let measures: [GroupMeasureRow]
    let send: (UIIntent) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader("Every measure in this group", note: "\(measures.count)")
            ForEach(measures) { m in
                VStack(alignment: .leading, spacing: 0) {
                    Button { send(.openMetric(key: m.key, variant: nil)) } label: {
                        HStack {
                            Text(m.name).mgFont(.rowTitle).foregroundStyle(colors.ink.color)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(colors.mute.color)
                                .accessibilityHidden(true)
                        }
                        .frame(minHeight: MGSpace.tapTarget)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    ForEach(Array(m.values.enumerated()), id: \.element.id) { i, v in
                        ExploreLabeledValueRow(item: v, showsRule: true, send: send)
                    }
                }
                .padding(.horizontal, 14)
                .mgSurface(.card, radius: MGRadius.card)
            }
        }
    }
}

/// T9976: the PC's HRV suite on the HRV group. r8h E2: with no PC result, ONE empty-state card (the sentence once);
/// with a result, one collapsed row per method (Night value in the header), its windows and source inside. Apple's
/// SDNN and WHOOP's history sit apart below. Open/closed is local (X5), nothing waits for the presenter.
struct HRVSuiteBlock: View {
    @Environment(\.mgColors) private var colors
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let suite: HRVSuiteState
    let send: (UIIntent) -> Void
    @State private var openMethods: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(suite.title, note: suite.methods.isEmpty ? nil : "\(suite.methods.count) methods")
            Text(suite.intro).mgFont(.detail).foregroundStyle(colors.ink2.color)
                .fixedSize(horizontal: false, vertical: true)
            if suite.methods.isEmpty {
                Text(suite.resultLine)
                    .mgFont(.detail)
                    .foregroundStyle(colors.ink2.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .mgSurface(.card, radius: MGRadius.card)
            } else {
                Text(suite.resultLine).mgFont(.receipt).foregroundStyle(colors.mute.color)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(suite.windows) { w in
                        Text("\(w.title): \(w.detail)").mgFont(.receipt).foregroundStyle(colors.ink2.color)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                VStack(spacing: 0) {
                    ForEach(suite.methods) { m in
                        ExpandableRow(title: m.name, detail: Self.headerText(m),
                                      receipt: nil,
                                      isOpen: Binding(get: { openMethods.contains(m.id) },
                                                      set: { on in
                                                          if on { openMethods.insert(m.id) } else { openMethods.remove(m.id) }
                                                      })) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(m.meaning).mgFont(.detail).foregroundStyle(colors.ink2.color)
                                    .fixedSize(horizontal: false, vertical: true)
                                Text("Source: \(m.source)").mgFont(.receipt).foregroundStyle(colors.mute.color)
                                    .fixedSize(horizontal: false, vertical: true)
                                if let g = MetricGrade.hrvSuite(m.id) {   // r9v (UI-SCRUB E3): METRICS grade per method
                                    Text(g.grade.line(g.row) + (g.note.map { " · \($0)" } ?? "") + " · wrist pulse, not ECG")
                                        .mgFont(.receipt).foregroundStyle(colors.mute.color)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                ForEach(Array(m.cells.enumerated()), id: \.element.id) { i, c in
                                    ExploreLabeledValueRow(item: LabeledValue(id: "\(m.id)|\(c.id)", label: c.window, value: c.value),
                                                           showsRule: i > 0, send: send)
                                }
                            }
                        }
                        .animation(MGMotion.expand(reduceMotion: reduceMotion), value: openMethods.contains(m.id))
                    }
                }
                .padding(.horizontal, 14)
                .mgSurface(.card, radius: MGRadius.card)
            }
            SectionHeader(suite.othersTitle, note: nil)
                .padding(.top, 6)
            VStack(spacing: 0) {
                ForEach(Array(suite.others.enumerated()), id: \.element.id) { i, o in
                    ExploreLabeledValueRow(item: o, showsRule: i > 0, send: send)
                }
            }
            .padding(.horizontal, 14)
            .mgSurface(.card, radius: MGRadius.card)
        }
    }

    /// The collapsed header: the night value, then the METRICS grade word ("Night 61 ms · PARTIAL").
    private static func headerText(_ m: HRVSuiteMethod) -> String {
        [nightText(m), MetricGrade.hrvSuite(m.id)?.grade.rawValue].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// "Night 61 ms" for the collapsed header; "Night: no value" when the night cell is blank.
    private static func nightText(_ m: HRVSuiteMethod) -> String {
        guard let night = m.cells.first(where: { $0.id == "night" }) else { return "" }
        switch night.value {
        case let .value(text, unit, _, _, _):
            return "Night " + [text, unit].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
        case .blank:
            return "Night: no value"
        }
    }
}

/// The root's "Working on" strip (T25, P11): ONE opaque 32 pt line in the top safe-area inset (never over content): the first
/// job, "· N more" when several, a 2 pt bar along the bottom when its end is known. Tap → Settings › Working on.
struct RootWorkingLine: View {
    @Environment(\.mgColors) private var colors
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let state: WorkingState
    let action: () -> Void

    private var text: String {
        let more = state.lines.count - 1
        return (state.lines.first?.text ?? "") + (more > 0 ? " · \(more) more" : "")
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if reduceMotion {
                    Circle().fill(colors.ink2.color).frame(width: 6, height: 6).frame(width: 12, height: 12)
                } else {
                    ProgressView().controlSize(.mini).frame(width: 12, height: 12)
                }
                Text(text)
                    .mgFont(.receipt)
                    .foregroundStyle(colors.ink2.color)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                Text("›").mgFont(.receipt).foregroundStyle(colors.mute.color)
            }
            .padding(.horizontal, MGSpace.gutter)
            .frame(height: 32)
            .background(colors.sheet.color)
            .overlay(alignment: .bottom) {
                ZStack(alignment: .bottomLeading) {
                    Rectangle().fill(colors.rule.color).frame(height: 1)
                    if let f = state.lines.first?.fraction {
                        Rectangle().fill(colors.focus.color).frame(height: 2)
                            .scaleEffect(x: min(max(f, 0), 1), anchor: .leading)
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Working on: " + text + (state.lines.first?.fraction.map { ", \(Int(($0 * 100).rounded())) percent" } ?? ""))
        .accessibilityHint("Opens Preferences, where Working on is")
    }
}

/// T108: the one failure badge on Today (sync broken, history stuck, compute far too long): a 28 pt capsule. Progress is never
/// shown here. Tap opens Strap & sync, or Settings › Working on when that is where the detail lives.
struct RootWorkingBadge: View {
    @Environment(\.mgColors) private var colors
    let badge: WorkingBadge
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(badge.text)
                .mgFont(.detail)
                .foregroundStyle(colors.bodyText.color)
                .lineLimit(1)
                .padding(.horizontal, MGSpace.m)
                .frame(height: 28)
                .background(Capsule().fill(colors.bodyWash.color))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, MGSpace.gutter)
                .padding(.vertical, MGSpace.xs)
                .background(colors.background.firstColor.color)
        }
        .buttonStyle(.plain)
    }
}

#if DEBUG
private struct RootBannersPreview: View {
    let theme: ThemeName

    private let one = WorkingState(lines: [.init(id: "compute", text: "Computing 2 days (hourly)", fraction: nil)])
    private let three = WorkingState(lines: [
        .init(id: "history", text: "Strap history · 40 chunks · 3,919 records", fraction: 0.42),
        .init(id: "compute", text: "Computing 2 days (hourly)", fraction: nil),
        .init(id: "upload", text: "Sending to the PC: 3 of 9", fraction: 0.33)])

    var body: some View {
        VStack(spacing: 16) {
            RootWorkingLine(state: one) {}
            RootWorkingLine(state: three) {}
            // Hidden (Settings › Top bar › Hide moving bars): the root draws nothing when the state is empty.
            Text("hidden: no line").mgFont(.receipt)
            RootWorkingBadge(badge: WorkingBadge(text: "History stuck · tap", opensStrapSync: true)) {}
            RootNotice(text: "Couldn't reach the PC. Nothing was lost.")
        }
        .mgTheme(theme)
        .background(Theme.colors(for: theme).background.lastColor.color)
    }
}

#Preview("Banners, Day") { RootBannersPreview(theme: .cream) }
#Preview("Banners, Night") { RootBannersPreview(theme: .emerald) }
#endif

/// r9s (D-TRENDS-1, D-POP-PRIOR): the six relative trends as cards. Each says what it tracks, where it stands now against your own
/// baseline ('population' next to 'yours (N nights)' in the sentence), its backing (paper / theory / both) and the base and
/// enhanced tiers. Never a diagnosis. Pure rendering of `TrendCard`s.
struct ExploreTrendsSection: View {
    @Environment(\.mgColors) private var colors
    let cards: [TrendCard]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader("Trends against your own baseline", note: "a trend is not a diagnosis")
            VStack(spacing: 0) {
                ForEach(Array(cards.enumerated()), id: \.element.id) { i, card in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(card.title).mgFont(.rowTitle).foregroundStyle(colors.ink.color)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(card.value.map { card.status + " · " + $0 } ?? card.status)
                                .mgFont(.receipt).foregroundStyle(colors.ink2.color)
                                .fixedSize(horizontal: false, vertical: true)
                                .multilineTextAlignment(.trailing)
                        }
                        if let sentence = card.sentence {
                            Text(sentence).mgFont(.body).foregroundStyle(colors.ink.color)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Text("Tracks: " + card.tracks).mgFont(.receipt).foregroundStyle(colors.mute.color)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("Backing (" + card.backingKind + "): " + card.backing).mgFont(.receipt)
                            .foregroundStyle(colors.mute.color).fixedSize(horizontal: false, vertical: true)
                        Text("Tiers: " + card.tiers + (card.tierUsed.map { " Used now: " + $0 + "." } ?? ""))
                            .mgFont(.receipt).foregroundStyle(colors.mute.color).fixedSize(horizontal: false, vertical: true)
                        Text("Population: " + card.population).mgFont(.receipt).foregroundStyle(colors.mute.color)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 8)
                    .overlay(alignment: .top) {
                        if i > 0 { Rectangle().fill(colors.rule.color).frame(height: 1).accessibilityHidden(true) }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(.horizontal, 14)
            .mgSurface(.card, radius: MGRadius.card)
        }
    }
}
