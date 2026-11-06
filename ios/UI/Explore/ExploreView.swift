import SwiftUI
import MGContext
import MGDesign

// Explore — "a final tab I scroll to what I want to see" (BRIEF, UX-SPEC §9). Pure rendering of `ExploreState`:
// header · search · period picker · pinned shelf · catalogue by body system · correlation-matrix card.
// Every tap is a `UIIntent` sent through `send`; section expansion is state-driven (`.toggleRow(id:)`), never local.
// Owner: WP-19. The theme comes from the root (`.mgTheme(...)`), as for every tab except Today.
//
// Integration (WP-23 RootView). Explore tab root: `ExploreView(state:send:)`. Screens pushed from it, all internal to MGApp:
//   .openMetric        -> MetricDetailView(state: MetricDetailState, send:)   (also pushed from any number on Today)
//   .openCompare / .openMatrixCell -> CompareView(state: CompareState, send:)
//   .openMatrix        -> MatrixView(state: MatrixState, choices:, send:)  with choices = ExploreChoices.metrics(from: exploreState)
//   .openGroup         -> GroupView(state: GroupState, send:)
// The root also sets `.environment(\.mgNow, now)` (receipts from an earlier day read "from Thu 9 Oct"). The pushed screens draw
// no back button: the root's NavigationStack provides it. Catalogue sections open with `.toggleRow(id: section.id)`
// (the id is the section title). The presenter filters the catalogue for `.search(text)`; the view shows what it is given.

struct ExploreView: View {
    @Environment(\.mgColors) private var colors
    private let state: ExploreState
    private let send: (UIIntent) -> Void

    init(state: ExploreState, send: @escaping (UIIntent) -> Void) {
        self.state = state
        self.send = send
    }

    private var searching: Bool {
        !state.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var pinnedKeys: Set<String> {
        Set(state.shelf.map { $0.key })
    }

    var body: some View {
        MGScreen {
            VStack(alignment: .leading, spacing: 0) {
                header
                    .padding(.top, 12)
                    .padding(.bottom, 14)

                ExploreSearchField(query: state.query, send: send)

                ExplorePeriodPicker(selected: state.period, send: send)
                    .padding(.top, 10)
                if let note = state.pcHistory {             // tracker #7: older years from the PC
                    PCHistoryNoteView(note, shown: state.pcHistoryShown)
                }

                if !searching {
                    ExploreShelf(shelf: state.shelf, send: send)
                }

                ExploreCatalogue(sections: state.catalogue, pinned: pinnedKeys, query: state.query,
                                 searching: searching, send: send)

                if !searching {
                    if !state.trends.isEmpty {                                              // r9s: relative trends
                        ExploreTrendsSection(cards: state.trends)
                            .padding(.top, MGSpace.section)
                    }
                    // Wave 2: every PC model's newest result, and today's outputs that are not metrics.
                    ExplorePCLabSection(rows: state.pcLab, send: send)
                        .padding(.top, MGSpace.section)
                    ExploreExtrasSection(rows: state.extras)
                        .padding(.top, MGSpace.section)
                    ExploreWorkoutsSection(history: state.workoutHistory, send: send)      // T116
                        .padding(.top, MGSpace.section)
                }

                if !searching {
                    ExploreMatrixCard(title: state.matrixTitle, subtitle: state.matrixSubtitle, send: send)
                        .padding(.top, MGSpace.section)
                    // T10022 (S12): the way to Settings from any tab (the gear is only on Today).
                    VStack(alignment: .leading, spacing: 0) {
                        SettingsLinkRow(SettingsMap.crossLinkTitle(on: .preferences),
                                        detail: SettingsMap.crossLinkDetail(on: .preferences),
                                        action: { send(.openSettings) }) { EmptyView() }
                    }
                    .padding(.horizontal, MGSpace.tileInset)
                    .mgSurface(.tile)
                    .padding(.top, MGSpace.section)
                }
            }
            .padding(.bottom, 40)
        }
        .exploreSampleBanner(state.sample)
        .environment(\.mgSend, send)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Any metric · any period")
                .mgFont(.kicker)
                .foregroundStyle(colors.topText.color)
            Text("Explore")
                .mgFont(.title)
                .foregroundStyle(colors.ink.color)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Shelf (UX §9 component 3)

/// Mo's pinned metrics: name, the number for the period, a sparkline. Long-press = Unpin.
struct ExploreShelf: View {
    @Environment(\.mgColors) private var colors
    private let shelf: [ShelfItem]
    private let send: (UIIntent) -> Void

    init(shelf: [ShelfItem], send: @escaping (UIIntent) -> Void) {
        self.shelf = shelf
        self.send = send
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader("Your shelf", note: "long-press a metric to unpin")
            if shelf.isEmpty {
                Text("Nothing pinned yet. Long-press any metric in the list below to pin it here.")
                    .mgFont(.body)
                    .foregroundStyle(colors.ink2.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 4)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: MGSpace.m) {
                        ForEach(shelf) { item in
                            ExploreShelfRow(item: item, send: send)
                        }
                    }
                    .padding(.vertical, 1)
                }
            }
        }
    }
}

