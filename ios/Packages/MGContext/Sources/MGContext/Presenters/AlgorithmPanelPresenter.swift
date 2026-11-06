import Foundation
import MGDomain

/// Copy shown after tapping an ALG-/MS- label. All model-specific words come from the generated ModelCatalogue and
/// GroupCatalogue; the presenter only joins those catalogue fields into the questions the panel answers.
public struct PanelExplanation: Equatable, Sendable {
    public var id: String
    public var simple: String
    public var technical: String
    public var inputs: String
    public var computation: String
    public var meaning: String
    public var unit: String
    public var source: String
    public var blank: String

    public init(id: String, simple: String, technical: String, inputs: String, computation: String, meaning: String,
                unit: String, source: String, blank: String) {
        self.id = id
        self.simple = simple
        self.technical = technical
        self.inputs = inputs
        self.computation = computation
        self.meaning = meaning
        self.unit = unit
        self.source = source
        self.blank = blank
    }
}

public struct PanelMetricState: Equatable, Sendable, Identifiable {
    public var id: String
    public var label: String
    public var value: DisplayValue
    public var explanation: PanelExplanation

    public init(id: String, label: String, value: DisplayValue, explanation: PanelExplanation) {
        self.id = id
        self.label = label
        self.value = value
        self.explanation = explanation
    }
}

public struct AlgorithmPanelOption: Equatable, Sendable, Identifiable {
    public var id: String
    public var label: String
    public var explanation: PanelExplanation
    public var metrics: [PanelMetricState]
    public var note: String?
    /// True when this option is a member of the panel's comparison group, so picking it saves the group's "read this
    /// one" mark. False = the pick is only local to the panel (a mark for a non-member would leave no chip as read).
    public var savesChoice: Bool

    public init(id: String, label: String, explanation: PanelExplanation, metrics: [PanelMetricState],
                note: String? = nil, savesChoice: Bool = true) {
        self.id = id
        self.label = label
        self.explanation = explanation
        self.metrics = metrics
        self.note = note
        self.savesChoice = savesChoice
    }
}

/// State for MGDesign's shared expandable panel + algorithm dropdown. Selection is supplied by settings; passing nil
/// uses the catalogue's display default without silently rewriting the setting.
public struct AlgorithmPanelState: Equatable, Sendable {
    public var sample: Bool
    public var title: String
    public var summary: String
    public var selectedID: String
    public var options: [AlgorithmPanelOption]
    public var note: String?

    public init(sample: Bool, title: String, summary: String, selectedID: String,
                options: [AlgorithmPanelOption], note: String? = nil) {
        self.sample = sample
        self.title = title
        self.summary = summary
        self.selectedID = selectedID
        self.options = options
        self.note = note
    }

    public var selected: AlgorithmPanelOption? { options.first { $0.id == selectedID } }
}

/// T30: one catalogue-backed explainer for every algorithm id and every registry metric id.
public enum AlgorithmExplainerPresenter {
    static let algorithmIDs: [String] = {
        let requirements = ModelCatalogue.requirements.map(\.id)
        let variants = ModelCatalogue.registry.flatMap(\.variants)
            + GroupCatalogue.all.flatMap { $0.members.map(\.variant) }
        return Array(Set(requirements + variants.compactMap(modelID))).sorted()
    }()

    static let metricIDs: [String] = Array(Set((ModelCatalogue.registry + ModelCatalogue.importOnly).map(\.name))).sorted()

    /// An ALG-/MS- id may arrive as a variant (`ALG-031:A`, `MS-18:import`) or inside a method string.
    static func modelID(_ text: String) -> String? {
        for prefix in ["ALG-", "MS-"] {
            guard let start = text.range(of: prefix) else { continue }
            let digits = text[start.upperBound...].prefix { $0.isNumber }
            if !digits.isEmpty { return prefix + digits }
        }
        return nil
    }

