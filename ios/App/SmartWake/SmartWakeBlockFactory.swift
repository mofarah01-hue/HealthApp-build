import Foundation
import MGDomain
import MGContext
import MGSignal

/// Builds the Tonight sheet's `SmartWakeBlockState` (UX-SPEC 8.1; WP-12 renders it). WP-23's Tonight presenter calls
/// this with the plan it got from `ALG035.plan` (or the controller's status) and the ringer the controller will use.
public enum SmartWakeBlockFactory {
    /// - Parameters:
    ///   - isOn: the Tonight toggle.
    ///   - windowMinutes: the setting (10–45, default 30).
    ///   - plan: tonight's plan, or Missing with the reason (no "must be up by" → "no wake plan", BRIEF default 3).
    ///   - ringer: `SmartWakeControlling.ringerKind`.
    ///   - motionLive: true only when `StrapLinking.liveMotion` is delivering (never in B1: opcodes 81 + 106 are
    ///     policy-gated), so the sentence says heart-only plainly.
    public static func make(isOn: Bool, windowMinutes: Int, plan: Computed<SmartWakePlan>?,
                            ringer: SmartWakeBlockState.Ringer, motionLive: Bool = false,
                            calendar: Calendar = .current) -> SmartWakeBlockState {
        let toggle = ToggleState(id: "sw", title: "Smart wake", isOn: isOn, intent: .setSmartWake(!isOn))
        let silent: String? = ringer == .notification ? "A notification may not wake you on Silent." : nil
        let source = motionLive ? "strap stager, live" : "strap stager, live, heart rate only"
        guard isOn else {
            return SmartWakeBlockState(toggle: toggle, windowMinutes: windowMinutes, windowStart: nil, windowEnd: nil,
                                       sentence: "Off: no smart wake tonight.", ringer: ringer, silentWarning: nil,
                                       noPlanReason: "Smart wake is off")
        }
        switch plan {
        case .success(let p)?:
            let ws = Date(timeIntervalSince1970: TimeInterval(p.windowStart))
            let we = Date(timeIntervalSince1970: TimeInterval(p.windowEnd))
            var sentence = "Wakes you in light sleep inside the window (\(source)); otherwise at \(hm(we, calendar))."
            if p.narrowed {
                sentence += p.narrowReason == .shortNight
                    ? " Short night: the window is only the last 15 min."
                    : " Past your bedtime: the window is only the last 15 min."
            }
            return SmartWakeBlockState(toggle: toggle, windowMinutes: windowMinutes, windowStart: ws, windowEnd: we,
                                       sentence: sentence, ringer: ringer, silentWarning: silent, noPlanReason: nil)
        case .failure(let m)?:
            return SmartWakeBlockState(toggle: toggle, windowMinutes: windowMinutes, windowStart: nil, windowEnd: nil,
                                       sentence: "No wake plan tonight.", ringer: ringer, silentWarning: silent,
                                       noPlanReason: m.reason)
        case nil:
            return SmartWakeBlockState(toggle: toggle, windowMinutes: windowMinutes, windowStart: nil, windowEnd: nil,
                                       sentence: "No wake plan tonight.", ringer: ringer, silentWarning: silent,
                                       noPlanReason: "No 'must be up by' for tomorrow, so no wake plan (set one in Tonight)")
        }
    }

    private static func hm(_ d: Date, _ cal: Calendar) -> String {
        ClockText.hm(d, timeZone: cal.timeZone)          // 12-hour (W10)
    }
}
