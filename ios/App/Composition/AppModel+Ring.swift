import Foundation
import MGBLE
import MGContext
import MGDomain

// 0.6.0.3 "Ring live" (Mo, Oct 26 2026): the ring as an input device beside the WHOOP strap. Settings keeps the choice
// (`settings.inputDevice`); `InputDeviceRule` (MGContext) turns it plus what is connected into the active device.
// Ring beats reach the Live tab only while the ring is the active device; the strap-only handlers (wrist, raw optical,
// auto raw, alarms) never see them. Steps are kept in RingBridge and shown in Settings, not stored.

extension AppModel {
    func wireRing() {
        let ring = RingBridge.shared
        ring.onBeat = { [weak self] beat in self?.ringBeat(beat) }
        ring.onEvent = { [weak self] at, dir, char, data, note in
            self?.ringLab.ingest(at: at, dir: dir, char: char, data: data, note: note)
        }
        ring.onStateChange = { [weak self] in
            guard let self else { return }
            self.ringLab.refreshConnection()
            Task { await self.refresh() }
        }
        ring.liveWanted = { [weak self] in
            guard let self else { return false }
            return self.liveOnScreen && self.activeInput == .ring
        }
    }

    /// True while the strap link is up (ready or downloading history).
    var strapLinkUp: Bool {
        switch services.strap.state {
        case .ready, .downloadingHistory: return true
        default: return false
        }
    }

    var activeInput: ActiveInput {
        InputDeviceRule.active(setting: settings.inputDevice, strapLinkUp: strapLinkUp,
                               ringConnected: RingBridge.shared.isConnected)
    }

    /// Same handlers the strap uses for the live display, minus the strap-only ones.
    private func ringBeat(_ beat: LiveBeat) {
        guard !isSample, activeInput == .ring else { return }
        liveBeatSource = nil              // 0.6.0.12
        liveBuffer.append(beat)
        keepUpBeat()
        liveBeatArrived()
    }

    /// Auto or Ring: the ring is connected and kept alive; WHOOP: the ring is left alone.
    func applyInputDevice() {
        if settings.inputDevice == .whoop || isSample {
            RingBridge.shared.stopAuto()
        } else {
            RingBridge.shared.startAuto()
        }
    }

    func setInputDevice(_ device: InputDevice) async {
        guard !isSample else { return showNotice("Sample data is on — the input device is not changed.") }
        settings.inputDevice = device
        await saveState()
        applyInputDevice()
        await refresh()
    }

    /// Fills the Settings lines for the Input device row.
    func applyRingInfo(_ info: inout StrapSyncInfo) {
        let ring = RingBridge.shared
        info.inputDevice = settings.inputDevice
        info.strapLinkUp = strapLinkUp
        info.ringConnected = ring.isConnected
        info.ringName = ring.displayName
        if let s = ring.lastSteps {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "h:mm a"
            info.ringStepsLine = "Ring steps: \(s.steps) · \(s.distanceM) m · at \(f.string(from: s.at))"
        }
    }
}