    public static func algorithm(_ id: String, metric: Metric? = nil) -> PanelExplanation? {
        guard let base = modelID(id) else { return nil }
        let requirement = ModelCatalogue.requirements.first { $0.id == base }
        let member = GroupCatalogue.all.flatMap(\.members).first {
            modelID($0.variant) == base || modelID($0.codename ?? "") == base
        }
        let registry = ModelCatalogue.registry.filter { row in row.variants.contains { modelID($0) == base } }
        guard requirement != nil || member != nil || !registry.isEmpty else { return nil }

        let names = Array(Set(registry.map(\.name))).sorted()
        let windows = Array(Set(registry.flatMap(\.windows))).sorted()
        let simple = requirement?.what ?? member?.label ?? names.joined(separator: ", ")
        let technical = names.isEmpty ? simple : names.joined(separator: ", ")
        let inputs = windows.isEmpty ? simple : windows.joined(separator: ", ")
        let computation: String
        if base.hasPrefix("MS-"), let label = member?.label {
            computation = "Our method, inspired by \(label); not a copy."
        } else {
            computation = requirement?.what ?? member?.label ?? simple
        }
        let meaning = [names.joined(separator: ", "), member?.scaleNote].compactMap(nonempty).joined(separator: " · ")
        let unit = unitText(metric, fallback: member?.scaleNote)
        let source = nonempty(metric?.citation) ?? nonempty(requirement?.codeProof)
            ?? ["ModelCatalogue", member == nil ? nil : "GroupCatalogue"].compactMap { $0 }.joined(separator: " · ")
        return PanelExplanation(id: base, simple: simple, technical: technical, inputs: inputs,
                                computation: computation, meaning: meaning.isEmpty ? simple : meaning, unit: unit,
                                source: source, blank: blankReason(metric, requirement: requirement, windows: windows))
    }

    public static func metric(_ id: String, metric: Metric? = nil) -> PanelExplanation? {
        // T9720 bug 21 (2026-10-14): a name written only by an import (Apple rings, stand, daylight, body measures)
        // used to return nil here, so the panel dropped it silently.
        if ModelCatalogue.registry.first(where: { $0.name == id }) == nil,
           let row = ModelCatalogue.importOnly.first(where: { $0.name == id }) {
            let from = row.importVariants.map { ImportedHistory.memberLabel($0) ?? $0 }.joined(separator: ", ")
            let windows = row.windows.joined(separator: ", ")
            return PanelExplanation(id: id, simple: id.replacingOccurrences(of: "_", with: " "),
                                    technical: row.importVariants.joined(separator: ", "), inputs: windows,
                                    computation: "Imported from \(from): that app's own value, not computed by us.",
                                    meaning: id.replacingOccurrences(of: "_", with: " "), unit: unitText(metric),
                                    source: nonempty(metric?.citation) ?? from,
                                    blank: blankReason(metric, requirement: nil, windows: row.windows))
        }
        guard let row = ModelCatalogue.registry.first(where: { $0.name == id }) else { return nil }
        let variants = row.variants.joined(separator: ", ")
        let windows = row.windows.joined(separator: ", ")
        let model = row.variants.compactMap(modelID).first
            .flatMap { key in ModelCatalogue.requirements.first { $0.id == key } }
        let source = nonempty(metric?.citation) ?? nonempty(model?.codeProof) ?? "ModelCatalogue"
        let meaning = row.group.flatMap { GroupCatalogue.group($0)?.title } ?? id
        return PanelExplanation(id: id, simple: id.replacingOccurrences(of: "_", with: " "),
                                technical: variants, inputs: windows, computation: model?.what ?? variants,
                                meaning: meaning, unit: unitText(metric),
                                source: source, blank: blankReason(metric, requirement: model, windows: row.windows))
    }

    static func imported(id: String, label: String, metrics: [Metric?], formulaUnpublished: Bool) -> PanelExplanation {
        let present = metrics.compactMap { $0 }
        let names = Array(Set(present.map(\.name))).sorted()
        let units = Array(Set(present.map(\.unit).filter { !$0.isEmpty })).sorted()
        let citations = Array(Set(present.compactMap { nonempty($0.citation) })).sorted()
        let blank = present.first(where: { $0.value == nil })?.note ?? "No result stored for this method yet."
        return PanelExplanation(
            id: id,
            simple: label,
            technical: names.isEmpty ? label : names.joined(separator: ", "),
            inputs: label,
            computation: formulaUnpublished ? "The formula is unpublished; this is the exported value." : label,
            meaning: names.isEmpty ? label : names.joined(separator: ", "),
            unit: units.isEmpty ? "Stored with the result" : units.joined(separator: ", "),
            source: citations.isEmpty ? label : citations.joined(separator: ", "),
            blank: blank
        )
    }

