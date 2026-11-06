import SwiftUI
import MGContext

/// The one-question card (UX §5): a bottom peek above the tab bar with a handle, the question in `headline`, one
/// row of answers. Swipe down (or "Later") = `.deferPeek` — it becomes a "1 question" chip in the header.
/// ARCHITECTURE §4.8: `PeekCard(state:send:)`. The caller places it and handles the 1.2 s entrance delay.
///
/// Answer layouts: a KSS-style question (answers carry a meaning in `detail`) → equal columns, number over meaning;
/// a long default answer ("Left wrist — same as before") → one full-width filled button first; otherwise one
/// wrapping row, defaults filled.
public struct PeekCard: View {
    @Environment(\.mgColors) private var colors
    @GestureState private var drag: CGFloat = 0
    private let state: PeekState
    private let send: (UIIntent) -> Void

    public init(state: PeekState, send: @escaping (UIIntent) -> Void) {
        self.state = state
        self.send = send
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Capsule()
                .fill(colors.rule.color)
                .frame(width: 38, height: 5)
                .frame(maxWidth: .infinity)
                .padding(.bottom, 10)
                .accessibilityHidden(true)

            HStack(alignment: .firstTextBaseline) {
                Text(state.question)
                    .mgFont(.headline)
                    .foregroundStyle(colors.ink.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                if state.stepCount > 1 {
                    Spacer(minLength: 6)
                    Text("\(state.step) of \(state.stepCount)")
                        .mgFont(.receipt)
                        .foregroundStyle(colors.mute.color)
                }
            }

            answers.padding(.top, 12)

            HStack {
                if let title = state.secondaryTitle, let intent = state.secondaryIntent {
                    Button(title) { send(intent) }
                        .mgFont(.detail)
                        .foregroundStyle(colors.ink2.color)
                        .underline()
                        .frame(minHeight: MGSpace.tapTarget)
                }
                Spacer()
                Button("Later") { send(.deferPeek(state.kind)) }
                    .mgFont(.detail)
                    .foregroundStyle(colors.ink2.color)
                    .underline()
                    .frame(minHeight: MGSpace.tapTarget)
                    .accessibilityHint("Keeps the question as a chip at the top of Today")
            }
            .padding(.top, 4)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .mgSurface(.peek, radius: MGRadius.peek, shadow: true)
        .offset(y: max(0, drag))
        .gesture(
            DragGesture(minimumDistance: 8)
                .updating($drag) { value, out, _ in out = value.translation.height }
                .onEnded { value in
                    if value.translation.height > 40 { send(.deferPeek(state.kind)) }
                }
        )
        .accessibilityElement(children: .contain)
        .accessibilityAction(.escape) { send(.deferPeek(state.kind)) }
    }

    @ViewBuilder
    private var answers: some View {
        if state.answers.contains(where: { $0.detail != nil }) {
            // KSS 1–9 with the meaning on the buttons (UX §5.2).
            HStack(spacing: 4) {
                ForEach(state.answers) { a in
                    Button { send(a.intent) } label: {
                        VStack(spacing: 1) {
                            Text(a.title).mgFont(.button)
                            if let d = a.detail {
                                Text(d)
                                    .mgFont(MGTextStyle(family: .sans, size: 8, lineHeight: 9, weight: .regular,
                                                        relativeTo: .caption2, maxScale: 1.5))
                                    .multilineTextAlignment(.center)
                                    .lineLimit(2)
                                    .minimumScaleFactor(0.8)
                            }
                        }
                        .foregroundStyle(a.isDefault ? colors.buttonText.color : colors.ink.color)
                        .frame(maxWidth: .infinity, minHeight: 46)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(a.isDefault ? colors.buttonFill.color : colors.chip.color))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(a.detail.map { "\(a.title), \($0)" } ?? a.title)
                }
            }
        } else {
            let wide = state.answers.filter { $0.isDefault && $0.title.count > 18 }
            VStack(alignment: .leading, spacing: 8) {
                ForEach(wide) { a in
                    answerButton(a).frame(maxWidth: .infinity)
                }
                FlowLayout(spacing: 6, lineSpacing: 6) {
                    ForEach(state.answers.filter { a in !wide.contains(where: { $0.id == a.id }) }) { a in
                        answerButton(a)
                    }
                }
            }
        }
    }

    private func answerButton(_ a: PeekAnswer) -> some View {
        Button { send(a.intent) } label: {
            Text(a.title)
                .mgFont(.button)
                .foregroundStyle(a.isDefault ? colors.buttonText.color : colors.ink.color)
                .padding(.horizontal, 12)
                .frame(minWidth: 56, maxWidth: .infinity, minHeight: MGSpace.tapTarget)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(a.isDefault ? colors.buttonFill.color : colors.chip.color))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
