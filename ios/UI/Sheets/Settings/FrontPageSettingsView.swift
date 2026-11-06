import SwiftUI
import MGContext
import MGDesign

// Settings › Front page (tracker #34, mockups P1b + P1c, 2026-10-11): Today's cards — drag to reorder, the eye hides
// (the card keeps its place), the red minus removes it to "Add", "Reset to default" — and the dial's layers. Pure
// rendering of `FrontPageSettingsState`; every change is `UIIntent.frontPage(_:)`. SAMPLE mode: nothing changes, the
// reason shows (the Settings rule).

struct FrontPageSettingsScreen: View {
    @ObservedObject var model: FrontPageModel
    let send: (UIIntent) -> Void

    init(model: FrontPageModel, send: @escaping (UIIntent) -> Void) {
        self.model = model
        self.send = send
    }

    var body: some View {
        if let s = model.state {
            FrontPageSettingsView(state: s, send: send)
        } else {
            RootLoading(text: "Reading your front page…", giveUpAfter: 10)
        }
    }
}

struct FrontPageSettingsView: View {
    let state: FrontPageSettingsState
    let send: (UIIntent) -> Void

    init(state: FrontPageSettingsState, send: @escaping (UIIntent) -> Void) {
        self.state = state
        self.send = send
    }
    @Environment(\.mgColors) private var colors
    /// R8e (S9): which reset is waiting for a yes.
    @State private var confirming: FrontPageReset?

