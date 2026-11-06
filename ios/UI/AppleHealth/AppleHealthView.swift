import SwiftUI
import MGContext
import MGDesign
import MGDomain

// Settings › Apple Health (2026-10-11): the Shortcuts bridge. Pure rendering of `AppleHealthState`; every tap is a
// `UIIntent.appleHealth(_:)`. `AppleHealthScreen` observes the bridge model so the page updates when a Shortcut calls
// back while it is on screen.

struct AppleHealthScreen: View {
    @ObservedObject var bridge: HealthBridgeModel
    let send: (UIIntent) -> Void

    init(bridge: HealthBridgeModel, send: @escaping (UIIntent) -> Void) {
        self.bridge = bridge
        self.send = send
    }

    var body: some View {
        if let s = bridge.state {
            AppleHealthView(state: s, send: send)
        } else {
            RootLoading(text: "Reading the Apple Health log…", giveUpAfter: 10)
        }
    }
}

struct AppleHealthView: View {
    let state: AppleHealthState
    let send: (UIIntent) -> Void

    init(state: AppleHealthState, send: @escaping (UIIntent) -> Void) {
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
                if let b = state.banner { banner(b) }
                if let p = state.pending {
                    LogHint(p)
                        .padding(.vertical, 6)
                }
                if let line = state.autoLine {
                    SettingsSection("Automatic read", note: "in the app") {
                        SettingsRow(line) { EmptyView() }
                        ForEach(state.autoTypeLines ?? [], id: \.self) { SettingsRow($0) { EmptyView() } }
                    }
                }
                intoHealth
                toPC
                SettingsSection("The three Shortcuts", note: "build once") {
                    ForEach(state.guides) { g in AppleHealthGuideView(guide: g, send: send) }
                }
                logs
            }
            .padding(.bottom, 48)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if state.sample { SampleBanner() }
        }
    }

    private var headerText: String {
        #if HEALTHKIT
        return "The app reads Apple Health itself and sends new samples to your PC on its own (when the phone is "
            + "unlocked and the PC is reachable). The two Shortcuts below are the fallback and the way back into Health."
        #else
        return "This build has no HealthKit (free Apple account), so two Shortcuts carry the data: one logs the app's "
            + "values into Health, one sends Health's samples to your PC."
        #endif
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Settings")          // U3: the parent's name
                .mgFont(.kicker)
                .foregroundStyle(colors.topText.color)
            Text("Apple Health")
                .mgFont(.title)
                .foregroundStyle(colors.ink.color)
                .accessibilityAddTraits(.isHeader)
            Text(headerText)
                .mgFont(.detail)
                .foregroundStyle(colors.ink2.color)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func banner(_ b: AppleHealthState.Banner) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(b.text)
                .mgFont(.rowTitle)
                .foregroundStyle(colors.ink.color)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                if let id = b.stepsFor {
                    MGButton("Steps", style: .filled) { send(.appleHealth(.showSteps(id))) }
                }
                MGButton("OK", style: .ghost) { send(.appleHealth(.dismissBanner)) }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(b.isProblem ? colors.ink.color : colors.rule.color,
                              style: StrokeStyle(lineWidth: 1, dash: b.isProblem ? [4, 3] : []))
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }

    private var intoHealth: some View {
        SettingsSection("Into Apple Health", note: "today") {
            VStack(alignment: .leading, spacing: 6) {
                if state.todayLines.isEmpty {
                    LogHint(state.send.disabledReason ?? "Nothing to send for today.")
                }
                ForEach(state.todayLines, id: \.self) { line in
                    Text(line)
                        .mgFont(.detail)
                        .foregroundStyle(colors.ink.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(state.todaySkipped, id: \.self) { line in LogHint("Not sent · " + line) }
                actionButton(state.send, style: .filled)
                if let t = state.testIn {
                    actionButton(t, style: .ghost)
                    LogHint("Runs the Shortcut with nothing to log: shows whether iOS finds it and what it reports back.")
                }
            }
            .padding(.vertical, 10)
            .overlay(alignment: .bottom) { Rectangle().fill(colors.rule.color).frame(height: 1) }
            SettingsToggleRow(state.autoSend.title, detail: state.autoSend.detail, isOn: state.autoSend.isOn,
                              enabled: state.autoSend.enabled, reason: state.autoSend.disabledReason) { _ in
                send(state.autoSend.intent)
            }
        }
    }

    private var toPC: some View {
        SettingsSection("From Apple Health to your PC", note: "Tailscale") {
            SettingsRow("Shortcuts token", detail: state.tokenLine) {
                if state.canCopyToken {
                    MGButton("Copy header", style: .ghost) { send(.appleHealth(.copy(.authorization))) }
                }
            }
            if let url = state.endpointLine {
                SettingsRow("URL", detail: url) {
                    MGButton("Copy URL", style: .ghost) { send(.appleHealth(.copy(.endpoint))) }
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    actionButton(state.runOut, style: .filled)
                    actionButton(state.refreshToken, style: .ghost)
                }
                if let f = state.forward { actionButton(f, style: .ghost) }
                LogHint("The PC keeps each delivery as a new folder in data/imports/apple_health_shortcut/ and adds "
                        + "the values to your history here.")
            }
            .padding(.vertical, 10)
        }
    }

    @ViewBuilder private var logs: some View {
        SettingsSection("Log", note: "every run") {
            if state.sends.isEmpty && state.imports.isEmpty {
                SettingsRow("Nothing sent yet") { EmptyView() }
            }
            ForEach(state.sends) { row in AppleHealthLogRow(row: row) }
            ForEach(state.imports) { row in AppleHealthLogRow(row: row) }
        }
    }

    @ViewBuilder private func actionButton(_ a: ActionState, style: MGButton.Style) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            MGButton(a.title, style: style) { if let i = a.intent, a.enabled { send(i) } }
                .disabled(!a.enabled)
                .opacity(a.enabled ? 1 : 0.4)
            if !a.enabled, let why = a.disabledReason, a.id != "send" || !state.todayLines.isEmpty {
                LogHint(why)
            }
        }
    }
}

