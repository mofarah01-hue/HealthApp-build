import SwiftUI
import MGContext
import MGDomain

/// One comparison group, quiet (UX §11, Vernier). ARCHITECTURE §4.8: `MethodsStrip(state:send:)`.
///
/// Collapsed: "Recovery · 5 methods" + "open ›", a 3-band strip with one tick per member placed on its OWN bands'
/// thirds (bold tick = the method Mo reads), one caption — about 36 pt. Groups with no shared band scale show one
/// values line instead ("**Ours A 7 h 08** · Deep model 7 h 14 · …").
/// Open: one row per member — radio (read this) · name + codename · its value on its own scale · band chip · rank ·
/// receipt · dotted research tag. Long-press or "⋯": Read this one · Keep · Drop (hides, never deletes) · About.
/// Expansion is state-driven: tapping sends `.toggleMethods(groupId:)`.
public struct MethodsStrip: View {
    @Environment(\.mgColors) private var colors
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let state: MethodsStripState
    private let send: (UIIntent) -> Void

    public init(state: MethodsStripState, send: @escaping (UIIntent) -> Void) {
        self.state = state
        self.send = send
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                send(.toggleMethods(groupId: state.groupId))
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    headerLine
                    if state.valuesLineOnly {
                        valuesLine
                    } else {
                        BandStrip(members: state.members, colors: colors)
                            .frame(height: 22)
                            .accessibilityHidden(true)
                    }
                    if !state.caption.isEmpty {
                        Text(state.caption)
                            .mgFont(.detail)
                            .foregroundStyle(colors.ink2.color)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(collapsedAccessibilityLabel)
            .accessibilityValue(state.isExpanded ? "open" : "closed")
            .accessibilityHint(state.isExpanded ? "Closes the methods" : "Shows every method side by side")

            if state.isExpanded {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(state.members.enumerated()), id: \.element.id) { index, member in
                        memberRow(member, first: index == 0)
                    }
                    footer
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 4)
                .mgSurface(.card, radius: MGRadius.card)
                .padding(.top, 6)
                .transition(.opacity)
            }
        }
        .padding(.vertical, 10)
        .animation(MGMotion.expand(reduceMotion: reduceMotion), value: state.isExpanded)
    }

    // MARK: collapsed

    private var headerLine: some View {
        let parts = state.title.components(separatedBy: " · ")
        let name = parts.first ?? state.title
        let rest = parts.dropFirst().joined(separator: " · ")
        return HStack(alignment: .firstTextBaseline) {
            (Text(name).fontWeight(.semibold).foregroundColor(colors.ink.color)
             + Text(rest.isEmpty ? "" : " · \(rest)").foregroundColor(colors.ink2.color))
                .mgFont(.detail)
            Spacer(minLength: 8)
            Text(state.isExpanded ? "close" : "open ›")
                .mgFont(.detail)
                .foregroundStyle(colors.ink.color)
        }
    }

    private var valuesLine: some View {
        var line = Text("")
        for (i, m) in state.members.enumerated() {
            if i > 0 { line = line + Text(" · ").foregroundColor(colors.ink2.color) }
            let piece = Text("\(m.label) \(MethodsStrip.shortValue(m.value))")
            line = line + (m.isRead ? piece.fontWeight(.semibold).foregroundColor(colors.ink.color)
                                    : piece.foregroundColor(colors.ink2.color))
        }
        return line.mgFont(.detail).fixedSize(horizontal: false, vertical: true)
    }

    private var collapsedAccessibilityLabel: String {
        var s = state.title
        if let read = state.readMember {
            s += ". Reading \(read.label), \(MethodsStrip.shortValue(read.value))"
        }
        if !state.caption.isEmpty { s += ". " + state.caption }
        return s
    }

    /// "7 h 08" / "51 /100" / "—".
    static func shortValue(_ v: DisplayValue) -> String {
        switch v {
        case let .value(text, unit, _, style, _):
            if case .strapRaw = style { return text }
            return [text, unit].compactMap { $0 }.joined(separator: " ")
        case .blank: return "—"
        }
    }

    // MARK: open

    private func memberRow(_ m: MethodMember, first: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Button {
                send(.selectMethod(groupId: state.groupId, variant: m.variant))
            } label: {
                Circle()
                    .strokeBorder(m.isRead ? colors.ink.color : colors.ink2.color, lineWidth: m.isRead ? 5 : 1.5)
                    .frame(width: 16, height: 16)
                    .frame(width: 44, height: 44, alignment: .top)
                    .padding(.top, 2)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(m.isRead ? "\(m.label), the method you read" : "Read \(m.label)")
            .accessibilityAddTraits(m.isRead ? .isSelected : [])

            // Bug 15 (round 2, 2026-10-14, M-143): the name opens that member's own detail (MS-18 was unreachable).
            // r8h E5: the receipt is its own 44 pt Button, not nested in the open Button.
            VStack(alignment: .leading, spacing: 0) {
                Button {
                    send(MethodsStrip.openIntent(groupId: state.groupId, member: m))
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 4) {
                            Text(m.label).mgFont(.rowTitle).foregroundStyle(colors.ink.color)
                            if m.isResearch { ResearchTag() }
                            Image(systemName: "chevron.right")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(colors.mute.color)
                                .accessibilityHidden(true)
                        }
                        Text([m.codename, m.rank.map { "rank \($0)" }].compactMap { $0 }.joined(separator: " · "))
                            .mgFont(.receipt)
                            .foregroundStyle(colors.ink2.color)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
                .accessibilityHint("Opens \(m.label)")
                if let r = m.value.receipt { ReceiptLabel(r) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 2) {
                MemberValueView(m.value, size: .small)
                HStack(spacing: 4) {
                    if let b = m.bandIndex, !m.value.isBlank {
                        RoundedRectangle(cornerRadius: 2).fill(bandColor(b).color).frame(width: 9, height: 9)
                            .accessibilityLabel(["bottom band", "middle band", "top band"][min(max(b, 0), 2)])
                    }
                    if let note = m.scaleNote {
                        Text(note).mgFont(.receipt).foregroundStyle(colors.ink2.color)
                    }
                }
                Menu {
                    menuItems(m)
                } label: {
                    Image(systemName: "ellipsis")
                        .foregroundStyle(colors.ink2.color)
                        .frame(width: 44, height: 44, alignment: .trailing)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("More for \(m.label)")
            }
        }
        .padding(.vertical, 10)
        .overlay(alignment: .top) {
            if !first { Rectangle().fill(colors.rule.color).frame(height: 1) }
        }
        .contextMenu { menuItems(m) }
    }

    /// Where tapping a member row goes: that member's own metric detail (name + variant); the group's About when
    /// the member's metric name is not known.
    public static func openIntent(groupId: String, member m: MethodMember) -> UIIntent {
        m.name.isEmpty ? .openGroup(groupId: groupId) : .openMetric(key: m.name, variant: m.variant)
    }

    @ViewBuilder
    private func menuItems(_ m: MethodMember) -> some View {
        Button("Read this one") { send(.selectMethod(groupId: state.groupId, variant: m.variant)) }
        Button("Open") { send(MethodsStrip.openIntent(groupId: state.groupId, member: m)) }
        Button("Keep") { send(.markMethod(groupId: state.groupId, variant: m.variant, mark: .keep)) }
        Button("Drop (hides, never deletes)") {
            send(.markMethod(groupId: state.groupId, variant: m.variant, mark: .drop))
        }
        Button("About") { send(.openGroup(groupId: state.groupId)) }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let a = state.agreement {
                Text(a).mgFont(.detail).foregroundStyle(colors.ink2.color).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("All methods") { send(.openGroup(groupId: state.groupId)) }
                    .mgFont(.detail)
                    .foregroundStyle(colors.ink.color)
                    .underline()
                    .frame(minHeight: MGSpace.tapTarget)
                Spacer()
                if state.droppedCount > 0 {
                    Button("Show dropped (\(state.droppedCount))") { send(.showDropped(groupId: state.groupId)) }
                        .mgFont(.detail)
                        .foregroundStyle(colors.ink.color)
                        .frame(minHeight: MGSpace.tapTarget)
                }
            }
        }
        .padding(.top, 6)
        .overlay(alignment: .top) { Rectangle().fill(colors.rule.color).frame(height: 1) }
    }

    private func bandColor(_ index: Int) -> MGRGBA {
        switch index {
        case 0: return colors.bandLow
        case 1: return colors.bandMid
        default: return colors.bandHigh
        }
    }
}

