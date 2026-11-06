#if DEBUG
import SwiftUI
import MGBLE
import MGContext
import MGDesign
import MGDomain

// Xcode previews of the strap sheets: Strap & sync (normal, PC offline, nothing paired), the write log, the unlock
// confirm sheet (the one R22 write), the result of a run that stopped
// early, the pairing sheet (no camera in the canvas, so the paste field shows; plus a bad link and a paired result)
// and the clock consent. SAMPLE values only; the payloads are the real bytes MGBLE would send. Taps print intents.

enum StrapPreviewData {
    static var connected: StrapSyncState {
        var s = StrapSyncState.preview
        let strap = SampleDay.receipt(.strap, .strap, 9, 40)
        if let firmware = s.strapRows.firstIndex(where: { $0.id == "firmware" }) {
            s.strapRows[firmware].value = SampleDay.value("50.42.1.0", nil, strap)
        }
        if let last = s.strapRows.firstIndex(where: { $0.id == "last" }) {
            s.strapRows[last].value = SampleDay.value("9:40 AM", nil, strap)
        }
        if !s.strapRows.contains(where: { $0.id == "battery_left" }) {
            s.strapRows.insert(
                LabeledValue(id: "battery_left", label: "Battery left",
                             value: SampleDay.value("2 d 8 h", nil, strap, .estimate(nil))),
                at: min(2, s.strapRows.count))
        }
        s.unlockStatus = "off ('2') · read 9:40 AM"
        s.pcLine = "PC got 3 h · 412 KB · 9:40 AM"
        s.healthLines = ["Heart rate, resting HR, HRV, steps · read 9:30 AM"]
        return s
    }

    static var notPaired: StrapSyncState {
        var s = connected
        s.pcState = .notSetUp
        s.pcLine = "PC Lab not set up — everything runs on the phone."
        return s
    }

    static let log: [StrapWriteEntry] = [
        StrapWriteEntry(command: 146, name: "SET_CLOCK", payloadHex: "01 8a 4c 2b 6a 00 00",
                        priorValue: "unix 1791700812", readback: "unix 1791701612",
                        confirmedAt: SampleDay.at(6, 53), result: "ok", standingConsent: true),
        StrapWriteEntry(command: 120, name: "SET_FF_VALUE", payloadHex: r22Hex(.enable),
                        priorValue: "2", readback: "1", confirmedAt: SampleDay.at(9, 12), result: "ok",
                        standingConsent: false),
    ]

    static func r22Hex(_ value: R22PacketsValue) -> String {
        SanctionedCommand.setR22Packets(value).payload.map { String(format: "%02x", $0) }.joined()
    }

    /// The one R22 write: enable_r22_packets "2" → "1".
    static var plan: StrapWritePlan {
        StrapWritePlan(
            title: "R22 research stream: enable_r22_packets → '1'",
            reason: "Lets the strap bank its R22 records into history. One setting; every strap setting was read and stored first.",
            items: [PlannedWrite(name: "enable_r22_packets", command: 120, payloadHex: r22Hex(.enable), currentValue: "2")],
            restorable: true,
            risks: ["enable_r22_packets stays on the strap until it is written again.",
                    "Only this one flag is written."])
    }

    static var report: UnlockReport {
        UnlockReport(
            planId: UUID(), startedAt: SampleDay.at(9, 12), endedAt: SampleDay.at(9, 12),
            items: [
                UnlockItemResult(name: "enable_r22_packets", command: 120, payloadHex: r22Hex(.enable),
                                 priorValue: "2", readback: "2", result: "readback '2' ≠ written '1'"),
            ],
            stoppedEarly: true, note: "stopped at the first failure")
    }
}

private struct StrapSheetPreviewHost: View {
    let state: StrapSyncState
    let theme: ThemeName

    var body: some View {
        StrapSyncSheet(state: state, writeLog: StrapPreviewData.log,
                       send: { print("Strap intent:", $0) }, close: { print("close") })
            .mgTheme(theme)
    }
}

#Preview("Strap & sync · connected") { StrapSheetPreviewHost(state: StrapPreviewData.connected, theme: .cream) }
#Preview("Strap & sync · connected · Emerald") {
    StrapSheetPreviewHost(state: StrapPreviewData.connected, theme: .emerald)
}

#Preview("Strap & sync · PC offline, history running") {
    var s = StrapSyncState.preview
    s.pcState = .offline
    s.pcLine = "PC got 3 h · 412 KB · 9:40 AM"
    s.unsyncedLine = "Waiting: 7 h · 2.1 MB"
    s.historyLine = "62 % · 3 h 10 of 5 h"
    s.historyProgress = 0.62
    return StrapSheetPreviewHost(state: s, theme: .cream)
}

#Preview("Strap & sync · strap connected · PC not paired") {
    var s = StrapPreviewData.notPaired
    s.healthLines = ["Apple Health isn't available in this build."]
    return StrapSheetPreviewHost(state: s, theme: .creamGolden)
}

#Preview("Strap write log") {
    MGScreen {
        StrapWriteLogView(entries: StrapPreviewData.log, back: {})
            .padding(.top, 16)
    }
    .mgTheme(.cream)
}

#Preview("Strap write log · empty · Emerald") {
    MGScreen {
        StrapWriteLogView(entries: [], back: {})
            .padding(.top, 16)
    }
    .mgTheme(.emerald)
}

#Preview("Unlock confirm · cream") {
    UnlockConfirmSheet(plan: StrapPreviewData.plan) { print("decision:", $0) }
        .mgTheme(.cream)
}

#Preview("Unlock confirm · Emerald · largest text") {
    UnlockConfirmSheet(plan: StrapPreviewData.plan) { print("decision:", $0) }
        .mgTheme(.emerald)
        .environment(\.dynamicTypeSize, .accessibility3)
}

#Preview("Unlock result · stopped early") {
    StrapUnlockReportSheet(report: StrapPreviewData.report, close: {})
        .mgTheme(.cream)
}

#Preview("Pairing · no camera, paste field") {
    PairingSheet(controller: PairingController(pair: { _ in }), close: {})
        .mgTheme(.cream)
}

#Preview("Pairing · bad link") {
    let controller = PairingController(pair: { _ in })
    controller.handleLink("https://example.com/")
    return PairingSheet(controller: controller, close: {})
        .mgTheme(.emerald)
}

#Preview("Pairing · incomplete link") {
    let controller = PairingController(pair: { _ in })
    controller.handleLink("mgapp://pair?v=1&base=http%3A%2F%2Fsample-pc%3A18787")
    return PairingSheet(controller: controller, close: {})
        .mgTheme(.cream)
}

#Preview("Pairing · paired") {
    let controller = PairingController(pair: { _ in })
    controller.handleLink("mgapp://pair?v=1&base=http%3A%2F%2Fsample-pc%3A18787&token=SAMPLETOKEN&pc=Sample-PC")
    return PairingSheet(controller: controller, close: {})
        .mgTheme(.cream)
}

#Preview("Clock consent") {
    StrapClockConsentSheet { print("allow clock set:", $0) }
        .mgTheme(.cream)
}
#endif
