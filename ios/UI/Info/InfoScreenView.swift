import SwiftUI
import MGContext
import MGDesign

// A plain read-out screen (W10, 2026-10-11): "Your ages" and the three Live research screens. Pure rendering of
// `InfoScreenState`; rows with an intent open it, actions send theirs, the optional text field sends `textIntent`.

struct InfoScreenView: View {
    let state: InfoScreenState
    let send: (UIIntent) -> Void
    var textIntent: ((String) -> UIIntent)?
    /// r8h U1: set when the screen is shown as a sheet; adds a Done button.
    var onDone: (() -> Void)?
    @State private var text = ""
    @Environment(\.mgColors) private var colors

    init(state: InfoScreenState, send: @escaping (UIIntent) -> Void, textIntent: ((String) -> UIIntent)? = nil,
         onDone: (() -> Void)? = nil) {
        self.state = state
        self.send = send
        self.textIntent = textIntent
        self.onDone = onDone
    }

    var body: some View {
        MGScreen {
            VStack(alignment: .leading, spacing: 0) {
                if let onDone {
                    HStack {
                        Spacer(minLength: 0)
                        MGButton("Done", style: .ghost, action: onDone)
                    }
                    .padding(.top, 8)
                }
                header
                    .padding(.top, 12)
                    .padding(.bottom, 6)
                if let prompt = state.textPrompt, let textIntent {
                    HStack(spacing: 8) {
                        TextField(prompt, text: $text)
                            .textFieldStyle(.roundedBorder)
                            .submitLabel(.go)
                            .onSubmit { start(textIntent) }
                        MGButton("Start", style: .filled) { start(textIntent) }
                    }
                    .padding(.vertical, 8)
                }
                if !state.actions.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(state.actions) { a in
                            MGButton(a.title, style: .ghost) { if let i = a.intent { send(i) } }
                                .disabled(!a.enabled)
                                .opacity(a.enabled ? 1 : 0.55)
                            if !a.enabled, let why = a.disabledReason { LogHint(why) }
                        }
                    }
                    .padding(.vertical, 8)
                }
                ForEach(state.sections) { section in
                    SettingsSection(section.title, note: section.note) {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(section.rows) { row in rowView(row) }
                        }
                    }
                }
            }
            .padding(.bottom, 48)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if state.sample { SampleBanner() }
        }
    }

    private func start(_ make: (String) -> UIIntent) {
        let label = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty else { return }
        send(make(label))
        text = ""
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(state.kicker)
                .mgFont(.kicker)
                .foregroundStyle(colors.topText.color)
            Text(state.title)
                .mgFont(.title)
                .foregroundStyle(colors.ink.color)
                .accessibilityAddTraits(.isHeader)
            if let summary = state.summary {
                Text(summary)
                    .mgFont(.detail)
                    .foregroundStyle(colors.ink2.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private func rowView(_ row: InfoScreenState.Row) -> some View {
        let content = VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(row.title)
                    .mgFont(.rowTitle)
                    .foregroundStyle(colors.ink.color)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                if let v = row.value {
                    Text(v).mgFont(.rowTitle).foregroundStyle(colors.ink.color)
                }
                if row.intent != nil {
                    Text("›").mgFont(.rowTitle).foregroundStyle(colors.ink2.color)
                }
            }
            ForEach(Array(row.lines.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .mgFont(.detail)
                    .foregroundStyle(colors.ink2.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) { Rectangle().fill(colors.rule.color).frame(height: 1) }
        .accessibilityElement(children: .combine)

        if let intent = row.intent {
            Button { send(intent) } label: { content.contentShape(Rectangle()) }
                .buttonStyle(.plain)
                .frame(minHeight: MGSpace.tapTarget)
        } else {
            content
        }
    }
}
