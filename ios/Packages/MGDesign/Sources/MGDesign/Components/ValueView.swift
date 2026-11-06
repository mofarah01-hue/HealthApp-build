import SwiftUI
import MGContext
import MGDomain

// ValueView and ReceiptLabel — UX rule 4 (every value carries a quiet receipt; measured values underlined,
// estimates carry ±, research rows wear a dotted tag) and UX §13 (blank with a reason, never a fake number).

private struct MGNowKey: EnvironmentKey {
    static let defaultValue: Date? = nil
}

extension EnvironmentValues {
    /// The screen's "now" (from its state). When set, a receipt from an earlier day reads "PC · from Thu 9 Oct" (UX §13).
    public var mgNow: Date? {
        get { self[MGNowKey.self] }
        set { self[MGNowKey.self] = newValue }
    }
}

/// `where · tier · when` in small mono, `mute` ink (ARCHITECTURE §4.8: `ReceiptLabel(_ receipt: Receipt)`).
public struct ReceiptLabel: View {
    @Environment(\.mgColors) private var colors
    @Environment(\.mgNow) private var now
    @Environment(\.calendar) private var calendar
    @Environment(\.mgSend) private var send
    private let receipt: Receipt

    public init(_ receipt: Receipt) {
        self.receipt = receipt
    }

    /// A tap opens the receipt in full (method, tier, where, when, citation — `.showReceipt`, wave 2; before, only a
    /// long-press on a value showed it).
    public var body: some View {
        let text = receipt.text(calendar: calendar, now: now)
        // r8h E5: its own Button with a 44 pt target (was an onTapGesture ~12 pt tall).
        Button { send(.showReceipt(receipt)) } label: {
            Text(text)
                .mgFont(.receipt)
                .foregroundStyle(colors.mute.color)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(ReceiptLabel.spoken(text))
        .accessibilityHint("Shows where this number comes from")
    }

    /// "phone · high · 06:52" → "phone, high, 06:52" (VoiceOver reads the middle dot badly).
    static func spoken(_ text: String) -> String {
        text.replacingOccurrences(of: " · ", with: ", ")
    }
}

/// A receipt plus an optional free-text note on one quiet line: "phone · high · 06:58 · 4 of 5 inputs in range".
/// Shows nothing when both are nil.
public struct ReceiptLine: View {
    @Environment(\.mgColors) private var colors
    @Environment(\.mgNow) private var now
    @Environment(\.calendar) private var calendar
    private let receipt: Receipt?
    private let note: String?

    public init(receipt: Receipt?, note: String?) {
        self.receipt = receipt
        self.note = note
    }

    public var body: some View {
        let parts = [receipt.map { $0.text(calendar: calendar, now: now) }, note].compactMap { $0 }
        if !parts.isEmpty {
            let text = parts.joined(separator: " · ")
            Text(text)
                .mgFont(.receipt)
                .foregroundStyle(colors.mute.color)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel(ReceiptLabel.spoken(text))
        }
    }
}

/// Sizes a value can be drawn at.
public enum ValueSize: Sendable {
    /// Live HR (96 pt).
    case hero
    /// Metric detail, dial hub (28 pt).
    case big
    /// Vitals, rows (22 pt). Default.
    case number
    /// A value that is words ("in range") or sits in a tight grid (15 pt).
    case small
    /// Inside a sentence-sized line (body, 15 pt regular).
    case inline

    var style: MGTextStyle {
        switch self {
        case .hero: return .heroNumber
        case .big: return .bigNumber
        case .number: return .number
        case .small: return .wordValue
        case .inline: return .body
        }
    }

