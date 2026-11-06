import SwiftUI
import MGContext
import MGDesign

// r9q (Oct 17 2026): the in-app "Workout? Yes / No" card, shown over the tab bar while the raw streams are on for a workout
// that looks likely. The same question goes out as a notification when the app is not in front. Pure rendering: the answers
// go through `send(.autoRaw(.answerWorkout(...)))`.
//
// WRITTEN, NOT COMPILED.

struct AutoWorkoutPromptCard: View {
    let prompt: AutoWorkoutPrompt
    let answer: (Bool) -> Void
    @Environment(\.mgColors) private var colors

    var body: some View {
        VStack(alignment: .leading, spacing: MGSpace.s) {
            Text(prompt.title)
                .mgFont(.rowTitle)
                .foregroundStyle(colors.ink.color)
            Text(prompt.body)
                .mgFont(.body)
                .foregroundStyle(colors.ink2.color)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: MGSpace.s) {
                MGButton("Yes") { answer(true) }
                MGButton("No", style: .ghost) { answer(false) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(MGSpace.l)
        .background(RoundedRectangle(cornerRadius: 24, style: .continuous).fill(colors.sheet.color))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(colors.rule.color, lineWidth: 1))
        .mgShadow(.raised)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Workout question")
    }
}