/// One guide: the Shortcut's name, what it is for, Copy name, and the numbered steps when opened.
struct AppleHealthGuideView: View {
    let guide: AppleHealthState.Guide
    let send: (UIIntent) -> Void

    init(guide: AppleHealthState.Guide, send: @escaping (UIIntent) -> Void) {
        self.guide = guide
        self.send = send
    }
    @Environment(\.mgColors) private var colors

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { send(.appleHealth(.toggleSteps(guide.id))) } label: {
                SettingsRow(guide.title, detail: guide.purpose) {
                    Image(systemName: guide.expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(colors.mute.color)
                        .accessibilityLabel(guide.expanded ? "Hide steps" : "Show steps")
                }
            }
            .buttonStyle(.plain)
            if guide.expanded {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        if guide.isShortcut {
                            MGButton("Copy name", style: .filled) { send(.appleHealth(.copy(.shortcutName(guide.title)))) }
                        }
                        if let run = guide.run {
                            MGButton(run.title, style: .ghost) { if let i = run.intent, run.enabled { send(i) } }
                                .disabled(!run.enabled)
                                .opacity(run.enabled ? 1 : 0.4)
                        }
                    }
                    ForEach(Array(guide.steps.enumerated()), id: \.offset) { n, step in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("\(n + 1)")
                                .mgFont(.kicker)
                                .foregroundStyle(colors.mute.color)
                                .frame(width: 18, alignment: .trailing)
                            Text(step)
                                .mgFont(.detail)
                                .foregroundStyle(colors.ink.color)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }
                    }
                }
                .padding(.bottom, 12)
                .overlay(alignment: .bottom) { Rectangle().fill(colors.rule.color).frame(height: 1) }
            }
        }
    }
}

struct AppleHealthLogRow: View {
    let row: AppleHealthState.LogRow

    init(row: AppleHealthState.LogRow) {
        self.row = row
    }
    @Environment(\.mgColors) private var colors

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(row.when)
                    .mgFont(.kicker)
                    .foregroundStyle(colors.mute.color)
                Text(row.title)
                    .mgFont(.detail)
                    .foregroundStyle(colors.ink.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(row.status)
                    .mgFont(.tag)
                    .foregroundStyle(row.isProblem ? colors.ink.color : colors.ink2.color)
            }
            if let d = row.detail {
                LogHint(d)
            }
        }
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) { Rectangle().fill(colors.rule.color).frame(height: 1) }
        .textSelection(.enabled)
    }
}
