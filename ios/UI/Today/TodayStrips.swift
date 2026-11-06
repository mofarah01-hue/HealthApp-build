import SwiftUI
import MGContext
import MGDesign

/// UX §3.2 row 7 (0.6, P05, T98): "Last night" vitals (morning, early afternoon) or "Today so far" (late afternoon on);
/// the other one sits collapsed below. Values sit on tiles: the first two large side by side, the rest three to a row.
/// Meaning labels (est., ±, raw, research) stay on the value; receipts moved behind the tile (one hint line under the
/// grid). Raw counts arrive from the presenter as `.strapRaw` (SpO₂ byte, no % sign) or as words (skin temp
/// "in range") — this view never adds units. Blanks show "—" + reason.
///
/// The header opens and closes the strip by sending `.toggleRow(id: "strip.<kind>")` (e.g. "strip.lastNight"); the
/// presenter flips `isCollapsed`.
struct TodayStripView: View {
    let strip: StripState
    let collapsible: Bool
    let send: (UIIntent) -> Void

    init(strip: StripState, collapsible: Bool, send: @escaping (UIIntent) -> Void) {
        self.strip = strip
        self.collapsible = collapsible
        self.send = send
    }
    @Environment(\.mgColors) private var colors
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static func toggleID(_ kind: StripState.Kind) -> String { "strip.\(kind.rawValue)" }

    private var isOpen: Bool { !(collapsible && strip.isCollapsed) }

    /// The tiles under the card. With the sleep card on top the "Slept" tile is left out: the card says it first and larger.
    private var tiles: [LabeledValue] {
        strip.sleepCard == nil ? strip.items : strip.items.filter { $0.id != "slept" }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if isOpen {
                VStack(alignment: .leading, spacing: MGSpace.s) {
                    if let card = strip.sleepCard { SleepCardView(card: card, send: send) }   // sleep expanded, spec §A
                    ForEach(Array(TodayStripView.rows(tiles, oneColumn: typeSize.isAccessibilitySize)
                        .enumerated()), id: \.offset) { _, row in
                        HStack(alignment: .top, spacing: MGSpace.s) {
                            ForEach(row.items) { item in
                                StripTile(item: item, large: row.large, send: send)
                            }
                        }
                        .fixedSize(horizontal: false, vertical: true)   // equal heights within a row
                    }
                    if !tiles.isEmpty {
                        Text("tap a value to open it · hold it for its source")
                            .mgFont(.receipt)
                            .foregroundStyle(colors.mute.color)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .accessibilityHidden(true)    // each tile says it in its own hint
                    }
                    if let line = strip.recoveryLine {
                        Text(line)
                            .mgFont(.body)
                            .foregroundStyle(colors.ink2.color)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, MGSpace.xs)
                    }
                }
                .padding(.top, MGSpace.m)
                .transition(.opacity)
            }
        }
        .animation(MGMotion.expand(reduceMotion: reduceMotion), value: strip.isCollapsed)
    }

    @ViewBuilder
    private var header: some View {
        if collapsible {
            Button { send(.toggleRow(id: TodayStripView.toggleID(strip.kind))) } label: {
                // Title left, "since 12:00 AM · close" right; when that does not fit on one line it goes under
                // the title, so neither side ever wraps word by word.
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: MGSpace.s) {
                        title
                        Spacer(minLength: MGSpace.s)
                        note.lineLimit(1)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        title
                        note.fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: MGSpace.tapTarget, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityValue(strip.isCollapsed ? "closed" : "open")
            .accessibilityAddTraits(.isHeader)
        } else {
            SectionHeader(strip.title, note: strip.summary)
        }
    }

    private var title: some View {
        Text(strip.title).mgFont(.headline).foregroundStyle(colors.ink.color)
    }

    private var note: some View {
        Text([strip.summary, strip.isCollapsed ? "open ›" : "close"].compactMap { $0 }.joined(separator: " · "))
            .mgFont(.detail)
            .foregroundStyle(colors.ink2.color)
    }

    struct Row {
        var items: [LabeledValue]
        var large: Bool
    }

    /// Tiles in presenter order. The first two are large, side by side; the rest go three to a row, an item whose
    /// words need more room (long caption, long blank reason, a worded value) taking two or three of the three
    /// places, so a caption never wraps one word per line (T98). A short last row stretches to the full width.
    /// `oneColumn` (accessibility text sizes): one tile per row.
    static func rows(_ items: [LabeledValue], oneColumn: Bool) -> [Row] {
        if oneColumn { return items.enumerated().map { Row(items: [$0.element], large: $0.offset < 2) } }
        var rows = items.isEmpty ? [] : [Row(items: Array(items.prefix(2)), large: true)]
        var current: [LabeledValue] = []
        var used = 0
        for item in items.dropFirst(2) {
            let span = places(item)
            if used + span > 3, !current.isEmpty {
                rows.append(Row(items: current, large: false))
                current = []
                used = 0
            }
            current.append(item)
            used += span
        }
        if !current.isEmpty { rows.append(Row(items: current, large: false)) }
        return rows
    }

    /// How many of a row's three places an item needs. A third of the 353 pt content width holds about 13
    /// characters of 12 pt text per line, so a 2-line caption fits about 26; a value is about twice as wide per
    /// character, a blank reason may run to four lines.
    static func places(_ item: LabeledValue) -> Int {
        var need = max(item.label.count, item.caption?.count ?? 0)
        switch item.value {
        case let .value(text, unit, _, _, _): need = max(need, (text.count + (unit?.count ?? 0)) * 2)
        case let .blank(reason, _): need = max(need, reason.count / 2)
        }
        return need <= 26 ? 1 : (need <= 50 ? 2 : 3)
    }
}

