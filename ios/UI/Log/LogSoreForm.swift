import SwiftUI
import MGContext
import MGDesign
import MGDomain

/// Sore or injured, opened in place (r9p, D-LOAD-WALK-2): a body area and how much it hurts, 0 to 10. Stored as a record event
/// (kind `soreness` or `injury`, `body_part`, `side`, `level`) and shown beside the load. The app gives no diagnosis and
/// makes no injury-risk claim from training load; this log is Mo's own input.
struct LogSoreForm: View {
    let ctx: LogFormContext

    init(ctx: LogFormContext) {
        self.ctx = ctx
    }
    @Environment(\.calendar) private var calendar
    @State private var kind: RecordFields.Kind? = .soreness
    @State private var area: String?
    @State private var otherArea = ""
    @State private var side: String?
    @State private var level: Double = 3
    @State private var note = ""
    @State private var when = LogHappenedAt()

    private static let areas = ["calf", "hamstring", "quad", "glute", "groin", "knee", "ankle", "foot", "hip", "lower back",
                                "upper back", "neck", "shoulder", "elbow", "wrist", "chest", "other"]
    private static let sides: [(id: String, label: String)] = [
        (id: "left", label: "left"), (id: "right", label: "right"), (id: "both", label: "both"),
    ]

    private var bodyPart: String? {
        guard let area else { return nil }
        return area == "other" ? LogText.clean(otherArea) : area
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            LogFormLabel("Which")
            LogChoiceChips(options: [(id: RecordFields.Kind.soreness, label: "sore"),
                                     (id: RecordFields.Kind.injury, label: "injured")],
                           selection: $kind, clearable: false)
            LogFormLabel("Where")
            LogChoiceChips(options: LogSoreForm.areas.map { (id: $0, label: $0) }, selection: $area)
            if area == "other" {
                LogTextField("Which part of the body", text: $otherArea)
            }
            LogChoiceChips(options: LogSoreForm.sides, selection: $side)
            LogStepperRow(title: "How much (0 none, 10 worst)", valueText: LogText.number(level), value: $level,
                          range: 0...10, step: 1)
            LogTextField("Anything to remember (optional)", text: $note)
            LogHappenedAtControl(choice: $when)
            LogSaveBar(title: "Save", enabled: ctx.canLog && kind != nil && bodyPart != nil,
                       reason: !ctx.canLog ? LogIntents.sampleReason : "Pick where it is.", action: save)
        }
        .keepsDraft($otherArea, row: ctx.row.id, field: "soreArea")
        .keepsDraft($note, row: ctx.row.id, field: "soreNote")
    }

    private func save() {
        guard let kind, let bodyPart else { return }
        let now = Date()
        let at = when.resolved(now: now, calendar: calendar)
        let event = LogEvents.sore(kind: kind, bodyPart: bodyPart, side: side.flatMap { RecordFields.Side(rawValue: $0) },
                                   level: Int(level.rounded()), text: LogText.clean(note), at: at, loggedAt: now)
        ctx.commit([event], message: "\(bodyPart) \(LogText.number(level))/10 logged \(LogText.time(at, calendar))")
    }
}