struct ExploreShelfRow: View {
    @Environment(\.mgColors) private var colors
    private let item: ShelfItem
    private let send: (UIIntent) -> Void

    init(item: ShelfItem, send: @escaping (UIIntent) -> Void) {
        self.item = item
        self.send = send
    }

    var body: some View {
        Button {
            send(.openMetric(key: item.key, variant: nil))
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                Text(item.name)
                    .mgFont(.label)
                    .foregroundStyle(colors.ink2.color)
                    .lineLimit(1)
                    .truncationMode(.tail)
                ValueView(item.value, size: .number)
                    .frame(maxWidth: .infinity, alignment: .leading)
                SparklineView(values: item.sparkline, accent: .ink2, width: nil, height: 40, lineWidth: 1.6)
            }
            .padding(MGSpace.tileInset)
            .frame(width: 156, alignment: .topLeading)
            .frame(minHeight: 104, alignment: .topLeading)    // r8h E10: grows with Dynamic Type instead of clipping
            .mgSurface(.card, radius: MGRadius.tile)
            .contentShape(RoundedRectangle(cornerRadius: MGRadius.tile, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens \(item.name)")
        .accessibilityAction(named: "Unpin from shelf") {
            send(.pinMetric(key: item.key, pinned: false))
        }
        .contextMenu {
            Button("Unpin from shelf", systemImage: "pin.slash") {
                send(.pinMetric(key: item.key, pinned: false))
            }
        }
    }
}

// MARK: - Catalogue (UX §9 component 4)

/// The collapsible sections by body system (Heart & lungs · Sleep · Activity · …). A section opens in place from
/// state (`isOpen`); while a search is active every section with a match shows its matches open, because the
/// matches are the answer. The presenter does the filtering (it knows ALG ids and codenames); this view only
/// draws what it is given and says so when nothing matches.
struct ExploreCatalogue: View {
    @Environment(\.mgColors) private var colors
    private let sections: [CatalogueSection]
    private let pinned: Set<String>
    private let query: String
    private let searching: Bool
    private let send: (UIIntent) -> Void
    /// r8h E1: while searching, only the first 40 matches are drawn; "Show more" adds 40.
    @State private var searchLimit = ExploreCatalogue.searchPage

    static let searchPage = 40

    init(sections: [CatalogueSection], pinned: Set<String>, query: String, searching: Bool,
         send: @escaping (UIIntent) -> Void) {
        self.sections = sections
        self.pinned = pinned
        self.query = query
        self.searching = searching
        self.send = send
    }

    private var visible: [CatalogueSection] {
        searching ? sections.filter { !$0.entries.isEmpty } : sections
    }

    /// The sections to draw: all of them normally; while searching, trimmed to `searchLimit` matches in total.
    private var drawn: [CatalogueSection] {
        guard searching else { return sections }
        var left = searchLimit
        var out: [CatalogueSection] = []
        for var section in visible where left > 0 {
            if section.entries.count > left { section.entries = Array(section.entries.prefix(left)) }
            left -= section.entries.count
            out.append(section)
        }
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if searching && visible.isEmpty {
                ExploreBlankNote("Nothing matches “\(query.trimmingCharacters(in: .whitespacesAndNewlines))”. "
                                 + "Try a metric name, an ALG id or a codename like Loop.")
            } else if sections.isEmpty {
                ExploreBlankNote("The catalogue is empty: no metrics have been registered yet.")
            } else {
                SectionHeader("All metrics", note: searching ? "\(matchCount) found" : "by body system")
                VStack(spacing: 0) {
                    ForEach(drawn) { section in
                        ExploreSectionRow(section: section, forceOpen: searching, pinned: pinned, send: send)
                    }
                }
                .overlay(alignment: .top) {
                    Rectangle().fill(colors.rule.color).frame(height: 1).accessibilityHidden(true)
                }
                if searching && matchCount > searchLimit {
                    MGButton("Show more (\(matchCount - searchLimit) left)", style: .ghost) {
                        searchLimit += ExploreCatalogue.searchPage
                    }
                    .padding(.top, 10)
                }
            }
        }
        .onChange(of: query) { _, _ in searchLimit = ExploreCatalogue.searchPage }
    }

    private var matchCount: Int {
        visible.reduce(0) { $0 + $1.entries.count }
    }
}

struct ExploreSectionRow: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let section: CatalogueSection
    private let forceOpen: Bool
    private let pinned: Set<String>
    private let send: (UIIntent) -> Void

