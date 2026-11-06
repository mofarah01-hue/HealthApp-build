import SwiftUI
import MGBLE
import MGDesign

// WHOOP4-LINK (2026-11-05; D-WHOOP4-LINK-1) — Strap & sync › "Device": which strap the app talks to ("MG / none", what it was,
// or "WHOOP 4.0"), the "Pair WHOOP 4.0" button when nothing is bonded, and one status line: connected, firmware, serial,
// battery, worn, live HR. It reads the 4.0 coordinator directly (a link status, not a screen state of the presenters), so the
// existing StrapSyncState and UIIntent set are untouched. Choosing "WHOOP 4.0" makes the app stop connecting to the 5.0/MG.
//
// WRITTEN, NOT COMPILED here (the app target is built with xtool).

struct Whoop4DeviceSection: View {
    @ObservedObject var coordinator: Whoop4Coordinator
    let choose: (StrapDeviceChoice) -> Void
    let pair: () -> Void
    /// 0.6.0.11: STOP_HAPTICS + DISABLE_ALARM (the strap buzzed nonstop on the first connect).
    var stopBuzzing: () -> Void = {}
    /// 0.6.0.12: opens the Raw WHOOP 4.0 data screen (the 4.0's once-a-second history fields, raw counts).
    var openRaw: () -> Void = {}

    @Environment(\.mgColors) private var colors

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader("Device", note: "which strap the app connects to")
            MGCard {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Strap").mgFont(.rowTitle).foregroundStyle(colors.ink.color)
                        Spacer(minLength: 8)
                        Menu {
                            ForEach(StrapDeviceChoice.allCases, id: \.self) { option in
                                Button(option.title) { choose(option) }
                            }
                        } label: {
                            Text(coordinator.choice.title)
                                .mgFont(.button)
                                .foregroundStyle(colors.ink.color)
                                .padding(.horizontal, 14)
                                .frame(minHeight: MGSpace.tapTarget)
                                .overlay(Capsule().strokeBorder(colors.rule.color, lineWidth: 1))
                                .contentShape(Capsule())
                        }
                        .accessibilityLabel("Strap")
                    }
                    if coordinator.choice == .whoop4 {
                        Text("The app connects to the WHOOP 4.0 only. It never scans for or connects to a WHOOP 5.0/MG while "
                             + "this is selected.")
                            .mgFont(.body)
                            .foregroundStyle(colors.ink2.color)
                            .fixedSize(horizontal: false, vertical: true)
                        if !coordinator.status.bonded {
                            MGButton("Pair WHOOP 4.0", style: .ghost) { pair() }
                            Text("Keep the strap close, close the WHOOP app if it holds this strap, and tap the strap until the "
                                 + "blue light shows. Pairing also sets the strap's clock and reads its history.")
                                .mgFont(.body)
                                .foregroundStyle(colors.mute.color)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if coordinator.isConnected {
                            MGButton("Stop buzzing", style: .ghost) { stopBuzzing() }
                        }
                        MGButton("Raw 4.0 data", style: .ghost) { openRaw() }
                        Text(coordinator.statusLine)
                            .mgFont(.body)
                            .foregroundStyle(colors.ink2.color)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }
}
