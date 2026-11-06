import Foundation
import MGDomain

// Values the views render (ARCHITECTURE §4.7 table, UX rule 4 and §13). Views never touch services.

/// The quiet receipt under every value: `where · tier · when` (UX rule 4; contract metric computed_on, tier, at).
public struct Receipt: Equatable, Hashable, Sendable {
    public var computedOn: ComputedOn
    public var tier: Tier
    public var at: Date
    /// e.g. "ALG-036 rule coach" — shown in the long-press popover, not in the one-line text.
    public var method: String?
    public var citation: String?
    /// Imported history only: where the value came from ("WHOOP via Apple Health", "WHOOP export"); nil = ours.
    public var source: String?

    public init(computedOn: ComputedOn, tier: Tier, at: Date, method: String? = nil, citation: String? = nil,
                source: String? = nil) {
        self.computedOn = computedOn
        self.tier = tier
        self.at = at
        self.method = method
        self.citation = citation
        self.source = source
    }

    /// The popover's first line: "From strap data", "Ours, computed on the phone", "From WHOOP's numbers (imported on the PC)".
    public var originText: String {
        if source != nil { return "From \(whereText) (imported on the PC)" }
        switch computedOn {
        case .strap: return "From \(whereText)"
        case .phone: return "\(whereText.capitalizedFirst), computed on the phone"
        case .pc: return "\(whereText.capitalizedFirst), computed on the PC"
        }
    }

    /// Mo's four terms (r9v, UI-SCRUB L12): "strap data" (what the strap sent), "ours" (worked out by the phone or the PC
    /// Lab), "WHOOP's numbers" (WHOOP's own, from its export or via Apple Health), "Apple's numbers" (Apple Health / Watch).
    public var whereText: String {
        if let source { return Receipt.term(forSource: source) }
        switch computedOn {
        case .strap: return "strap data"
        case .phone, .pc: return "ours"
        }
    }

    /// The imported source name mapped to one of the four terms; anything the PC derived from past data is ours.
    static func term(forSource source: String) -> String {
        let s = source.lowercased()
        if s.contains("past data") { return "ours" }
        if s.contains("whoop") { return "WHOOP's numbers" }
        if s.contains("apple") { return "Apple's numbers" }
        return source
    }

    /// "phone · high · 06:52" in the phone's calendar.
    public var text: String { text(calendar: .current) }

    /// "phone · high · 06:52". With `now`, a value from an earlier day reads "PC · from Thu 9 Oct" (UX §13).
    public func text(calendar: Calendar, now: Date? = nil) -> String {
        // T29: "strap" place + "strap" tier is one word, not two ("strap · strap · 6:52 AM").
        // (r9v: "strap data" for the strap place; a strap-tier value still reads once.)
        let head = (computedOn == .strap && source == nil && tier == .strap) || whereText == tier.rawValue
            ? whereText : "\(whereText) · \(tier.rawValue)"
        if let now, !calendar.isDate(at, inSameDayAs: now) {
            return "\(head) · from \(MGFormat.shortDate(at, calendar: calendar))"
        }
        return "\(head) · \(MGFormat.time(at, calendar: calendar))"
    }
}

/// A number on screen, or a blank with its reason (R6, UX §13).
public enum DisplayValue: Equatable, Sendable {
    /// How the value is marked (UX rule 4).
    public enum Style: Equatable, Sendable {
        /// Cuff, scale, lab, CGM: underlined.
        case measured
        /// Carries ± (the uncertainty when known).
        case estimate(Uncertainty?)
        /// Dotted research tag.
        case research
        /// A raw strap count that is not a unit (SpO₂ byte, skin-temp raw): no unit sign (BRIEF "raw counts are not units").
        case strapRaw
        /// No decoration: high- or strap-tier values such as resting HR, HRV, strain (added with main's OK, 2026-10-11).
        case plain
    }

    case value(text: String, unit: String?, receipt: Receipt, style: Style, sample: Bool)
    case blank(reason: String, receipt: Receipt?)

    public var isBlank: Bool {
        if case .blank = self { return true }
        return false
    }

    /// true only for sample values (SAMPLE mode and previews).
    public var sample: Bool {
        if case let .value(_, _, _, _, s) = self { return s }
        return false
    }

    public var receipt: Receipt? {
        switch self {
        case let .value(_, _, r, _, _): return r
        case let .blank(_, r): return r
        }
    }

    /// The default style for a contract tier (verified → measured, estimate/relative → ±, research → tag, else plain).
    /// Raw strap counts must be marked `.strapRaw` by the caller; the tier alone can't tell.
    public static func style(for tier: Tier, uncertainty: Uncertainty? = nil) -> Style {
        switch tier {
        case .verified: return .measured
        case .estimate, .relative: return .estimate(uncertainty)
        case .research: return .research
        case .strap, .high: return .plain
        }
    }