    init(section: CatalogueSection, forceOpen: Bool, pinned: Set<String>, send: @escaping (UIIntent) -> Void) {
        self.section = section
        self.forceOpen = forceOpen
        self.pinned = pinned
        self.send = send
    }

    private var isOpen: Bool { forceOpen || section.isOpen }

    var body: some View {
        ExpandableRow(
            title: section.title,
            detail: section.entries.count == 1 ? "1 metric" : "\(section.entries.count) metrics",
            receipt: nil,
            isOpen: Binding(get: { isOpen }, set: { _ in send(.toggleRow(id: section.id)) }),
            hasContent: !section.entries.isEmpty
        ) {
            LazyVStack(alignment: .leading, spacing: 0) {    // r8h E1: rows are built as they scroll in
                ForEach(section.entries) { entry in
                    ExploreEntryRow(entry: entry, isPinned: pinned.contains(entry.key), send: send)
                }
            }
        }
        .animation(MGMotion.expand(reduceMotion: reduceMotion), value: isOpen)
    }
}

struct ExploreEntryRow: View {
    @Environment(\.mgColors) private var colors
    private let entry: CatalogueEntry
    private let isPinned: Bool
    private let send: (UIIntent) -> Void

    init(entry: CatalogueEntry, isPinned: Bool, send: @escaping (UIIntent) -> Void) {
        self.entry = entry
        self.isPinned = isPinned
        self.send = send
    }