    var body: some View {
        List {
            Section {
                header
            }
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)

            Section {
                ForEach(Array(state.rows.enumerated()), id: \.element.id) { index, row in
                    FrontPageRowView(row: row, canEdit: state.canEdit, send: send)
                        .accessibilityActions {
                            if state.canEdit, index > 0 {
                                Button("Move up") { send(.frontPage(.move(from: [index], to: index - 1))) }
                            }
                            if state.canEdit, index < state.rows.count - 1 {
                                Button("Move down") { send(.frontPage(.move(from: [index], to: index + 2))) }
                            }
                        }
                }
                .onMove { from, to in send(.frontPage(.move(from: Array(from), to: to))) }
                .onDelete { offsets in
                    for i in offsets where state.rows.indices.contains(i) { send(.frontPage(.remove(state.rows[i].item))) }
                }
                .moveDisabled(!state.canEdit)
                .deleteDisabled(!state.canEdit)
            } header: {
                sectionTitle("On the front page", note: "drag to reorder · eye hides · − removes")
            }
            .listRowBackground(Color.clear)

            Section {
                if state.addable.isEmpty {
                    Text("Every card is on the page.")
                        .mgFont(.detail)
                        .foregroundStyle(colors.ink2.color)
                } else {
                    ForEach(state.addable) { row in
                        Button { send(.frontPage(.add(row.item))) } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "plus.circle.fill")
                                    .foregroundStyle(colors.focus.color)
                                    .accessibilityHidden(true)
                                rowText(row.title, row.detail, dimmed: false)
                            }
                            .frame(minHeight: MGSpace.rowMinHeight)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(!state.canEdit)
                        .accessibilityLabel("Add \(row.title)")
                    }
                }
            } header: {
                sectionTitle("Add", note: nil)
            }
            .listRowBackground(Color.clear)

            Section {
                ForEach(state.picks) { pick in
                    SettingsRow(pick.name) {
                        Menu {
                            ForEach(MetricPickForm.allCases, id: \.self) { form in
                                Button(form.title) { send(.frontPage(.pickMetric(key: pick.key, form: form))) }
                            }
                            Button("Remove", role: .destructive) { send(.frontPage(.unpickMetric(key: pick.key))) }
                        } label: {
                            SettingsValueText(pick.form.title)
                        }
                        .disabled(!state.canEdit)
                    }
                }
                SettingsRow("Add a metric") {
                    Menu {
                        ForEach(state.pickChoices) { c in
                            Button(c.name) { send(.frontPage(.pickMetric(key: c.key, form: .tile))) }
                        }
                    } label: {
                        SettingsValueText("Choose…")
                    }
                    .disabled(!state.canEdit)
                }
            } header: {
                sectionTitle("Metrics on Today", note: "any metric, as a tile, a graph or a number")
            }
            .listRowBackground(Color.clear)

            Section {
                ForEach(ringLayers.indices, id: \.self) { index in
                    let pair = ringLayers[index]
                    FrontPageRingRow(layer: pair.0, toggle: pair.1, index: index, send: send)
                }
            } header: {
                sectionTitle("Inner rings", note: "outside → in")
            }
            .listRowBackground(Color.clear)

            Section {
                ForEach(state.dialLayers.filter { !DialLayer.rings.map(\.rawValue).contains($0.id) }) { layer in
                    SettingsToggleRow(layer.title, isOn: layer.isOn, enabled: layer.enabled,
                                      reason: layer.disabledReason) { _ in send(layer.intent) }
                }
            } header: {
                sectionTitle("Layers", note: "the awake track, the hand and the hub always draw")
            }
            .listRowBackground(Color.clear)

            Section {
                MGButton("Reset front page to default", style: .ghost) { confirming = .page }
                    .disabled(!state.canEdit || state.pageIsDefault)
                MGButton("Show every ring", style: .ghost) { confirming = .rings }
                    .disabled(!state.canEdit || state.dialIsDefault)
            }
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(colors.sheet.color)
        .environment(\.editMode, .constant(state.canEdit ? .active : .inactive))
        .safeAreaInset(edge: .top, spacing: 0) {
            if state.sample { SampleBanner() }
        }
        .confirmationDialog(confirming?.question ?? "", isPresented: Binding(get: { confirming != nil },
                                                                              set: { if !$0 { confirming = nil } }),
                            titleVisibility: .visible, presenting: confirming) { reset in
            // `reset` is the value captured when the dialog opened (the binding above is cleared before a button runs).
            Button(reset.action, role: .destructive) {
                switch reset {
                case .page: send(.frontPage(.reset))
                case .rings: send(.frontPage(.resetDial))
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { reset in
            Text(reset.detail)
        }
    }

    private var ringLayers: [(DialLayer, ToggleState)] {
        DialLayer.rings.compactMap { ring in
            state.dialLayers.first(where: { $0.id == ring.rawValue }).map { (ring, $0) }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Preferences")       // U3: the parent's name
                .mgFont(.kicker)
                .foregroundStyle(colors.topText.color)
            Text("Front page")
                .mgFont(.title)
                .foregroundStyle(colors.ink.color)
                .accessibilityAddTraits(.isHeader)
            Text(state.note)
                .mgFont(.detail)
                .foregroundStyle(colors.ink2.color)
                .fixedSize(horizontal: false, vertical: true)
            if let reason = state.disabledReason {
                LogHint(reason)
                    .padding(.top, 4)
            }
        }
        .padding(.top, 4)
    }

    private func sectionTitle(_ title: String, note: String?) -> some View {
        SectionHeader(title, note: note)
            .textCase(nil)
    }

    private func rowText(_ title: String, _ detail: String, dimmed: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .mgFont(.rowTitle)
                .foregroundStyle(dimmed ? colors.mute.color : colors.ink.color)
            Text(detail)
                .mgFont(.detail)
                .foregroundStyle(colors.ink2.color)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// R8e (S9): the two resets change a page Mo set up by hand, with no undo, so each asks first.
private enum FrontPageReset {
    case page, rings

    var question: String { self == .page ? "Reset the front page?" : "Show every ring?" }
    var action: String { self == .page ? "Reset front page" : "Show every ring" }
    var detail: String {
        self == .page ? "The cards and the layers go back to the default order. Your choices on this page are lost."
                      : "Every ring comes back on the dial. Your choice of rings is lost."
    }
}

private struct FrontPageRingRow: View {
    let layer: DialLayer
    let toggle: ToggleState
    let index: Int
    let send: (UIIntent) -> Void
    @Environment(\.mgColors) private var colors

    var body: some View {
        OptimisticToggle(isOn: toggle.isOn, onChange: { _ in send(toggle.intent) }) {
            HStack(alignment: .center, spacing: 10) {
                ConcentricRingsIcon(count: DialLayer.rings.count, highlighted: index, colors: ringColors)
                    .scaleEffect(0.8)
                    .frame(width: 16, height: 16)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .mgFont(.rowTitle)
                        .foregroundStyle(colors.ink.color)
                    if let detail = toggle.detail {
                        Text(detail)
                            .mgFont(.detail)
                            .foregroundStyle(colors.ink2.color)
                    }
                    if !toggle.enabled, let reason = toggle.disabledReason { LogHint(reason) }
                }
            }
        }
        .tint(colors.focus.color)
        .disabled(!toggle.enabled)
        .padding(.vertical, 4)
        .frame(minHeight: 52)
    }

    private var ringColors: [Color] {
        DialLayer.rings.map { colors.ring(kind($0)).color }
    }

    private var title: String {
        switch layer {
        case .ringStrain: return "Strain"
        case .ringRecovery: return "Recovery"
        case .ringSleep: return "Sleep"
        case .ringStress: return "Body arousal"
        case .ringBurn: return "Burned"
        case .ringEaten: return "Eaten"
        default: return layer.title
        }
    }

    private func kind(_ layer: DialLayer) -> DialRing.Kind {
        switch layer {
        case .ringStrain: return .strain
        case .ringRecovery: return .recovery
        case .ringSleep: return .sleep
        case .ringStress: return .stress
        case .ringBurn: return .burn
        case .ringEaten: return .eaten
        default: preconditionFailure("A non-ring layer reached the inner-ring list")
        }
    }
}

/// One card on the page: title, what it shows, and the eye (hide keeps its place).
struct FrontPageRowView: View {
    let row: FrontPageSettingsState.Row
    let canEdit: Bool
    let send: (UIIntent) -> Void

    init(row: FrontPageSettingsState.Row, canEdit: Bool, send: @escaping (UIIntent) -> Void) {
        self.row = row
        self.canEdit = canEdit
        self.send = send
    }
    @Environment(\.mgColors) private var colors

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title)
                    .mgFont(.rowTitle)
                    .foregroundStyle(row.hidden ? colors.mute.color : colors.ink.color)
                Text(row.hidden ? "hidden · " + row.detail : row.detail)
                    .mgFont(.detail)
                    .foregroundStyle(colors.ink2.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button { send(.frontPage(.setHidden(row.item, hidden: !row.hidden))) } label: {
                Image(systemName: row.hidden ? "eye.slash" : "eye")
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(row.hidden ? colors.mute.color : colors.ink.color)
                    .frame(width: MGSpace.tapTarget, height: MGSpace.tapTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .disabled(!canEdit)
            .accessibilityLabel(row.hidden ? "Show \(row.title)" : "Hide \(row.title)")
        }
        .frame(minHeight: MGSpace.rowMinHeight)
        .accessibilityElement(children: .contain)
    }
}
