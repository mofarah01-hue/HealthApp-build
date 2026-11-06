import SwiftUI
import MGContext
import MGDesign

// Settings › Command test (T87, 2026-10-13). One command at a time: a Send button on each row sends that command once (with
// the optional hex payload; r8h C1: it was a switch that only meant "send"), each send is logged, and the picker beside a log
// row marks what happened. Pure rendering of
// `CommandTestState`; the only output is `UIIntent.commandTest(_:)`. "can disable the strap" is information, not a gate.

struct CommandTestScreen: View {
    @ObservedObject var model: CommandTestModel
    let send: (UIIntent) -> Void

    init(model: CommandTestModel, send: @escaping (UIIntent) -> Void) {
        self.model = model
        self.send = send
    }

    var body: some View {
        CommandTestView(state: model.state, send: send)
    }
}

struct CommandTestView: View {
    let state: CommandTestState
    let send: (UIIntent) -> Void
    @State private var payload: String
    @State private var search = ""
    @Environment(\.mgColors) private var colors

    init(state: CommandTestState, send: @escaping (UIIntent) -> Void) {
        self.state = state
        self.send = send
        _payload = State(initialValue: state.payload)       // r8h C3: what the model holds, not an empty field
    }

    /// r8h C2: the command list filtered on number or name.
    private var shown: [CommandTestState.Command] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return state.commands }
        return state.commands.filter { String($0.number) == q || String($0.number).hasPrefix(q)
            || $0.name.lowercased().contains(q) }
    }

    /// "last result: worked" / "sent, no result marked" / nil when this page never sent it.
    private func lastResult(_ c: CommandTestState.Command) -> String? {
        guard c.wasSent else { return nil }
        if let mark = c.lastMark { return "last result: \(mark.rawValue)" }
        return "sent, no result marked"
    }

    var body: some View {
        MGScreen {
            VStack(alignment: .leading, spacing: 0) {
                Text("Settings")          // U3: the parent's name
                    .mgFont(.kicker)
                    .foregroundStyle(colors.topText.color)
                    .padding(.top, 12)
                Text("Command test")
                    .mgFont(.title)
                    .foregroundStyle(colors.ink.color)
                    .accessibilityAddTraits(.isHeader)
                // P9726: raw optical on/off, each slot live, what Mo sees, motion polling, record all night.
                CommandTestPPGSection(state: state.ppg, send: send)
                SettingsSection("Payload", note: "optional, hex") {
                    LogTextField("01 01", text: $payload)
                        .padding(.vertical, 8)
                        .onChange(of: payload) { _, text in send(.commandTest(.setPayload(text))) }
                    if let problem = state.payloadProblem { LogHint(problem) }
                    if let notice = state.notice { LogHint(notice) }
                }
                SettingsSection("Log", note: "newest first") {
                    if state.log.isEmpty { LogHint("Nothing sent yet.") }
                    ForEach(state.log) { entry in
                        SettingsRow(entry.text) {
                            Picker("Result", selection: Binding(
                                get: { entry.mark },
                                set: { if let m = $0 { send(.commandTest(.mark(entryID: entry.id, m))) } })) {
                                Text("result").tag(Optional<CommandTestMark>.none)
                                ForEach(CommandTestMark.allCases, id: \.self) { Text($0.rawValue).tag(Optional($0)) }
                            }
                            .pickerStyle(.menu)
                        }
                    }
                }
                SettingsSection("Commands", note: shown.count == state.commands.count
                                ? "\(state.commands.count) in the protocol table"
                                : "\(shown.count) of \(state.commands.count)") {
                    LogTextField("Search by number or name", text: $search)
                        .padding(.vertical, 8)
                    if shown.isEmpty { LogHint("No command matches.") }
                    LazyVStack(alignment: .leading, spacing: 0) {       // r8h C2: rows are built as they scroll in
                        ForEach(shown) { c in
                            SettingsRow("\(c.name) (\(c.number))", detail: lastResult(c)) {
                                HStack(spacing: MGSpace.s) {
                                    if c.canDisableStrap { TagPill(text: CommandTestPresenter.disableLabel) }
                                    MGButton(state.sending == c.number ? "Sending…" : "Send", style: .ghost) {
                                        send(.commandTest(.toggle(number: c.number, on: true)))
                                    }
                                    .disabled(state.sending != nil)
                                    .accessibilityLabel("Send \(c.name), command \(c.number)")
                                }
                            }
                        }
                    }
                }
            }
            .padding(.bottom, 48)
        }
        .scrollDismissesKeyboard(.interactively)
        .keyboardDoneBar()
    }
}
