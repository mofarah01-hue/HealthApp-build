import SwiftUI
import MGContext
import MGDesign
import MGDomain

/// More › What are you doing? (T129): the activity label, saved as an `activity_label` event and kept as local
/// training data for the later model. Nothing is sent anywhere.
struct LogActivityForm: View {
    let ctx: LogFormContext

    init(ctx: LogFormContext) {
        self.ctx = ctx
    }
    @Environment(\.calendar) private var calendar
    @State private var kind: ActivityKind?
    @State private var note = ""
    @State private var minutes: Double = 30
    @State private var when = LogHappenedAt()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            LogFormLabel("What are you doing?")
            LogChoiceChips(options: ActivityKind.allCases.map { (id: $0, label: $0.word) }, selection: $kind)
            LogTextField("Note (optional)", text: $note)
            LogStepperRow(title: "For", valueText: "\(Int(minutes)) min", value: $minutes, range: 5...480, step: 5)
            LogHappenedAtControl(choice: $when, title: "Started · minutes ago")
            LogHint("Saved on this phone as training data for the push-or-relax suggestion. Nothing is sent anywhere.")
            LogSaveBar(title: "Save", enabled: ctx.canLog && kind != nil,
                       reason: ctx.canLog ? "Pick what you are doing." : LogIntents.sampleReason, action: save)
        }
        .keepsDraft($note, row: ctx.row.id, field: "note")
    }

    private func save() {
        guard ctx.canLog, let kind else { return }
        let now = Date()
        let start = when.resolved(now: now, calendar: calendar)
        let label = ActivityLabel(kind: kind, at: start, end: start.addingTimeInterval(minutes * 60), note: LogText.clean(note))
        ctx.commit([label.event(loggedAt: now)], message: "\(kind.word) saved \(LogText.time(start, calendar))")
    }
}
