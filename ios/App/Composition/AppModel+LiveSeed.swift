import Foundation
import MGContext
import MGDomain
import MGStore

// #35 (Mo 2026-10-11: "as I open it's there scrolling live, like the HR in the WHOOP app"). The Live tab's charts used
// to start empty and fill beat by beat. Now, whenever live data becomes wanted (the Live tab, a guided flow or a
// workout turns the realtime toggles on) and when the app comes back to the front with it on screen, ONE bounded store
// read — the last 10 min of HR and R-R, HR back to a running workout's start (at most 3 h) — goes under the live beats
// (LiveBeatBuffer.seed → MGContext LiveSeed). Nothing per frame: the 1-s live refresh only slices the buffer.

extension AppModel {
    /// Not more often than this (switching tabs back and forth must not read the store every time).
    static let liveSeedGap: TimeInterval = 20
    /// The HR line's span on the Live tab (LiveHRTrace.window in the UI).
    static let liveTraceWindow: TimeInterval = 300

    func seedLive() {
        guard !isSample else { return }
        let now = clock.now
        if let at = liveSeededAt, now.timeIntervalSince(at) >= 0, now.timeIntervalSince(at) < Self.liveSeedGap { return }
        liveSeededAt = now
        let to = Int64(now.timeIntervalSince1970)
        let rrFrom = to - Int64(LiveBeatBuffer.keep)
        var hrFrom = rrFrom
        if let w = sessions.workout {
            hrFrom = min(hrFrom, max(Int64(w.start.timeIntervalSince1970), to - 3 * 3600))
        }
        let store = services.store
        let window = Int64(Self.liveTraceWindow)
        Task { [weak self] in
            do {
                // Wave W11: every stored HR source — live / history / 0x2A37 samples and history R18 seconds.
                let hr = try await store.hrSamples(from: hrFrom, to: to) + store.r18HeartRates(from: hrFrom, to: to)
                let rr = try await store.rrIntervals(from: rrFrom, to: to)
                // Nothing stored in the window before now: read the newest stored stretch instead (LiveBackfill).
                var tail: (hr: [HRPoint], rr: [RRPoint], end: Int64)?
                if let newest = try await store.newestHRSecond(atOrBefore: to), newest < to - window {
                    let tailHR = try await store.hrSamples(from: newest - window, to: newest)
                        + store.r18HeartRates(from: newest - window, to: newest)
                    let tailRR = try await store.rrIntervals(from: newest - window, to: newest)
                    tail = (tailHR, tailRR, newest)
                }
                guard let self else { return }
                self.liveBuffer.seed(storedHR: hr, storedRR: rr, now: self.clock.now)
                if let tail {
                    self.liveBuffer.setStoredTail(hr: tail.hr, rr: tail.rr,
                                                  end: Date(timeIntervalSince1970: TimeInterval(tail.end)),
                                                  window: Self.liveTraceWindow)
                } else {
                    self.liveBuffer.clearStoredTail()
                }
                if self.liveOnScreen { self.refreshLive() }
            } catch {
                self?.services.strap.noteExternal("live pre-fill: couldn't read stored HR / R-R — \(error)")
            }
        }
    }

    /// The HR line for the snapshot (stored + live, the last 5 min; wave W11: or the newest stored stretch).
    func liveHRTrace() -> [LiveHRPoint] {
        guard !isSample else { return [] }
        return liveBuffer.hrTrace(now: clock.now, window: Self.liveTraceWindow, plan: liveBackfillPlan())
    }

    /// Wave W11: whether the Live charts show the newest stored stretch (and its labels).
    func liveBackfillPlan() -> LiveBackfill.Plan? {
        isSample ? nil : liveBuffer.backfillPlan(now: clock.now, window: Self.liveTraceWindow, calendar: calendar)
    }
}
