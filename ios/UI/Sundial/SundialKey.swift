import SwiftUI
import MGContext
import MGDesign

/// The key under the dial (0.6; replaces the single legend line): the precise-tap-free route to every detail sheet,
/// for VoiceOver and big fingers.
/// - Row 1: one 44 pt chip per ring on, in ring order: the concentric icon with this ring lit, its name, its value in
///   the ring's text colour with unit and meaning tag ("—" when blank). More than 4 (or accessibility text sizes):
///   the row scrolls sideways, fading at the right edge.
/// - Row 2: one chip per mark kind present (`legendItems`), its glyph tinted like the rim mark. Until the presenter
///   fills `legendItems`, the old legend line.
struct SundialKey: View {
    let state: DialState
    let open: (DialTarget) -> Void

    init(state: DialState, open: @escaping (DialTarget) -> Void) {
        self.state = state
        self.open = open
    }

    @Environment(\.mgColors) private var colors
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// calloutValue grown like a grid value (DESIGN-TOKENS §2: 2.0 outside the dial corners).
    static let chipValue = MGTextStyle.calloutValue.capped(2.0)

    var body: some View {
        VStack(alignment: .leading, spacing: MGSpace.s) {
            if !state.rings.isEmpty { ringRow }
            if state.legendItems.isEmpty {
                SundialLegend(text: state.legend)
            } else {
                FlowLayout(spacing: MGSpace.s, lineSpacing: MGSpace.s) {
                    ForEach(state.legendItems) { legendChip($0) }
                }
            }
        }
    }

    // MARK: Ring chips

    @ViewBuilder
    private var ringRow: some View {
        let rings = Array(state.rings.enumerated())
        if state.rings.count > 4 || dynamicTypeSize.isAccessibilitySize {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: MGSpace.s) {
                    ForEach(rings, id: \.element.kind) { i, ring in ringChip(i, ring, fill: false) }
                }
                .padding(.trailing, MGSpace.xl)
            }
            .mask {
                LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.88),
                                       .init(color: .clear, location: 1)],
                               startPoint: .leading, endPoint: .trailing)
            }
        } else {
            HStack(spacing: MGSpace.s) {
                ForEach(rings, id: \.element.kind) { i, ring in ringChip(i, ring, fill: true) }
            }
        }
    }

    private func ringChip(_ i: Int, _ ring: DialRing, fill: Bool) -> some View {
        Button { open(.ring(ring.kind)) } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    ConcentricRingsIcon(count: state.rings.count, highlighted: i,
                                        colors: state.rings.map { colors.ring($0.kind).color })
                    Text(ring.title)
                        .mgFont(.label)
                        .foregroundStyle(colors.ink2.color)
                        .lineLimit(1)
                }
                SundialValueLine(value: ring.value, style: Self.chipValue, color: colors.ringText(ring.kind))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(minWidth: fill ? nil : 96, maxWidth: fill ? .infinity : nil, minHeight: MGSpace.tapTarget,
                   alignment: .leading)
            .background(RoundedRectangle(cornerRadius: MGRadius.tile, style: .continuous).fill(colors.chip.color))
            .contentShape(RoundedRectangle(cornerRadius: MGRadius.tile, style: .continuous))
        }
        .buttonStyle(MGPressButtonStyle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.spoken(ring))
        .accessibilityAddTraits(.isButton)
    }

    /// "Strain 9.4 of 21, estimate. Opens details."
    static func spoken(_ ring: DialRing) -> String {
        if case let .blank(reason, _) = ring.value {
            return "\(ring.title), no value. \(reason) Opens details."
        }
        return "\(ring.title) \(SundialValueLine.spoken(ring.value)). Opens details."
    }

    // MARK: Mark chips

    private func legendChip(_ item: DialLegendItem) -> some View {
        Button { open(item.target) } label: {
            HStack(spacing: 6) {
                Text(item.glyph)
                    .mgFont(.detail)
                    .foregroundStyle((item.glyph.first.flatMap { SundialLegend.glyphColor($0, colors) }
                                      ?? colors.mark(item.tone)).color)
                Text(item.text)
                    .mgFont(.detail)
                    .foregroundStyle(colors.ink2.color)
                    .multilineTextAlignment(.leading)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(minHeight: MGSpace.tapTarget)
            .background(RoundedRectangle(cornerRadius: MGRadius.tile, style: .continuous).fill(colors.chip.color))
            .contentShape(RoundedRectangle(cornerRadius: MGRadius.tile, style: .continuous))
        }
        .buttonStyle(MGPressButtonStyle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(SundialLegend.spoken(item.glyph + " " + item.text)). Opens details.")
        .accessibilityAddTraits(.isButton)
    }
}

/// A value as the dial shows it: the number in `color`, its unit, and its meaning tag (est. / ± / raw / research),
/// measured values underlined; a blank is "—" (its reason lives in the sheet or the callout).
struct SundialValueLine: View {
    let value: DisplayValue
    let style: MGTextStyle
    let color: MGRGBA

    init(value: DisplayValue, style: MGTextStyle, color: MGRGBA) {
        self.value = value
        self.style = style
        self.color = color
    }

    @Environment(\.mgColors) private var colors

    var body: some View {
        switch value {
        case let .value(text, unit, _, s, _):
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(text)
                    .mgFont(style)
                    .foregroundStyle(color.color)
                    .underline(Self.isMeasured(s), color: color.color)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                if let unit, !unit.isEmpty, !Self.isRaw(s) {
                    Text(unit).mgFont(.unit).foregroundStyle(colors.ink2.color).lineLimit(1)
                }
                switch s {
                case .estimate(let u):
                    Text(EstimateMark.text(u, valueText: text)).mgFont(.unit).foregroundStyle(colors.ink2.color)
                case .research:
                    ResearchTag()
                case .strapRaw:
                    TagPill(text: "raw")
                case .measured, .plain:
                    EmptyView()
                }
            }
        case .blank:
            Text("—").mgFont(style).foregroundStyle(colors.mute.color)
        }
    }

    static func isMeasured(_ s: DisplayValue.Style) -> Bool {
        if case .measured = s { return true }
        return false
    }

    static func isRaw(_ s: DisplayValue.Style) -> Bool {
        if case .strapRaw = s { return true }
        return false
    }

    /// "9.4 of 21, estimate" · "62 bpm, measured" · "212, raw strap value, not a unit" · "no value".
    static func spoken(_ value: DisplayValue) -> String {
        guard case let .value(text, unit, _, style, sample) = value else { return "no value" }
        var head = text
        if let unit, !unit.isEmpty, !isRaw(style) {
            head += unit.hasPrefix("/") ? " of \(unit.dropFirst())" : " \(unit)"
        }
        var parts = [head]
        switch style {
        case .measured: parts.append("measured")
        case .estimate(let u): parts.append(EstimateMark.spoken(u, valueText: text))
        case .research: parts.append("research method")
        case .strapRaw: parts.append("raw strap value, not a unit")
        case .plain: break
        }
        if sample { parts.append("sample") }
        return parts.joined(separator: ", ")
    }
}

extension MGTextStyle {
    /// The same style with a different Dynamic Type cap.
    func capped(_ maxScale: CGFloat) -> MGTextStyle {
        MGTextStyle(family: family, size: size, lineHeight: lineHeight, weight: weight, relativeTo: relativeTo,
                    trackingEm: trackingEm, uppercase: uppercase, tabular: tabular, maxScale: maxScale)
    }
}