/// One value on the tile surface: label, value with its meaning tag, caption. Tap → the item's own destination (or
/// the receipt when it has none); hold → its receipt. Fills its row's height so tiles in a row line up.
struct StripTile: View {
    let item: LabeledValue
    let large: Bool
    let send: (UIIntent) -> Void
    @Environment(\.mgColors) private var colors
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button { if let intent = tapIntent { send(intent) } } label: { tile }
            .buttonStyle(MGPressButtonStyle())
            .disabled(tapIntent == nil)
            .contextMenu {
                if let r = item.value.receipt {
                    Button { send(.showReceipt(r)) } label: { Label("Where this comes from", systemImage: "info.circle") }
                }
            }
            .accessibilityHint(item.intent != nil ? "Opens the details. Hold for its source." : "Shows its source")
    }

    private var tapIntent: UIIntent? {
        item.intent ?? item.value.receipt.map { .showReceipt($0) }
    }

    private var tile: some View {
        VStack(alignment: .leading, spacing: MGSpace.xs) {
            Text(item.label)
                .mgFont(.label)
                .foregroundStyle(colors.ink2.color)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            ValueView(item.value, size: large ? .big : StripTile.size(for: item.value))
                .contentTransition(.numericText())
                .animation(MGMotion.numeric(reduceMotion: reduceMotion), value: item.value)
            // SpO₂ before the per-strap check: the byte read as "≈ 96 % estimate" (CLAUDE.md rule 4 exception).
            // ValueView leaves a raw value's unit out, so it shows here, under the byte — only when it carries
            // its "estimate" label (raw counts are never shown as a unit).
            if case let .value(_, unit?, _, .strapRaw, _) = item.value, unit.contains("estimate") {
                Text(unit)
                    .mgFont(.label)
                    .foregroundStyle(colors.ink2.color)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let caption = item.caption {
                Text(caption)
                    .mgFont(.label)
                    .foregroundStyle(colors.ink2.color)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(MGSpace.tileInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .frame(minHeight: large ? 88 : 72)
        .mgSurface(.tile)
        .contentShape(RoundedRectangle(cornerRadius: MGRadius.tile, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    /// Words ("in range", "✓ 7:15 AM") get the word size so they fit a third of the width.
    static func size(for value: DisplayValue) -> ValueSize {
        guard case let .value(text, _, _, _, _) = value else { return .number }
        let wordy = text.contains { $0.isLetter } || text.count > 5
        return wordy ? .small : .number
    }
}
