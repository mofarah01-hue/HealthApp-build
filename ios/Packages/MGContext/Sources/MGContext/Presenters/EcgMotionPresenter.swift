import Foundation
import MGDomain

/// Wave W8 (2026-10-11): the ECG and raw-motion switches (Strap & sync) and the raw-motion block of the Live tab.

/// What the app knows about the two families (filled in `StrapSyncInfo.ecgMotion`).
public struct EcgMotionInfo: Equatable, Sendable {
    public var ecgWanted: Bool = false
    /// "left" / "right".
    public var wrist: String = "left"
    /// MGBLE `EcgStatus.phase` raw value ("idle", "running", …) and its last outcome in words.
    public var ecgPhase: String = "idle"
    public var ecgOutcome: String?
    public var ecgStopOwed: Bool = false
    public var motionWanted: Bool = false
    /// 81 + 106 ON in effect on this connection.
    public var motionOn: Bool = false
    public var motionSeconds: Int = 0
    public var motionLastAt: Date?
    public var motionSessionUntil: Date?
    public var motionStopped: String?
    /// The last ~10 s of accelerometer magnitude, raw counts (4,096 ≈ 1 g by noop's convention, checked per day), oldest
    /// first; empty when nothing arrived recently.
    public var trace: [Double] = []

    public init() {}
}

/// Strap & sync rows for the two switches.
public struct EcgMotionSection: Equatable, Sendable {
    public var ecg: ToggleState
    public var ecgLine: String
    /// "Worn on the left wrist" / "… right": one action switches it.
    public var wrist: ActionState
    public var motion: ToggleState
    public var motionLine: String

    public init(ecg: ToggleState, ecgLine: String, wrist: ActionState, motion: ToggleState, motionLine: String) {
        self.ecg = ecg
        self.ecgLine = ecgLine
        self.wrist = wrist
        self.motion = motion
        self.motionLine = motionLine
    }
}

/// The Live tab's raw-motion block: shown while raw motion streams or its switch is on.
public struct LiveMotionState: Equatable, Sendable {
    /// "Raw motion · 100 Hz · 312 s · last 09:40" / "on — waiting for the strap".
    public var line: String
    /// Accelerometer magnitude, raw counts, oldest first (drawn as a line; no unit on the axis).
    public var trace: [Double]
    /// "Record 2 min", "Record 10 min" or "Stop session (ends 09:52)".
    public var actions: [ActionState]

    public init(line: String, trace: [Double], actions: [ActionState]) {
        self.line = line
        self.trace = trace
        self.actions = actions
    }
}

public enum EcgMotionPresenter {
    /// "left" / "right" only: the strap's wrist as a word, whatever is stored.
    static func wristWord(_ stored: String) -> String {
        stored == "right" ? "right" : "left"
    }

