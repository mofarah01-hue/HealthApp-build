import SwiftUI
import MGContext
import MGDesign

// Settings › Command test › "Raw optical (PPG)" (P9726, Mo Oct 14: "include that test page with toggle on/off for the raw
// PPG I see, so we can figure that out"). Pure rendering of `RawPPGState`; the only output is `UIIntent.commandTest(_:)`.
// Every R20 slot is drawn on its own (R-180: a pulse with no green and no red lit is IR). Raw counts, decoded, untested.

struct CommandTestPPGSection: View {
    let state: RawPPGState
    let send: (UIIntent) -> Void
    @State private var seen = PPGObservation()
    @Environment(\.mgColors) private var colors

    var body: some View {
        SettingsSection("Raw optical (PPG)", note: "decoded, untested") {
            // r9v (UI-SCRUB T2): one home for the switch. Strap & sync owns it; this page shows where it stands and links there.
            SettingsLinkRow("Raw optical is \(state.rawOpticalWanted ? "on" : "off")",
                            detail: "Switch it in Strap & sync (108 [01 01] on, [01 00] off; streams only while the app is "
                                + "open; uses strap battery; off by default).",
                            action: { send(.openStrapSync) }) { EmptyView() }
            LogHint(state.status)
            ForEach(state.strips) { strip in
                VStack(alignment: .leading, spacing: 4) {
                    Text(strip.label)
                        .mgFont(.detail)
                        .foregroundStyle(colors.ink.color)
                    SparklineView(values: strip.samples.map { Optional($0) }, width: nil, height: 44)
                    LogHint(strip.rate)
                    LogHint(strip.quality)
                }
                .padding(.vertical, 6)
            }
        }
        SettingsSection("What you see on the strap", note: "saved with the newest send in the log") {
            // T9847 (r9d): the live line for each slot is above; label what the strap shows while you watch it. Red and
            // infrared are controlled by the strap's own firmware, so a send may not change them.
            LogHint("Watch the lines above while you label: each slot shows its own live signal (infrared shows as a pulse "
                    + "with no green or red lit).")
            SettingsRow("Green LEDs lit") {
                Picker("Green LEDs lit", selection: $seen.greens) {
                    Text("?").tag(Optional<Int>.none)
                    ForEach(0...3, id: \.self) { Text("\($0)").tag(Optional($0)) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 200, minHeight: MGSpace.tapTarget)    // r8h C4
            }
            onOffRow("Red", $seen.red)
            onOffRow("Infrared light", $seen.infrared)
            onOffRow("Photodiode (light sensor)", $seen.photodiode)       // T9847
            SettingsRow("Brightness") {
                Picker("Brightness", selection: $seen.brightness) {
                    Text("?").tag(Optional<PPGObservation.Brightness>.none)
                    Text("low").tag(Optional(PPGObservation.Brightness.low))
                    Text("med").tag(Optional(PPGObservation.Brightness.medium))
                    Text("high").tag(Optional(PPGObservation.Brightness.high))
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 200, minHeight: MGSpace.tapTarget)    // r8h C4
            }
            LogTextField("Note (optional)", text: $seen.note)       // r8h C3: a styled field
                .padding(.vertical, 8)
            MGButton("Save what I see", style: .filled) {           // r8h C4: 44 pt, themed
                send(.commandTest(.observe(PPGObservation(greens: seen.greens, red: seen.red, infrared: seen.infrared,
                                                          brightness: seen.brightness, photodiode: seen.photodiode,
                                                          note: seen.note))))
                seen = PPGObservation()
            }
            .disabled(seen.isEmpty)
            .opacity(seen.isEmpty ? 0.4 : 1)
            .padding(.vertical, 8)
            ForEach(state.observations) { LogHint($0.text) }
        }
        SettingsSection("Motion polling", note: "T124") {
            SettingsRow("Raw motion (100 Hz)") {
                Picker("Raw motion", selection: Binding(get: { state.motion },
                                                        set: { send(.commandTest(.setMotionPolling($0))) })) {
                    ForEach(MotionPolling.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.menu)
            }
            LogHint("Faster or slower polling: 1-minute bursts, continuous, or the Settings switch (the default). No "
                    + "command is known that changes the strap's own motion rate, so a burst is 81 + 106 at 100 Hz. "
                    + "Uses strap battery; not saved, the Settings switch takes over when you pick it.")
            if !state.motionStatus.isEmpty { LogHint(state.motionStatus) }
        }
        SettingsSection("Record all night", note: "for the sleep model") {
            // r8h C5 (Oct 17 2026): both are command 107 ENABLE_OPTICAL_DATA but they are not the same switch. This one is the
            // SAVED setting: 107 [01 01] goes out while raw optical is on and again after every reconnect.
            SettingsToggleRow("Keep raw on the strap if the app is closed",
                              detail: "Saved switch: sends 107 [01 01] while raw optical is on and after each reconnect. "
                                  + "Fills strap memory. Off by default.",
                              isOn: state.keepRawOnStrap) { send(.commandTest(.setKeepRawOnStrap($0))) }
            // ... and this one is a single manual send, logged in the list below.
            SettingsToggleRow("Bank raw optical to strap history",
                              detail: "One manual send of 107 [01 01] / [01 00], logged. Uses strap battery and memory; "
                                  + "turn it off in the morning.",
                              isOn: state.nightBanking) { send(.commandTest(.setNightBanking($0))) }
        }
    }

    private func onOffRow(_ title: String, _ value: Binding<Bool?>) -> some View {
        SettingsRow(title) {
            Picker(title, selection: value) {
                Text("?").tag(Optional<Bool>.none)
                Text("on").tag(Optional(true))
                Text("off").tag(Optional(false))
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 160, minHeight: MGSpace.tapTarget)    // r8h C4
        }
    }
}
