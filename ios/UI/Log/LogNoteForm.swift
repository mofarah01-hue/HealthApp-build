import SwiftUI
import MGContext
import MGDesign
import MGDomain

/// Note, opened in place (UX §7, APP-086): free text, tags, time. Photo / file attachments need the attachment store
/// (not in this build) and are shown disabled with the reason.
struct LogNoteForm: View {
    let ctx: LogFormContext

    init(ctx: LogFormContext) {
        self.ctx = ctx
    }
    @Environment(\.mgColors) private var colors
    @Environment(\.calendar) private var calendar
    @State private var text = ""
    @State private var tagText = ""
    @State private var when = LogHappenedAt()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            LogFormLabel("Note")
            TextField(text: $text, prompt: Text("What do you want to remember?").foregroundStyle(colors.mute.color),
                      axis: .vertical) {
                Text("Note")
            }
            .mgFont(.body)
            .foregroundStyle(colors.ink.color)
            .lineLimit(3...8)
            .padding(12)
            .frame(minHeight: 88, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: MGRadius.chip, style: .continuous).fill(colors.chip.color))

            LogTextField("Tags, separated by commas", text: $tagText)

            LogHappenedAtControl(choice: $when)
            LogSaveBar(title: "Save note", enabled: ctx.canLog && LogText.clean(text) != nil,
                       reason: ctx.canLog ? "Write something first." : LogIntents.sampleReason, action: save)
        }
        .keepsDraft($text, row: ctx.row.id, field: "text")
        .keepsDraft($tagText, row: ctx.row.id, field: "tags")
    }

    private func save() {
        guard ctx.canLog, let body = LogText.clean(text) else { return }
        let now = Date()
        let at = when.resolved(now: now, calendar: calendar)
        let event = LogEvents.journal(text: body, tags: LogText.tags(tagText), at: at, loggedAt: now)
        ctx.commit([event], message: "Note saved \(LogText.time(at, calendar))")
    }
}
