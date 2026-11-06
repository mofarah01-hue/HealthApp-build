import SwiftUI
import MGContext
import MGDesign

// Settings › Places (tracker #41, 2026-10-11): Mo's saved places (Home, Work, Gym, Soccer field, Pickup field, others),
// each set with "Use my current location" and a radius; the switch that notices when he is at them (region monitoring
// + visits, low power); his last stays; how the places are used. Pure rendering of `PlacesState`; every change is a
// `UIIntent.places(_:)`. The rename sheet holds only the text being typed.

struct PlacesScreen: View {
    @ObservedObject var model: PlacesModel
    let send: (UIIntent) -> Void

    init(model: PlacesModel, send: @escaping (UIIntent) -> Void) {
        self.model = model
        self.send = send
    }

    var body: some View {
        if let s = model.state {
            PlacesView(state: s, send: send)
        } else {
            RootLoading(text: "Reading your places…", giveUpAfter: 10)
        }
    }
}

/// The rename sheet's target (presentation only; the name changes through `.places(.rename)`).
struct PlacesRename: Identifiable {
    let id: String
    let name: String
}

struct PlacesView: View {
    let state: PlacesState
    let send: (UIIntent) -> Void

    init(state: PlacesState, send: @escaping (UIIntent) -> Void) {
        self.state = state
        self.send = send
    }
    @Environment(\.mgColors) private var colors
    @State private var renaming: PlacesRename?

    var body: some View {
        MGScreen {
            VStack(alignment: .leading, spacing: 0) {
                header
                    .padding(.top, 12)
                    .padding(.bottom, 6)
                if let note = state.note {
                    LogHint(note).padding(.vertical, 6)
                }
                placesSection
                addSection
                presenceSection
                if !state.recent.isEmpty { recentSection }
                LogHint(state.howUsed)
                    .padding(.top, 16)
            }
            .padding(.bottom, 48)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if state.sample { SampleBanner() }
        }
        .sheet(item: $renaming) { r in
            PlacesRenameSheet(target: r, send: send)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Settings")          // U3: the parent's name
                .mgFont(.kicker)
                .foregroundStyle(colors.topText.color)
            Text("Places")
                .mgFont(.title)
                .foregroundStyle(colors.ink.color)
                .accessibilityAddTraits(.isHeader)
            Text("Where a workout happened, and a better first guess at what it was.")
                .mgFont(.detail)
                .foregroundStyle(colors.ink2.color)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var placesSection: some View {
        SettingsSection("Your places", note: state.places.isEmpty ? "none yet" : nil) {
            if state.places.isEmpty {
                Text("Add Home, Work, Gym or a field below, then stand there and tap Use my current location.")
                    .mgFont(.detail)
                    .foregroundStyle(colors.ink2.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 8)
            }
            ForEach(state.places) { p in
                VStack(alignment: .leading, spacing: 6) {
                    SettingsRow(p.name, detail: p.kindLine + "\n" + p.status) {
                        if p.isHere { SettingsTag("here") }
                    }
                    AlarmsStepperRow("Radius", value: p.radiusMeters, range: 50...500, step: 25, unit: "m") {
                        send(.places(.setRadius(id: p.id, meters: $0)))
                    }
                    FlowLayout(spacing: 8, lineSpacing: 8) {
                        MGButton(p.hasLocation ? "Set again here" : "Use my current location",
                                 style: p.hasLocation ? .ghost : .filled) {
                            send(.places(.useCurrentLocation(id: p.id)))
                        }
                        MGButton("Rename", style: .ghost) { renaming = PlacesRename(id: p.id, name: p.name) }
                        MGButton("Remove", style: .ghost) { send(.places(.remove(id: p.id))) }
                    }
                    .padding(.bottom, 10)
                }
            }
        }
    }

    private var addSection: some View {
        SettingsSection("Add a place") {
            FlowLayout(spacing: 8, lineSpacing: 8) {
                ForEach(state.add) { a in
                    Chip(a.title) { if let i = a.intent { send(i) } }
                }
            }
            .padding(.vertical, 8)
        }
        .padding(.top, 8)
    }

    private var presenceSection: some View {
        SettingsSection("Notice where I am", note: "low power") {
            SettingsToggleRow(state.presence.title, detail: state.presenceDetail, isOn: state.presence.isOn,
                              enabled: state.presence.enabled, reason: state.presence.disabledReason) { on in
                send(.places(.setPresence(on)))
            }
            if let problem = state.permissionProblem {
                LogHint(problem).padding(.vertical, 6)
            }
        }
        .padding(.top, 8)
    }

    private var recentSection: some View {
        SettingsSection("Last stays", note: "newest first") {
            ForEach(Array(state.recent.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .mgFont(.detail)
                    .foregroundStyle(colors.ink.color)
                    .padding(.vertical, 6)
            }
        }
        .padding(.top, 8)
    }
}

struct PlacesRenameSheet: View {
    let target: PlacesRename
    let send: (UIIntent) -> Void
    @State private var name: String

    init(target: PlacesRename, send: @escaping (UIIntent) -> Void) {
        self.target = target
        self.send = send
        _name = State(initialValue: target.name)
    }

    var body: some View {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        SettingsSheetFrame(title: "Rename place", canSave: !clean.isEmpty, reason: clean.isEmpty ? "Type a name." : nil,
                           onSave: { send(.places(.rename(id: target.id, name: clean))) }) {
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .formSubmit()                  // r9v (K1)
            LogHint("Workouts logged from now on carry the new name.")
        }
    }
}
