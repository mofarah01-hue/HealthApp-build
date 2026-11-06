import SwiftUI
import MGContext
import MGDesign

/// What opens when a ring, mark or arc on the Sundial is tapped (0.6, package P04). Built only from one `DialDetail`:
/// top to bottom the ring switcher (ring sheets only), the header (kicker, serif title, value with its meaning tag,
/// sentence), up to two small charts on tiles, labelled rows, the related items, the blank reason, and the actions
/// that already exist. Every intent goes through `\.mgSend`; an action also closes the sheet.
struct DialDetailSheet: View {
    let detail: DialDetail
    /// The other ring sheets (empty for marks and arcs).
    let siblings: [DialDetail]
    let select: (DialTarget) -> Void

    init(detail: DialDetail, siblings: [DialDetail], select: @escaping (DialTarget) -> Void) {
        self.detail = detail
        self.siblings = siblings
        self.select = select
    }

    @Environment(\.mgColors) private var colors
    @Environment(\.mgSend) private var send
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MGSpace.xl) {
                if siblings.count > 1 { switcher }
                header
                ForEach(Array(detail.visuals.enumerated()), id: \.offset) { _, visual in
                    DialDetailVisualView(visual: visual, color: markColor, centreText: detail.title,
                                         dashed: ringKind == .eaten)
                        .padding(MGSpace.tileInset)
                        .frame(maxWidth: .infinity)
                        .mgSurface(.tile)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(detail.visualSummary ?? "")
                }
                if !detail.rows.isEmpty { rows }
                if !detail.items.isEmpty { items }
                if let reason = detail.blankReason { blank(reason) }
                if !detail.actions.isEmpty { actions }
            }
            .padding(.horizontal, MGSpace.gutter)
            .padding(.vertical, MGSpace.xl)
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(colors.sheet.color.ignoresSafeArea())
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(MGRadius.sheet)
        .presentationBackground(colors.sheet.color)
    }

    // MARK: Colour

    private var ringKind: DialRing.Kind? {
        if case .ring(let kind) = detail.id { return kind }
        return nil
    }

    /// Marks and lines: the ring's colour for ring sheets, else the tone's.
    private var markColor: MGRGBA { ringKind.map(colors.ring) ?? colors.mark(detail.tone) }

    /// Text in the accent: the ring's or tone's TEXT colour (contrast-checked).
    private var accentText: MGRGBA { ringKind.map(colors.ringText) ?? colors.text(detail.tone) }

    // MARK: 1. Ring switcher

    private var switcher: some View {
        // The selected chip scrolls into view (six rings do not fit the width; audit #18).
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: MGSpace.s) {
                    ForEach(Array(siblings.enumerated()), id: \.element.id) { i, sibling in
                        let on = sibling.id == detail.id
                        Button { select(sibling.id) } label: {
                            HStack(spacing: 6) {
                                ConcentricRingsIcon(count: siblings.count, highlighted: i, colors: siblingColors)
                                Text(Self.ringName(sibling.id))
                                    .mgFont(.button)
                                    .foregroundStyle((on ? colors.buttonText : colors.ink).color)
                            }
                            .padding(.horizontal, 14)
                            .frame(minHeight: MGSpace.tapTarget)
                            .background(Capsule().fill((on ? colors.buttonFill : colors.chip).color))
                            .contentShape(Capsule())
                        }
                        .buttonStyle(MGPressButtonStyle())
                        .accessibilityLabel("\(Self.ringName(sibling.id)) details")
                        .accessibilityAddTraits(on ? .isSelected : [])
                        .id(sibling.id)
                    }
                }
            }
            .onAppear { proxy.scrollTo(detail.id, anchor: .center) }
            .onChange(of: detail.id) { _, new in
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(new, anchor: .center) }
            }
        }
    }

    private var siblingColors: [Color] {
        siblings.map { s in
            if case .ring(let kind) = s.id { return colors.ring(kind).color }
            return colors.mark(s.tone).color
        }
    }

    static func ringName(_ target: DialTarget) -> String {
        guard case .ring(let kind) = target else { return "" }
        switch kind {
        case .strain: return "Strain"
        case .recovery: return "Recovery"
        case .sleep: return "Sleep"
        case .stress: return "Body arousal"
        case .burn: return "Burned"
        case .eaten: return "Eaten"
        }
    }

    // MARK: 2. Header

    private var header: some View {
        VStack(alignment: .leading, spacing: MGSpace.s) {
            Text(detail.kicker)
                .mgFont(.kicker)
                .foregroundStyle(accentText.color)
            Text(detail.title)
                .mgFont(.sheetTitle)
                .foregroundStyle(colors.ink.color)
                .fixedSize(horizontal: false, vertical: true)
            // Tags always visible; the receipt opens on a long-press (ValueView's menu).
            if let value = detail.value { ValueView(value, size: .small) }
            if let sentence = detail.sentence {
                Text(sentence)
                    .mgFont(.body)
                    .foregroundStyle(colors.ink2.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    // MARK: 4. Rows

    private var rows: some View {
        VStack(spacing: 0) {
            ForEach(Array(detail.rows.enumerated()), id: \.element.id) { i, row in
                if i > 0 { hairline }
                if let intent = row.intent {
                    Button { send(intent) } label: { rowContent(row, chevron: true) }
                        .buttonStyle(MGPressButtonStyle())
                } else {
                    rowContent(row, chevron: false)
                }
            }
        }
    }

    private func rowContent(_ row: LabeledValue, chevron: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: MGSpace.m) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.label)
                    .mgFont(.body)
                    .foregroundStyle(colors.ink2.color)
                    .fixedSize(horizontal: false, vertical: true)
                if let caption = row.caption {
                    Text(caption).mgFont(.detail).foregroundStyle(colors.mute.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: MGSpace.m)
            ValueView(row.value, size: .small)
                .multilineTextAlignment(.trailing)
            if chevron { Self.chevron(colors) }
        }
        .padding(.vertical, MGSpace.m)
        .frame(minHeight: MGSpace.tapTarget)
        .contentShape(Rectangle())
    }

    // MARK: 5. Items

    private var items: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title = detail.itemsTitle {
                SectionHeader(title)
                    .padding(.top, -MGSpace.xl)    // the stack already leaves 24
            }
            ForEach(Array(detail.items.enumerated()), id: \.element.id) { i, item in
                if i > 0 { hairline }
                if let intent = item.intent {
                    Button { send(intent) } label: { itemContent(item, chevron: true) }
                        .buttonStyle(MGPressButtonStyle())
                } else {
                    itemContent(item, chevron: false)
                }
            }
        }
    }

    private func itemContent(_ item: DialDetailItem, chevron: Bool) -> some View {
        HStack(spacing: MGSpace.m) {
            // The selected item (the mark that was tapped) wears a bar in the tone colour; "this one" is also spoken.
            RoundedRectangle(cornerRadius: 1.5)
                .fill(item.isSelected ? markColor.color : Color.clear)
                .frame(width: 3)
                .padding(.vertical, 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .mgFont(.rowTitle)
                    .foregroundStyle(colors.ink.color)
                    .fixedSize(horizontal: false, vertical: true)
                if let d = item.detail {
                    Text(d).mgFont(.detail).foregroundStyle(colors.ink2.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: MGSpace.s)
            if let t = item.trailing {
                Text(t).mgFont(.detail).foregroundStyle(colors.ink2.color)
            }
            if chevron { Self.chevron(colors) }
        }
        .frame(minHeight: MGSpace.rowMinHeight)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityValue(item.isSelected ? "this one" : "")
    }

    // MARK: 6. Blank

    private func blank(_ reason: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: MGSpace.s) {
            Text("—").mgFont(.number).foregroundStyle(colors.mute.color)
            Text(reason)
                .mgFont(.body)
                .foregroundStyle(colors.ink2.color)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("No value. \(reason)")
    }

    // MARK: 7. Actions

    private var actions: some View {
        VStack(spacing: MGSpace.s) {
            ForEach(Array(detail.actions.enumerated()), id: \.element.id) { i, action in
                VStack(spacing: MGSpace.xs) {
                    Button {
                        if let intent = action.intent { send(intent) }
                        dismiss()
                    } label: {
                        Text(action.title)
                            .mgFont(.button)
                            .foregroundStyle((i == 0 ? colors.buttonText : colors.ink).color)
                            .frame(maxWidth: .infinity, minHeight: i == 0 ? 48 : MGSpace.tapTarget)
                            .background(Capsule().fill((i == 0 ? colors.buttonFill : colors.chip).color))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(MGPressButtonStyle())
                    .disabled(!action.enabled || action.intent == nil)
                    .opacity(action.enabled ? 1 : 0.45)
                    if !action.enabled, let why = action.disabledReason {
                        Text(why)
                            .mgFont(.detail)
                            .foregroundStyle(colors.ink2.color)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(.top, MGSpace.xs)
    }

    // MARK: Parts

    private var hairline: some View {
        Rectangle().fill(colors.rule.color).frame(height: 1)
    }

    static func chevron(_ colors: ThemeColors) -> some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(colors.mute.color)
            .accessibilityHidden(true)
    }
}