    var body: some View {
        Button {
            send(entry.intent)
        } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(entry.name)
                            .mgFont(.rowTitle)
                            .fontWeight(.medium)
                            .foregroundStyle(colors.ink.color)
                            .fixedSize(horizontal: false, vertical: true)
                        if entry.isResearch { ResearchTag() }
                    }
                    if let detail = entry.detail {
                        // Wave 2 "Every measure": where the newest value came from (algorithm · origin · day)
                        Text(detail)
                            .mgFont(.receipt)
                            .foregroundStyle(colors.mute.color)
                            .lineLimit(2)    // r8h E10: two lines, so the origin (strap / ours / WHOOP / Apple) is not cut
                            .fixedSize(horizontal: false, vertical: true)
                    } else if let group = entry.groupId {
                        Text("\(group) · comparison group")
                            .mgFont(.receipt)
                            .foregroundStyle(colors.mute.color)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if let value = entry.value {
                    ValueView(value, size: .small)
                        .frame(maxWidth: 130, alignment: .trailing)
                }
                if isPinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(colors.ink2.color)
                        .accessibilityLabel("Pinned to your shelf")
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(colors.mute.color)
                    .accessibilityHidden(true)
            }
            .frame(minHeight: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens \(entry.name)")
        .overlay(alignment: .bottom) {
            Rectangle().fill(colors.rule.color).frame(height: 1).accessibilityHidden(true)
        }
        .modifier(ExplorePinActions(entry: entry, isPinned: isPinned, send: send))
    }
}

/// Long-press = Pin / Unpin (UX §10), only for entries that open a metric (not research tools or groups).
private struct ExplorePinActions: ViewModifier {
    let entry: CatalogueEntry
    let isPinned: Bool
    let send: (UIIntent) -> Void

    func body(content: Content) -> some View {
        if entry.isMetric {
            content
                .contextMenu {
                    Button(isPinned ? "Unpin from shelf" : "Pin to shelf",
                           systemImage: isPinned ? "pin.slash" : "pin") {
                        send(.pinMetric(key: entry.key, pinned: !isPinned))
                    }
                }
                .accessibilityAction(named: isPinned ? "Unpin from shelf" : "Pin to shelf") {
                    send(.pinMetric(key: entry.key, pinned: !isPinned))
                }
        } else {
            content
        }
    }
}

// MARK: - Matrix card (UX §9 component 5)

/// "Correlation matrix — pick up to 8" → Matrix (APP-104, in the first build by BRIEF default 6).
struct ExploreMatrixCard: View {
    @Environment(\.mgColors) private var colors
    private let title: String
    private let subtitle: String
    private let send: (UIIntent) -> Void

    init(title: String, subtitle: String, send: @escaping (UIIntent) -> Void) {
        self.title = title
        self.subtitle = subtitle
        self.send = send
    }

    var body: some View {
        Button {
            send(.openMatrix)
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).mgFont(.rowTitle).foregroundStyle(colors.ink.color)
                    Text(subtitle)
                        .mgFont(.detail)
                        .foregroundStyle(colors.ink2.color)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Correlation, not cause.")
                        .mgFont(.receipt)
                        .foregroundStyle(colors.mute.color)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                ExploreMatrixGlyph()
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(colors.mute.color)
                    .accessibilityHidden(true)
            }
            .frame(minHeight: MGSpace.rowMinHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens the correlation matrix")
        .overlay(alignment: .bottom) {
            Rectangle().fill(colors.rule.color).frame(height: 1).accessibilityHidden(true)
        }
    }
}

/// A 3 × 3 picture of a diverging grid — an icon, not data (hidden from VoiceOver).
struct ExploreMatrixGlyph: View {
    @Environment(\.mgColors) private var colors
    private static let pattern: [[Double]] = [[1, -0.6, 0.4], [-0.6, 1, -0.3], [0.4, -0.3, 1]]

    init() {}

    var body: some View {
        Canvas { ctx, size in
            let cell = size.width / 3
            for r in 0..<3 {
                for c in 0..<3 {
                    let v = ExploreMatrixGlyph.pattern[r][c]
                    let rect = CGRect(x: CGFloat(c) * cell + 1, y: CGFloat(r) * cell + 1,
                                      width: cell - 2, height: cell - 2)
                    let tone = v < 0 ? colors.sleep : colors.caffeine
                    ctx.fill(Path(roundedRect: rect, cornerRadius: 3),
                             with: .color(tone.opacity(abs(v) * 0.85 + 0.1).color))
                }
            }
        }
        .frame(width: 48, height: 48)
        .accessibilityHidden(true)
    }
}
