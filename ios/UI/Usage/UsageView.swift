import SwiftUI
import MGContext
import MGDesign

// Settings › Usage (tracker #40, 2026-10-11): storage on the iPhone and the PC, background runs, the app's own compute
// and what the PC Lab is running now. Pure rendering of `UsageState` (UsagePresenter); "Measure again" is
// `UIIntent.usage(.refresh)`. Reached from Settings › Usage.

struct UsageScreen: View {
    @ObservedObject var model: UsageModel
    let send: (UIIntent) -> Void

    init(model: UsageModel, send: @escaping (UIIntent) -> Void) {
        self.model = model
        self.send = send
    }

    var body: some View {
        if let s = model.state {
            UsageView(state: s, send: send)
        } else {
            RootLoading(text: "Measuring…", giveUpAfter: 15)      // U2: it gives up with a reason and Back
        }
    }
}

struct UsageView: View {
    let state: UsageState
    let send: (UIIntent) -> Void

    init(state: UsageState, send: @escaping (UIIntent) -> Void) {
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
                    UsageSectionView(section: section)
                }
                HStack {
                    MGButton(state.refresh.title, style: .ghost) {
                        if let i = state.refresh.intent { send(i) }
                    }
                    .disabled(!state.refresh.enabled)
                    Spacer(minLength: 0)
                }
                .padding(.top, 16)
            }
            .padding(.bottom, 48)
        }
        .refreshable {                    // U2: pull down = Measure again (the header says "Measuring…" while it runs)
            if state.refresh.enabled, let i = state.refresh.intent { send(i) }
            try? await Task.sleep(for: .seconds(1))
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
            Text("Usage")
                .mgFont(.title)
                .foregroundStyle(colors.ink.color)
                .accessibilityAddTraits(.isHeader)
            Text(state.measured)
                .mgFont(.detail)
                .foregroundStyle(colors.ink2.color)
            if let failure = state.failure {
                Text(failure)
                    .mgFont(.detail)
                    .foregroundStyle(colors.ink.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct UsageSectionView: View {
    let section: UsageState.Section
    @Environment(\.mgColors) private var colors

    init(section: UsageState.Section) {
        self.section = section
    }

    var body: some View {
        SettingsSection(section.title, note: section.note) {
            if let m = section.message {
                Text(m)
                    .mgFont(.detail)
                    .foregroundStyle(colors.ink2.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 8)
            }
            ForEach(section.rows) { row in
                SettingsRow(row.title, detail: row.detail) {
                    Text(row.value)
                        .mgFont(.detail)
                        .foregroundStyle(colors.ink.color)
                        .multilineTextAlignment(.trailing)
                }
                .padding(.leading, row.isPart ? 16 : 0)
            }
        }
        .padding(.top, 8)
    }
}