    public static func strapSection(_ s: PresenterSnapshot, link: StrapStatus.Link) -> EcgMotionSection {
        let i = s.strapSync.ecgMotion
        let why: String? = s.mgOnlyReason ?? (s.sample ? "Sample data is on." : nil)
        let ecg = ToggleState(
            id: "ecg", title: "ECG (MG)",
            detail: "Lets the Live tab take a timed ECG reading: the app tells the strap which wrist (command 123), turns "
                + "ECG on (commands 139 and 125) and starts it (command 124); it stops again with commands 124, 125 and "
                + "139. Nothing is sent until you start a reading.",
            isOn: i.ecgWanted, enabled: why == nil, disabledReason: why, intent: .ecgMotion(.setEcgSwitch(!i.ecgWanted)))
        var ecgLine = i.ecgWanted ? "on — start a reading from the Live tab" : "off"
        if i.ecgPhase != "idle" { ecgLine = "reading: \(i.ecgPhase)" }
        if i.ecgStopOwed && i.ecgPhase == "idle" { ecgLine = "a stop is owed — sent at the next connection" }
        if let o = i.ecgOutcome, i.ecgWanted, i.ecgPhase == "idle", !i.ecgStopOwed { ecgLine += " · last: \(o)" }
        // Mo 2026-10-14: the wrist line is always a word. The app reads anything but "right" as left (AppModel+EcgMotion),
        // so the line says the same and never echoes a stored value.
        let side = EcgMotionPresenter.wristWord(i.wrist)
        let other = side == "right" ? "left" : "right"
        let wrist = ActionState(id: "ecgWrist", title: "Strap worn on the \(side) wrist · switch to \(other)",
                                intent: .ecgMotion(.setWrist(other)), enabled: why == nil, disabledReason: why)
        // 0.6.0.12 (Mo, Nov 5: "need to be able to control raw optical and motion"): raw motion works on the 4.0 too, through
        // command 63 (whoop4-wire 6), so only Sample mode greys it; ECG above stays MG only.
        let motionWhy: String? = s.sample ? "Sample data is on." : nil
        let motion = ToggleState(
            id: "rawMotion", title: "Raw motion (100 Hz, uses strap battery)",
            detail: s.whoop4Selected
                ? "Streams the WHOOP 4.0's accelerometer and gyro (100 samples per axis each second, decoded, untested) while "
                    + "the switch is on. Sends 63 [01]; off with 63 [00]. The same command also starts raw optical."
                : "Streams the strap's six-axis IMU (R21) while the app is open, or for a session you start on the Live "
                    + "tab. Sends 81 [01] + 106 [01 01]; off again with 82 [01] + 106 [01 00].",
            isOn: i.motionWanted, enabled: motionWhy == nil, disabledReason: motionWhy,
            intent: .ecgMotion(.setRawMotion(!i.motionWanted)))
        return EcgMotionSection(ecg: ecg, ecgLine: ecgLine, wrist: wrist, motion: motion,
                                motionLine: motionLine(s, link: link))
    }

    static func motionLine(_ s: PresenterSnapshot, link: StrapStatus.Link) -> String {
        let i = s.strapSync.ecgMotion
        if let stopped = i.motionStopped, !i.motionOn { return stopped }
        guard i.motionWanted else { return "off" }
        guard link == .connected else { return "on — waiting for the strap" }
        guard i.motionOn else { return "on — starts when the app is open or a session runs" }
        var line = "streaming · \(i.motionSeconds) s" + (i.motionLastAt.map { " · last \(s.hm($0))" } ?? " · none yet")
        if let until = i.motionSessionUntil { line += " · session until \(s.hm(until))" }
        return line
    }

    /// nil when the switch is off and nothing streams.
    public static func live(_ s: PresenterSnapshot) -> LiveMotionState? {
        let i = s.strapSync.ecgMotion
        guard i.motionWanted || i.motionOn else { return nil }
        let link = s.inputs.strap.link
        var actions: [ActionState] = []
        if let until = i.motionSessionUntil {
            actions.append(ActionState(id: "motionStop", title: "Stop session (ends \(s.hm(until)))",
                                       intent: .ecgMotion(.rawMotionSession(minutes: 0))))
        } else {
            let why: String? = link == .connected ? nil : "Needs the strap connected."
            for m in [2, 10, 30] {
                actions.append(ActionState(id: "motion\(m)", title: "Record \(m) min", intent: .ecgMotion(.rawMotionSession(minutes: m)),
                                           enabled: why == nil, disabledReason: why))
            }
        }
        return LiveMotionState(line: "Raw motion · " + motionLine(s, link: link), trace: i.trace, actions: actions)
    }

    /// The Live tab's ECG tile.
    static func ecgAction(_ s: PresenterSnapshot, streaming: Bool) -> ActionState {
        let i = s.strapSync.ecgMotion
        let why: String?
        if let mgOnly = s.mgOnlyReason {
            why = mgOnly
        } else if s.sample {
            why = "Sample data is on."
        } else if !i.ecgWanted {
            why = "Turn on ECG in Strap & sync first."      // wave W11: on by default since 2026-10-11 21:43
        } else if s.inputs.strap.link != .connected {
            why = "Needs the strap connected."
        } else {
            why = nil
        }
        return ActionState(id: "ecg", title: "ECG reading", intent: .startECG, enabled: why == nil, disabledReason: why)
    }
}
