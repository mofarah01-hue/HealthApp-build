#if DEBUG
import SwiftUI
import MGContext
import MGDesign
import MGDomain

// Xcode previews of the Live tab: normal, strap off (blank with the reason), workout mode, a stalled stream, the
// largest accessibility text size, and every theme. All values are SAMPLE (`sample: true`), so the SAMPLE banner
// shows on each. Taps print their intent to the console.

struct LivePreviewHost: View {
    let state: LiveState
    let theme: ThemeName

    init(_ state: LiveState, theme: ThemeName = .cream) {
        var state = state
        if state.broadcast.detail == nil {
            state.broadcast.detail = "Shares heart rate with compatible gym kit and other apps. Uses a little strap battery. Strap reports: off."
        }
        self.state = state
        self.theme = theme
    }

    var body: some View {
        LiveView(state: state) { intent in print("Live intent:", intent) }
            .mgTheme(theme)
    }
}

#Preview("Live · Day · connected") { LivePreviewHost(.preview) }
#Preview("Live · golden") { LivePreviewHost(.preview, theme: .creamGolden) }
#Preview("Live · Night · connected") { LivePreviewHost(.preview, theme: .emerald) }
#Preview("Live · Emerald low") { LivePreviewHost(.preview, theme: .emeraldLow) }
#Preview("Strap off · blank with the reason") { LivePreviewHost(.previewStrapOff12Hour) }
#Preview("HR only · blank tiles") { LivePreviewHost(.previewHROnly) }
#Preview("Bluetooth off · Open Settings") { LivePreviewHost(.previewBluetoothOff) }
#Preview("Wave rows · on") { LivePreviewHost(.previewWaves(on: true), theme: .emerald) }
#Preview("Wave rows · off · Streams 0 of 3") { LivePreviewHost(.previewWaves(on: false)) }
#Preview("Workout mode · golden") { LivePreviewHost(.previewWorkout, theme: .creamGolden) }
#Preview("Workout mode · Emerald") { LivePreviewHost(.previewWorkout, theme: .emerald) }

/// Workout running but the strap is off: the reason shows, the controls stay.
#Preview("Workout · strap off mid-session") {
    var s = LiveState.previewWorkout
    s.blankReason = "Strap's off your wrist since 5:52 PM — heart rate is paused."
    if var w = s.workout {
        w.heartRate = .blank(reason: "strap off", receipt: nil)
        w.zone = nil
        s.workout = w
    }
    return LivePreviewHost(s)
}

/// Workout with no max HR known: the HR map draws the trace and says why there is no shading.
#Preview("Workout · no zone edges") {
    var s = LiveState.previewWorkout
    if var w = s.workout {
        w.zoneEdgesBpm = nil
        w.zoneBasis = nil
        s.workout = w
    }
    return LivePreviewHost(s)
}

/// No pulse wave and too few clean beats: each chart says why.
#Preview("Empty charts") {
    var s = LiveState.preview
    s.pulseWave = []
    s.pulseQuality = nil
    s.tachogram = []
    s.rmssd = .previewBlank
    return LivePreviewHost(s)
}

#Preview("Largest text · Live") {
    LivePreviewHost(.preview)
        .environment(\.dynamicTypeSize, .accessibility3)
}

#Preview("Largest text · workout") {
    LivePreviewHost(.previewWorkout)
        .environment(\.dynamicTypeSize, .accessibility3)
}

private extension LiveState {
    static var previewStrapOff12Hour: LiveState {
        var state = LiveState.previewStrapOff
        state.blankReason = "Strap's off your wrist — nothing to show live. Off since 3:12 PM."
        return state
    }

    static var previewHROnly: LiveState {
        var state = LiveState.preview
        let reason = "needs a few minutes of clean beats (have 0)"
        state.streamChip = StreamChipState(text: "HR only", tone: .warn)
        state.rmssd = .blank(reason: reason, receipt: nil)
        state.autonomicLoad = .blank(reason: reason, receipt: nil)
        state.rmssdTile = LiveTileState(kind: .grey, text: "—", reason: "Nothing to show yet: too few clean beats (have 7, need 20)",
                                        note: "no clean 5-min window yet")
        state.loadTile = LiveTileState(kind: .grey, text: "about usual", reason: "No clean 5-minute window yet.",
                                       note: "from stored days · last stored value, Nov 4")
        state.autonomicLevel = nil
        state.stressToday = .blank(reason: reason, receipt: nil)
        return state
    }

    static var previewBluetoothOff: LiveState {
        var state = LiveState.previewStrapOff
        state.streamChip = StreamChipState(text: "HR only", tone: .warn)
        state.blankReason = "Bluetooth is off. Turn it on in Settings to reconnect the strap."
        state.blankReasonNeedsSettings = true
        return state
    }

    static func previewWaves(on: Bool) -> LiveState {
        var state = LiveState.preview
        let ppg = ToggleState(id: "rawOptical", title: "Raw PPG (R20)", isOn: on,
                              intent: .setRawOptical(!on))
        let motion = ToggleState(id: "rawMotion", title: "100 Hz motion", isOn: on,
                                 intent: .ecgMotion(.setRawMotion(!on)))
        let ecg = ToggleState(id: "ecg", title: "ECG (research)", isOn: false,
                              intent: .ecgMotion(.setEcgSwitch(true)))
        state.streamToggles = [ppg, motion, ecg]
        state.streamsMaster = StreamsMasterState(
            text: "Streams: \(on ? 2 : 0) of 3 on", title: "Turn all on",
            intents: on ? [ecg.intent] : [ppg.intent, motion.intent, ecg.intent], enabled: true)

        let ppgWaves = on ? [
            OpticalWave(id: 0, label: "Green · block 0 · slot A", samples: previewWave(phase: 0)),
            OpticalWave(id: 2, label: "Red · block 1 · slot A", samples: previewWave(phase: 4)),
            OpticalWave(id: 6, label: "IR · block 3 · slot A", samples: previewWave(phase: 8)),
        ] : []
        let motionWaves = on ? [
            OpticalWave(id: 0, label: "Motion size (R21)", samples: previewWave(phase: 12)),
        ] : []
        state.waveRows = [
            LiveWaveRow(
                id: "ppg", title: ppg.title,
                note: "last 5 s, ends now · raw counts, no unit · decoded, untested", toggle: ppg,
                waves: ppgWaves, reason: on ? nil : "Off. Tap the switch to start it."),
            LiveWaveRow(
                id: "motion", title: motion.title,
                note: "last seconds, ends now · raw counts, no unit", toggle: motion,
                waves: motionWaves, reason: on ? nil : "Off. Tap the switch to start it."),
            LiveWaveRow(
                id: "ecg", title: ecg.title, note: "research tier · wrist ECG, finger on the sensor",
                toggle: ecg, reason: "Off. Tap the switch to start it."),
        ]
        return state
    }

    static func previewWave(phase: Int) -> [Double] {
        (0..<120).map { index in
            let x = Double((index + phase) % 24) / 24
            return x < 0.2 ? x * 5 : max(0, 1 - (x - 0.2) * 1.25)
        }
    }
}
#endif
