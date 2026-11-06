import SwiftUI
import MGContext
import MGDesign
import MGDomain

/// Sleepy & check-in, opened in place (UX §7, APP-061): Karolinska Sleepiness Scale 1–9 with its meanings on the
/// buttons, energy / focus / mood 1–5, and the 3-minute reaction test (APP-062).
struct LogSleepyForm: View {
    let ctx: LogFormContext

    init(ctx: LogFormContext) {
        self.ctx = ctx
    }
    @Environment(\.mgColors) private var colors
    @Environment(\.calendar) private var calendar
    @State private var kss: Int?
    @State private var energy: Int?
    @State private var focus: Int?
    @State private var mood: Int?
    @State private var when = LogHappenedAt()

    private var scaleOptions: [(id: Int, label: String)] { (1...5).map { (id: $0, label: "\($0)") } }
    private var hasAnswer: Bool { kss != nil || energy != nil || focus != nil || mood != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            LogFormLabel("Sleepiness, 1–9")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8, alignment: .top), count: 3), spacing: 8) {
                ForEach(1...9, id: \.self) { value in
                    kssButton(value)
                }
            }
            if let kss, let words = LogVocabulary.kssFull[kss] {
                LogHint("\(kss) · \(words)")
            }

            Group {
                scaleRow("Energy, 1–5", selection: $energy)
                scaleRow("Focus, 1–5", selection: $focus)
                scaleRow("Mood, 1–5", selection: $mood)
                LogHint("1 very low · 2 low · 3 middle · 4 high · 5 very high")
            }

            LogHappenedAtControl(choice: $when)
            LogSaveBar(title: "Save check-in", enabled: ctx.canLog && hasAnswer,
                       reason: ctx.canLog ? "Pick at least one answer." : LogIntents.sampleReason, action: save)

            VStack(alignment: .leading, spacing: 8) {
                Divider().overlay(colors.rule.color)
                LogFormLabel("Reaction test")
                MGButton("Reaction test, 3 min", style: .ghost) { ctx.send(LogIntents.startReactionTest) }
                    .disabled(!ctx.canLog)
                    .opacity(ctx.canLog ? 1 : 0.4)
                LogHint(ctx.canLog ? "Tap as fast as you can for 3 minutes. False starts are shown." : LogIntents.sampleReason)
            }
        }
    }

    private func kssButton(_ value: Int) -> some View {
        let selected = kss == value
        return Button {
            kss = selected ? nil : value
        } label: {
            VStack(spacing: 2) {
                Text("\(value)")
                    .mgFont(.number)
                    .foregroundStyle(selected ? colors.buttonText.color : colors.ink.color)
                Text(LogVocabulary.kssShort[value] ?? "")
                    .mgFont(.receipt)
                    .foregroundStyle(selected ? colors.buttonText.color : colors.ink2.color)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, minHeight: 64)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: MGRadius.chip, style: .continuous)
                .fill(selected ? colors.buttonFill.color : colors.chip.color))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(value), \(LogVocabulary.kssFull[value] ?? "")")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func scaleRow(_ title: String, selection: Binding<Int?>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            LogFormLabel(title)
            LogChoiceChips(options: scaleOptions, selection: selection)
        }
    }

    private func save() {
        guard ctx.canLog, hasAnswer else { return }
        let now = Date()
        let at = when.resolved(now: now, calendar: calendar)
        let event = LogEvents.checkin(kss: kss, energy: energy, focus: focus, mood: mood, at: at, loggedAt: now)
        let message = kss.map { "KSS \($0) saved \(LogText.time(at, calendar))" } ?? "Check-in saved \(LogText.time(at, calendar))"
        ctx.commit([event], message: message)
    }
}
