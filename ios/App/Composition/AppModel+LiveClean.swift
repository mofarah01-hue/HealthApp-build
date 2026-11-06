import Foundation
import MGContext
import MGDomain
import MGSignal

// P9729 (job 12, Oct 14, 2026): the ALG-144 cleaned PPG wave beside the raw Live pulse wave. The window, the pace gate
// and the words are MGContext (`LiveCleanWindow`, `LivePresenter.cleanChip/cleanNote`, tested there); this file only runs
// ALG-144 off the main thread and maps its last window. Respects the Live pace limit (R-094, T9723): it is called from
// `liveInput()` on the existing UI tick, runs at most once per new strap second, one run at a time, never per packet.

struct LiveCleanState {
    var result: LiveCleanPulse?
    var lastRunTs: Int64?
    var inFlight = false
}

extension AppModel {
    /// What the Live tab shows for the cleaned wave now; starts a background run when a newer second arrived.
    func liveCleanPulse(records: [R20Record]) -> LiveCleanPulse {
        let motion = motionTrace.lastAt.map { clock.now.timeIntervalSince($0) < 5 } == true ? motionTrace.seconds : []
        switch LiveCleanWindow.assemble(records: records, motion: motion) {
        case .waiting(let why):
            return .waiting(why)
        case .ready(let w):
            if LiveCleanWindow.shouldRun(newestTs: w.newestTs, lastRunTs: liveClean.lastRunTs, inFlight: liveClean.inFlight) {
                liveClean.inFlight = true
                liveClean.lastRunTs = w.newestTs
                Task { [weak self] in
                    let r = await Task.detached(priority: .utility) {
                        Self.liveCleanMap(ALG144.analyse(r20: w.records, motion: w.motion), newestTs: w.newestTs)
                    }.value
                    guard let self else { return }
                    self.liveClean.result = r
                    self.liveClean.inFlight = false
                }
            }
            // The last result while it is at most 3 s behind the newest record; otherwise say a run is under way.
            if let r = liveClean.result, w.newestTs - r.newestTs <= 3 { return r }
            return .waiting("ALG-144 is cleaning the newest \(LiveCleanWindow.seconds) s")
        }
    }

    /// ALG-144's last window → what Live shows: the chosen slot's band-passed trace inside that window, the newest
    /// pulse estimate, the state, the named gates and their reasons.
    nonisolated static func liveCleanMap(_ out: ALG144.Output, newestTs: Int64) -> LiveCleanPulse {
        guard let w = out.windows.last else {
            return LiveCleanPulse(wave: [], hrBpm: nil, state: ALG144.State.unavailable.rawValue, gates: [],
                                  reasons: ["ALG-144 returned no window"], newestTs: newestTs)
        }
        let wave = w.slot.map { s in out.cleanSeries(for: s).filter { $0.t >= w.start && $0.t < w.end }.map(\.value) } ?? []
        let hr = w.state == .unavailable ? nil : out.hrEstimated.last?.bpm
        return LiveCleanPulse(wave: w.state == .unavailable ? [] : wave, hrBpm: hr, state: w.state.rawValue,
                              gates: w.gates.map(\.rawValue), reasons: w.reasons, slot: w.slot, newestTs: newestTs)
    }
}