    static func blankReason(_ metric: Metric?, requirement: ModelCatalogue.Requirement?, windows: [String]) -> String {
        if let note = metric?.note, !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return note }
        if metric?.value != nil { return "This result is not blank." }
        if let blocked = requirement?.blockedOn { return "Needs \(blocked)." }
        if let requirement, requirement.codeProof == nil { return ModelStatusPresenter.notBuiltState(requirement) }
        if windows.isEmpty { return "No result stored for this method yet." }
        return "No result stored for this method yet. Data window: \(windows.joined(separator: ", "))."
    }

    static func nonempty(_ text: String?) -> String? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Raw sensor counts are never presented as a unit: T30's prose labels them just as ValueView labels the number.
    static func unitText(_ metric: Metric?, fallback: String? = nil) -> String {
        if metric?.unit == "raw_div_100" { return "°C · decoded, untested" }
        if let metric, MetricText.isRaw(metric) {
            return "decoded, untested · raw value, not a unit"
        }
        if let fallback = nonempty(fallback), fallback.localizedCaseInsensitiveContains("raw") {
            return "decoded, untested · " + fallback
        }
        return nonempty(metric?.unit) ?? nonempty(fallback) ?? "Stored with the result"
    }
}

// MARK: - Shared panel construction

struct PanelOptionSpec {
    struct MetricSpec {
        var name: String
        var variant: String
        var label: String?
        var window: String?
    }

    var id: String
    var label: String
    var metrics: [MetricSpec]
    var note: String?
    var imported: Bool
    var formulaUnpublished: Bool

    init(_ id: String, _ label: String, metrics: [(String, String)], window: String? = nil, note: String? = nil,
         imported: Bool = false, formulaUnpublished: Bool = false) {
        self.id = id
        self.label = label
        self.metrics = metrics.map { MetricSpec(name: $0.0, variant: $0.1, label: nil, window: window) }
        self.note = note
        self.imported = imported
        self.formulaUnpublished = formulaUnpublished
    }
}

enum AlgorithmPanelBuilder {
    static func make(_ snapshot: PresenterSnapshot, title: String, summary: String, defaultID: String,
                     selectedID: String?, specs: [PanelOptionSpec], note: String? = nil,
                     groupID: String? = nil) -> AlgorithmPanelState {
        let options = specs.compactMap { option(snapshot, $0, groupID: groupID) }
        let available = Set(options.map(\.id))
        let selected = selectedID.flatMap { available.contains($0) ? $0 : nil }
            ?? (available.contains(defaultID) ? defaultID : options.first?.id ?? defaultID)
        return AlgorithmPanelState(sample: snapshot.sample, title: title, summary: summary, selectedID: selected,
                                   options: options, note: note)
    }

    static func option(_ snapshot: PresenterSnapshot, _ spec: PanelOptionSpec,
                       groupID: String?) -> AlgorithmPanelOption? {
        let found = spec.metrics.map { snapshot.metric($0.name, variant: $0.variant, window: $0.window) }
        let explanation: PanelExplanation?
        if spec.imported {
            explanation = AlgorithmExplainerPresenter.imported(id: spec.id, label: spec.label, metrics: found,
                                                                formulaUnpublished: spec.formulaUnpublished)
        } else {
            explanation = AlgorithmExplainerPresenter.algorithm(spec.id, metric: found.compactMap { $0 }.first)
        }
        guard let explanation else { return nil }
        let metrics = zip(spec.metrics, found).compactMap { metricSpec, metric -> PanelMetricState? in
            guard let metricExplanation = AlgorithmExplainerPresenter.metric(metricSpec.name, metric: metric) else {
                return nil
            }
            return PanelMetricState(id: metricSpec.name + "|" + metricSpec.variant,
                                    label: metricSpec.label ?? metricLabel(metricSpec.name),
                                    value: snapshot.display(metric, missing: explanation.blank),
                                    explanation: metricExplanation)
        }
        let savesChoice = groupID.map { GroupCatalogue.member($0, spec.id) != nil } ?? true
        return AlgorithmPanelOption(id: spec.id, label: spec.label, explanation: explanation, metrics: metrics,
                                    note: spec.note, savesChoice: savesChoice)
    }

    static func metricLabel(_ name: String) -> String {
        let acronyms: Set<String> = ["hrv", "rmssd", "sdnn", "rem", "waso"]
        return name.split(separator: "_").enumerated().map { index, word in
            let text = String(word)
            if acronyms.contains(text) { return text.uppercased() }
            return index == 0 ? text.prefix(1).uppercased() + String(text.dropFirst()) : text
        }.joined(separator: " ")
    }
}
