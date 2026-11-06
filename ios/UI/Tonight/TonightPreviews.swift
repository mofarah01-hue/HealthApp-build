#if DEBUG
import SwiftUI
import MGContext
import MGDesign
import MGDomain

// Xcode previews of the Tonight sheet from `TonightState.preview` (SAMPLE): the notification ringer (iOS < 26, with
// the Silent sentence), AlarmKit (iOS 26+), no "must be up by" (no plan, and why), Satin Emerald, largest text.
// Taps print their intent.

private enum TonightPreviewData {
    static var sleepDebtAndSmartWake: TonightState {
        var s = TonightState.preview
        let receipt = SampleDay.receipt(.phone, .estimate, 20, 5, method: "ALG-115")
        s.need[1].value = SampleDay.value("31 min", nil, receipt, .estimate(nil))
        s.summaryLine = "Bed 10:30 PM → asleep ≈ 10:44 PM → up 6:40–7:10 AM"
        s.smartWake.sentence = "Wakes you in light sleep inside the window (strap stager, live); otherwise at 7:10 AM."
        s.caffeineSentence = "32 mg at 10:30 PM — under your 33"
        s.windDown.detail = "9:30 PM, one notification"
        return s
    }

    static var alarmKit: TonightState {
        var s = sleepDebtAndSmartWake
        s.smartWake.ringer = .alarmKit
        s.smartWake.silentWarning = nil
        return s
    }

    /// BRIEF default 3: weekday "up by" times blank until Mo fills them → no wake plan, and the sheet says why.
    static var noPlan: TonightState {
        var s = sleepDebtAndSmartWake
        s.latestWake = (1...7).map { WeekdayWake(weekday: $0, time: nil) }
        s.summaryLine = "Bed 10:30 PM → asleep ≈ 10:44 PM · no wake plan"
        s.smartWake.windowStart = nil
        s.smartWake.windowEnd = nil
        s.smartWake.noPlanReason = "No \"must be up by\" for Monday yet — set one and smart wake plans its window."
        s.smartWake.toggle = ToggleState(id: "sw", title: "Smart wake", isOn: false, enabled: false,
                                         disabledReason: "Needs a \"must be up by\" time for tomorrow.",
                                         intent: .setSmartWake(true))
        return s
    }
}

private struct TonightPreviewHost: View {
    let state: TonightState
    let theme: ThemeName

    var body: some View {
        Color.gray.opacity(0.3)
            .sheet(isPresented: .constant(true)) {
                TonightSheet(state: state, theme: theme) { intent in print("Tonight intent:", intent) }
            }
    }
}

#Preview("Tonight · sleep debt · smart wake on") {
    TonightPreviewHost(state: TonightPreviewData.sleepDebtAndSmartWake, theme: .emerald)
}
#Preview("Tonight · AlarmKit (iOS 26+)") { TonightPreviewHost(state: TonightPreviewData.alarmKit, theme: .emerald) }
#Preview("Tonight · no wake plan") { TonightPreviewHost(state: TonightPreviewData.noPlan, theme: .emerald) }
#Preview("Tonight · cream") { TonightPreviewHost(state: TonightPreviewData.sleepDebtAndSmartWake, theme: .cream) }
#Preview("Tonight · largest text") {
    TonightPreviewHost(state: TonightPreviewData.sleepDebtAndSmartWake, theme: .emeraldLow)
        .environment(\.dynamicTypeSize, .accessibility3)
}
#endif