    var underlineThickness: CGFloat {
        switch self {
        case .hero: return 4
        case .big: return 2.5
        default: return 2
        }
    }
}

/// One `DisplayValue` (ARCHITECTURE §4.8: `ValueView(_ value: DisplayValue, size: ValueSize = .number)`).
///
/// - `.value` + `.measured`   → underlined (cuff, scale, lab, CGM)
/// - `.value` + `.estimate`   → "±" after the unit, with the half-width when the uncertainty is known
/// - `.value` + `.research`   → dotted "research" tag
/// - `.value` + `.strapRaw`   → no unit sign, a small "raw" mark (raw counts are not units)
/// - `.value` + `.plain`      → nothing extra
/// - `.blank(reason, _)`      → "—" plus the reason (never a number)
/// Long-press shows the receipt in full (method, tier, computed on, at, citation — UX §10).
/// The meaning tag (est. / ± / raw / research) always sits next to the value; the one-line receipt is hidden unless
/// `showsReceipt` is set (it opens from a tap or long-press instead).
public struct ValueView: View {
    @Environment(\.mgColors) private var colors
    @Environment(\.mgNow) private var now
    @Environment(\.calendar) private var calendar
    @Environment(\.mgSend) private var send
    private let value: DisplayValue
    private let size: ValueSize
    private let showsReceipt: Bool

    public init(_ value: DisplayValue, size: ValueSize = .number, showsReceipt: Bool = false) {
        self.value = value
        self.size = size
        self.showsReceipt = showsReceipt
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            switch value {
            case let .value(text, unit, receipt, style, _):
                valueLine(text: text, unit: unit, style: style)
                if showsReceipt { ReceiptLabel(receipt) }
            case let .blank(reason, receipt):
                Text("—")
                    .mgFont(size.style)
                    .foregroundStyle(colors.mute.color)
                Text(reason)    // a sentence: sans, never mono
                    .mgFont(.detail)
                    .foregroundStyle(colors.ink2.color)
                    .fixedSize(horizontal: false, vertical: true)
                if showsReceipt, let receipt { ReceiptLabel(receipt) }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        // r8h E5: the value reads as one element, so the receipt is an action on it, not a lost button.
        .accessibilityAction(named: "Show where this comes from") {
            if let r = value.receipt { send(.showReceipt(r)) }
        }
        .contextMenu {
            if let r = value.receipt { receiptMenu(r) }
        }
    }

    @ViewBuilder
    private func valueLine(text: String, unit: String?, style: DisplayValue.Style) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(text)
                .mgFont(size.style)
                .foregroundStyle(colors.ink.color)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .overlay(alignment: .bottom) {
                    if case .measured = style {
                        Rectangle()
                            .fill(colors.ink.color)
                            .frame(height: size.underlineThickness)
                            .offset(y: size.underlineThickness + 1)
                    }
                }
            if let unit, !unit.isEmpty, !ValueView.isRaw(style) {
                Text(unit)
                    .mgFont(.unit)
                    .foregroundStyle(colors.ink2.color)
            }
            switch style {
            case .estimate(let u):
                Text(EstimateMark.text(u, valueText: text))
                    .mgFont(.unit)
                    .foregroundStyle(colors.ink2.color)
            case .research:
                ResearchTag()
            case .strapRaw:
                TagPill(text: "raw")
            case .measured, .plain:
                EmptyView()
            }
        }
    }

    @ViewBuilder
    private func receiptMenu(_ r: Receipt) -> some View {
        Text("\(r.originText) · tier \(r.tier.rawValue)")
        Text("At \(r.text(calendar: calendar, now: now).components(separatedBy: " · ").last ?? "")")
        if let m = r.method { Text("Method: \(m)") }
        if let c = r.citation { Text("Source: \(c)") }
    }

    static func isRaw(_ style: DisplayValue.Style) -> Bool {
        if case .strapRaw = style { return true }
        return false
    }

    private var accessibilityText: String {
        switch value {
        case let .value(text, unit, receipt, style, sample):
            var parts: [String] = []
            let unitSpoken = (unit.map { ValueView.isRaw(style) ? "" : " \($0)" }) ?? ""
            parts.append(text + unitSpoken)
            switch style {
            case .measured: parts.append("measured")
            case .estimate(let u):
                parts.append(EstimateMark.spoken(u, valueText: text))
            case .research: parts.append("research method")
            case .strapRaw: parts.append("raw strap value, not a unit")
            case .plain: break
            }
            if sample { parts.append("sample") }
            if showsReceipt { parts.append(ReceiptLabel.spoken(receipt.text(calendar: calendar, now: now))) }
            return parts.joined(separator: ", ")
        case let .blank(reason, _):
            return "No value. \(reason)"
        }
    }
}
