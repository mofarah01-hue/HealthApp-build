import SwiftUI
import MGContext
import MGDesign
import MGDomain

/// What Mo tapped in the Symptom row.
enum LogSymptomPick: Hashable {
    /// Bristol 1…7, shown in plain words.
    case stool(Int)
    case gut(SymptomFields.Kind)
    case swallowing(String)
    case headache
    case groan
    case breathHold
    case other
}

/// Symptom, opened in place (UX §7, APP-081): stool in plain words (stored as Bristol), gut 0–3 (bloating, pain,
/// urgency, nausea), swallowing (hard swallow, pain, food sticking), headache, groan / breath-hold, other.
/// Descriptions say what the shape looks like; the app never judges ("normal", "constipated") and gives no advice.
struct LogSymptomForm: View {
    let ctx: LogFormContext

    init(ctx: LogFormContext) {
        self.ctx = ctx
    }
    @Environment(\.mgColors) private var colors
    @Environment(\.calendar) private var calendar
    @State private var pick: LogSymptomPick?
    @State private var severity: Int?
    @State private var otherText = ""
    @State private var when = LogHappenedAt()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Group {
                LogFormLabel("Stool")
                FlowLayout(spacing: 8, lineSpacing: 8) {
                    ForEach(LogVocabulary.stool) { choice in
                        pickChip(choice.label, .stool(choice.bristol))
                    }
                }
                if case .stool(let bristol) = pick, let choice = LogVocabulary.stool.first(where: { $0.bristol == bristol }) {
                    LogHint("\(choice.label): \(choice.plain) · Bristol \(choice.bristol)")
                }
            }

            Group {
                LogFormLabel("Gut, 0–3")
                FlowLayout(spacing: 8, lineSpacing: 8) {
                    ForEach(LogVocabulary.gut) { item in
                        pickChip(item.label, .gut(item.kind))
                    }
                }
            }

            Group {
                LogFormLabel("Swallowing")
                FlowLayout(spacing: 8, lineSpacing: 8) {
                    ForEach(LogVocabulary.swallowing, id: \.self) { word in
                        pickChip(word, .swallowing(word))
                    }
                }
                FlowLayout(spacing: 8, lineSpacing: 8) {
                    pickChip("headache", .headache)
                    pickChip("groan", .groan)
                    pickChip("breath-hold", .breathHold)
                    pickChip("other…", .other)
                }
            }

            if pick == .other {
                LogTextField("What was it", text: $otherText)
            }
            if asksSeverity {
                LogFormLabel(needsSeverity ? "How strong, 0–3" : "How strong, 0–3 (optional)")
                LogChoiceChips(options: LogVocabulary.severityWords.enumerated().map { (id: $0.offset, label: "\($0.offset) \($0.element)") },
                               selection: $severity, clearable: !needsSeverity)
            }

            LogHappenedAtControl(choice: $when, title: "Happened · minutes ago")
            LogSaveBar(title: "Log it", enabled: ctx.canLog && problem == nil, reason: reason, action: save)
        }
        .keepsDraft($otherText, row: ctx.row.id, field: "other")
    }

    // MARK: Picking

    private func pickChip(_ label: String, _ value: LogSymptomPick) -> some View {
        Chip(label, selected: pick == value) {
            if pick != value { severity = nil }
            pick = value
        }
    }

    private var needsSeverity: Bool {
        if case .gut = pick { return true }
        return false
    }

    private var asksSeverity: Bool {
        if needsSeverity { return true }
        return pick == .headache
    }

    /// nil = ready; otherwise what is missing.
    private var problem: String? {
        guard let pick else { return "Pick what you felt." }
        switch pick {
        case .gut:
            return severity == nil ? "Pick how strong, 0–3." : nil
        case .other:
            return LogText.clean(otherText) == nil ? "Say what it was." : nil
        default:
            return nil
        }
    }

    private var reason: String? { ctx.canLog ? problem : LogIntents.sampleReason }

    // MARK: Save

    private func save() {
        guard ctx.canLog, problem == nil, let pick else { return }
        let now = Date()
        let at = when.resolved(now: now, calendar: calendar)
        let event: EventRecord
        let title: String
        switch pick {
        case .stool(let bristol):
            guard let choice = LogVocabulary.stool.first(where: { $0.bristol == bristol }) else { return }
            event = LogEvents.stool(choice, at: at, loggedAt: now)
            title = "Stool · \(choice.label)"
        case .gut(let kind):
            let label = LogVocabulary.gut.first(where: { $0.kind == kind })?.label ?? kind.rawValue
            event = LogEvents.symptom(kind: kind, severity: severity, detail: nil, at: at, loggedAt: now)
            title = "\(label.capitalized) · \(LogVocabulary.severityWords[min(3, max(0, severity ?? 0))])"
        case .swallowing(let word):
            event = LogEvents.symptom(kind: .swallowing, severity: nil, detail: word, at: at, loggedAt: now)
            title = "Swallowing · \(word)"
        case .headache:
            event = LogEvents.symptom(kind: .headache, severity: severity, detail: nil, at: at, loggedAt: now)
            title = "Headache"
        case .groan:
            event = LogEvents.symptom(kind: .groan, severity: nil, detail: nil, at: at, loggedAt: now)
            title = "Groan"
        case .breathHold:
            event = LogEvents.symptom(kind: .breathHold, severity: nil, detail: nil, at: at, loggedAt: now)
            title = "Breath-hold"
        case .other:
            event = LogEvents.symptom(kind: .other, severity: nil, detail: LogText.clean(otherText), at: at, loggedAt: now)
            title = "Symptom"
        }
        ctx.commit([event], message: "\(title) logged \(LogText.time(at, calendar))")
    }
}