    /// The style for a whole metric. T132 (app/docs/T-LIST-v2.md): a number WHOOP or Apple computed and the PC imported
    /// is that vendor's own unit, not our estimate, so it is plain (no "estimate", no "±"); ours on that history
    /// (`:import`) and the app's own values follow their tier.
    public static func style(for metric: Metric) -> Style {
        if ImportedHistory.isImported(metric), ImportedHistory.baseVariant(metric.variant) == nil { return .plain }
        return style(for: metric.tier, uncertainty: metric.uncertainty)
    }

    /// A metric as shown: blank with its note when the value is missing (R6), otherwise `format(value)` with its receipt.
    public static func from(_ metric: Metric, sample: Bool = false, style: Style? = nil,
                            format: (Double) -> String) -> DisplayValue {
        let receipt = Receipt(computedOn: metric.computedOn, tier: metric.tier, at: metric.at, method: metric.method,
                              citation: metric.citation, source: ImportedHistory.sourceLabel(metric))
        guard let v = metric.value, v.isFinite else {
            return .blank(reason: metric.note ?? "No value, and no reason recorded.", receipt: receipt)
        }
        return .value(text: format(v), unit: metric.unit.isEmpty ? nil : metric.unit, receipt: receipt,
                      style: style ?? Self.style(for: metric), sample: sample)
    }
}

/// The visible mark of an estimate. T132 (app/docs/T-LIST-v2.md): "±" only where a real interval exists; an estimate
/// with no stated spread reads "est." so it is still labelled (CLAUDE.md rule 4) without a bare "±".
public enum EstimateMark {
    /// What an estimate with no spread shows.
    public static let noSpread = "est."

    /// "±1.1" from the sd, else half the low–high width, else `noSpread`. Decimals follow the value text ("14.8" → 1).
    public static func text(_ u: Uncertainty?, valueText: String) -> String {
        var decimals = 0
        if let dot = valueText.firstIndex(of: ".") {
            decimals = valueText[valueText.index(after: dot)...].prefix(while: { $0.isNumber }).count
        }
        if let sd = u?.sd, sd.isFinite { return "±" + MGFormat.number(sd, decimals: decimals) }
        if let lo = u?.low, let hi = u?.high, lo.isFinite, hi.isFinite, hi >= lo {
            return "±" + MGFormat.number((hi - lo) / 2, decimals: decimals)
        }
        return noSpread
    }

    /// The spoken form: "estimate" or "estimate, plus or minus 1.1".
    public static func spoken(_ u: Uncertainty?, valueText: String) -> String {
        let mark = text(u, valueText: valueText)
        return mark == noSpread ? "estimate" : "estimate, plus or minus \(mark.dropFirst())"
    }
}

/// Semantic ink names (UX §1.2 tokens); MGDesign maps them to colours per theme.
public enum InkTone: String, Sendable, CaseIterable {
    case ink, ink2, mute, sleep, focus, caffeine, body, live
}

/// Status tones for dots and chips.
public enum StatusTone: String, Sendable, CaseIterable {
    /// green
    case good
    /// amber
    case warn
    /// red
    case bad
    /// grey
    case neutral
}

/// A labelled action (button) with the reason it is disabled, if it is.
public struct ActionState: Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var intent: UIIntent?
    public var enabled: Bool
    /// Shown under a disabled action ("No known command starts an awake reading").
    public var disabledReason: String?

    public init(id: String, title: String, intent: UIIntent?, enabled: Bool = true, disabledReason: String? = nil) {
        self.id = id
        self.title = title
        self.intent = intent
        self.enabled = enabled
        self.disabledReason = disabledReason
    }
}

/// A switch row ("Smart wake", "Listen tonight").
public struct ToggleState: Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var detail: String?
    public var isOn: Bool
    public var enabled: Bool
    public var disabledReason: String?
    /// Sent with the new value.
    public var intent: UIIntent

    public init(id: String, title: String, detail: String? = nil, isOn: Bool, enabled: Bool = true,
                disabledReason: String? = nil, intent: UIIntent) {
        self.id = id
        self.title = title
        self.detail = detail
        self.isOn = isOn
        self.enabled = enabled
        self.disabledReason = disabledReason
        self.intent = intent
    }
}

/// One labelled value in a list or grid.
public struct LabeledValue: Equatable, Sendable, Identifiable {
    public var id: String
    public var label: String
    public var value: DisplayValue
    public var caption: String?
    public var intent: UIIntent?

    public init(id: String, label: String, value: DisplayValue, caption: String? = nil, intent: UIIntent? = nil) {
        self.id = id
        self.label = label
        self.value = value
        self.caption = caption
        self.intent = intent
    }
}
