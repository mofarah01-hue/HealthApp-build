import Foundation
import MGBLE
import MGContext
import MGDomain

// 0.6.0.12 — "Read WHOOP 5.0 heart-rate broadcast" (Strap & sync). The reader (`HRBroadcastReader`, MGBLE) is its own tiny link
// with its own CoreBluetooth central: it never pairs, never writes, never touches the WHOOP 4.0 or MG links. Here: the switch,
// the one chosen sensor (kept in settings), the one-source rule (`HRReadSourceRule`), and where its beats go.
//
// WRITTEN, NOT COMPILED here (the app target is built with xtool).

extension AppModel {
    static let hrReadRestoreIdentifier = "mgapp.ble.central.hrread"

    var whoop4LinkUp: Bool {
        switch services.whoop4.state {
        case .ready, .downloadingHistory: return true
        default: return false
        }
    }

    /// The reader, made the first time the switch is on (its central only exists then).
    private func hrReaderMade() -> HRBroadcastReader {
        if let r = hrReader { return r }
        let r = HRBroadcastReader(transport: CoreBluetoothTransport(restoreIdentifier: Self.hrReadRestoreIdentifier), clock: clock)
        r.onBeat = { [weak self] beat in self?.hrReadBeat(beat) }
        r.onChange = { [weak self] in Task { await self?.refresh() } }
        r.onChosen = { [weak self] choice in
            guard let self else { return }
            self.settings.hrReadChoiceID = choice?.id.uuidString
            self.settings.hrReadChoiceName = choice?.name
            Task { await self.saveState() }
        }
        hrReader = r
        return r
    }

    private var hrReadSavedChoice: HRBroadcastChoice? {
        guard let s = settings.hrReadChoiceID, let id = UUID(uuidString: s) else { return nil }
        return HRBroadcastChoice(id: id, name: settings.hrReadChoiceName)
    }

    /// Applies the switch and the one-source rule: runs, holds (and says why) or stops the reader.
    func applyHRRead() {
        let decision = HRReadSourceRule.decide(wanted: settings.hrReadOn, sample: isSample,
                                               whoop4LinkUp: whoop4LinkUp, mgLinkUp: strapLinkUp)
        switch decision {
        case .off:
            hrReader?.stop()
        case .hold(let why):
            let r = hrReaderMade()
            if r.state == .off { r.start(chosen: hrReadSavedChoice) }
            r.setHeld(reason: why)
        case .run:
            let r = hrReaderMade()
            if r.state == .off { r.start(chosen: hrReadSavedChoice) }
            r.setHeld(reason: nil)
        }
    }

    func hrReadAction(_ action: HRReadAction) async {
        switch action {
        case .setOn(let on):
            guard !isSample else { return showNotice("Sample data is on — the broadcast reader is not changed.") }
            settings.hrReadOn = on
            await saveState()
            applyHRRead()
        case .pick(let id):
            guard let uuid = UUID(uuidString: id) else { return }
            hrReader?.choose(uuid)
        case .forget:
            hrReader?.forget()
        case .rescan:
            hrReader?.rescan()
        }
        await refresh()
    }

    /// Beats go to the Live path only while the rule says this source is the one: never beside a 4.0 / MG link, never while the
    /// ring is the active input. The strap-only handlers (wrist, alarms, raw streams) never see them: it is a heart rate only.
    private func hrReadBeat(_ beat: LiveBeat) {
        guard !isSample, activeInput != .ring,
              HRReadSourceRule.decide(wanted: settings.hrReadOn, sample: isSample,
                                      whoop4LinkUp: whoop4LinkUp, mgLinkUp: strapLinkUp) == .run else { return }
        liveBeatSource = HRBroadcastReader.beatSource
        liveBuffer.append(beat)
        keepUpBeat()
        liveBeatArrived()
    }

    func hrReadInfo() -> HRReadInfo {
        var i = HRReadInfo()
        i.wanted = settings.hrReadOn
        i.whoop4LinkUp = whoop4LinkUp
        i.mgLinkUp = strapLinkUp
        i.chosenID = settings.hrReadChoiceID
        i.chosenName = settings.hrReadChoiceName
        guard let r = hrReader else { return i }
        switch r.state {
        case .off: i.phase = .off
        case .held(let why): i.phase = .held; i.detail = why
        case .radio(let why): i.phase = .radio; i.detail = why
        case .choosing: i.phase = .choosing
        case .searching: i.phase = .searching
        case .connecting: i.phase = .connecting
        case .reading: i.phase = .reading
        }
        i.candidates = r.candidates.map { HRReadCandidate(id: $0.id.uuidString, name: $0.name, rssi: $0.rssi) }
        i.beats = r.beats
        i.lastBeatAt = r.lastBeatAt
        i.lastError = r.lastError
        if let c = r.chosen { i.chosenID = c.id.uuidString; i.chosenName = c.name }
        return i
    }
}