/// The three-band strip with one tick per member (prototype `mstrip`).
struct BandStrip: View {
    let members: [MethodMember]
    let colors: ThemeColors

    var body: some View {
        Canvas { ctx, size in
            let w = size.width
            let third = w / 3
            let bands: [MGRGBA] = [colors.bandLow, colors.bandMid, colors.bandHigh]
            for i in 0..<3 {
                let rect = CGRect(x: CGFloat(i) * third + (i == 0 ? 0 : 1.5), y: 12, width: third - 3, height: 6)
                ctx.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(bands[i].color))
            }
            // Ticks: position 0…1 when the presenter gives one; else the middle of the member's band.
            // Read tick last so it draws on top.
            let ordered = members.filter { !$0.isRead } + members.filter { $0.isRead }
            for m in ordered {
                guard !m.value.isBlank else { continue }
                let pos: Double
                if let p = m.position {
                    pos = min(max(p, 0), 1)
                } else if let b = m.bandIndex {
                    pos = (Double(min(max(b, 0), 2)) + 0.5) / 3
                } else {
                    continue
                }
                let x = CGFloat(pos) * w
                var tick = Path()
                tick.move(to: CGPoint(x: x, y: m.isRead ? 2 : 7))
                tick.addLine(to: CGPoint(x: x, y: 21))
                ctx.stroke(tick, with: .color((m.isRead ? colors.ink : colors.ink2).color),
                           style: StrokeStyle(lineWidth: m.isRead ? 2.6 : 1.3, lineCap: .round))
            }
        }
    }
}

/// A member's value in a group row (bug 15, round 2, 2026-10-14, M-142): a number shows as `ValueView` does; a blank
/// shows "—" and a "why ›" link, and its reason opens only on tap (it used to print in full on every row). The reason
/// is never dropped: it is one tap away and VoiceOver reads it in full.
public struct MemberValueView: View {
    @Environment(\.mgColors) private var colors
    @State private var showsReason = false
    private let value: DisplayValue
    private let size: ValueSize

    public init(_ value: DisplayValue, size: ValueSize = .number) {
        self.value = value
        self.size = size
    }

    public var body: some View {
        switch value {
        case .value:
            ValueView(value, size: size)
        case let .blank(reason, _):
            VStack(alignment: .trailing, spacing: 2) {
                Button {
                    showsReason.toggle()
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("—").mgFont(size.style).foregroundStyle(colors.mute.color)
                        Text(showsReason ? "hide" : "why ›").mgFont(.receipt).foregroundStyle(colors.ink2.color)
                    }
                    .frame(minHeight: 28)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("No value. \(reason)")
                .accessibilityHint(showsReason ? "Hides the reason" : "Shows why it is blank")
                if showsReason {
                    Text(reason)    // a sentence: sans, never mono
                        .mgFont(.detail)
                        .foregroundStyle(colors.ink2.color)
                        .multilineTextAlignment(.trailing)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 220, alignment: .trailing)
                }
            }
        }
    }
}
