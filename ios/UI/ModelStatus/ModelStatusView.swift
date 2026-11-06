import SwiftUI
import MGContext
import MGDesign

// Model status (Mo 2026-10-11: "if something isn't working I should know … all models should be working"). Pure
// rendering of `ModelStatusState`: every registry metric with its model ids and every ALG id of the requirements, with
// today's state. Reached from Today's "N models not running ›" line and from Settings › Model status. A registry row
// opens its metric.

struct ModelStatusView: View {
    let state: ModelStatusState
    let send: (UIIntent) -> Void

    init(state: ModelStatusState, send: @escaping (UIIntent) -> Void) {
        self.state = state
        self.send = send
    }
    @Environment(\.mgColors) private var colors

    var body: some View {
        MGScreen {
            VStack(alignment: .leading, spacing: 0) {
                header
                    .padding(.top, 12)
                    .padding(.bottom, 6)
                ForEach(state.sections) { section in
                    SettingsSection(section.title, note: "\(section.rows.count)") {
                        VStack(alignment: .leading, spacing: 0) {
                            if let note = section.note { LogHint(note).padding(.vertical, 4) }
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

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Settings")          // U3: the parent's name
                .mgFont(.kicker)
                .foregroundStyle(colors.topText.color)
            Text("Model status")
                .mgFont(.title)
                .foregroundStyle(colors.ink.color)
                .accessibilityAddTraits(.isHeader)
            Text(state.summary)
                .mgFont(.detail)
                .foregroundStyle(colors.ink2.color)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private func rowView(_ row: ModelStatusState.Row) -> some View {
        let content = VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(row.title)
                    .mgFont(.rowTitle)
                    .foregroundStyle(colors.ink.color)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                if row.intent != nil {
                    Text("›").mgFont(.rowTitle).foregroundStyle(colors.ink2.color)
                }
            }
            Text(row.state)
                .mgFont(.detail)
                .foregroundStyle(row.kind == .hasOutput ? colors.ink2.color : colors.ink.color)
            if let d = row.detail {
                Text(d)
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
