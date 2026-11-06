import Foundation
import MGDomain

/// History download (ARCHITECTURE §4.4.4). The state machine is `HistoryRun`; this wires it to the link.
extension StrapLink {
    /// Downloads banked history, storing each chunk through `HistorySink` and acking it only after `store`
    /// returns. Throws `.persistStalled` for the rest of a connection on which a store already failed.
    public func downloadHistory() async throws -> HistorySummary {
        guard handshakeDone, let sid = strapId else { throw StrapLinkError.notReady("strap not connected") }
        if let reason = persistStalledReason { throw StrapLinkError.persistStalled(reason) }
        // T9997: a run whose store or ack never returned (app suspended in the background) used to block every later
        // download until the app was restarted. A run silent for `historyRunMaxIdle`, or older than `historyRunMaxAge`,
        // is dead: it is told to stop and replaced.
        if let old = historyRun {
            let now = clock.now
            let idle = now.timeIntervalSince(old.lastActivityAt)
            let age = now.timeIntervalSince(old.startedAt)
            guard HistoryRun.looksDead(idle: idle, age: age, maxIdle: config.timing.historyRunMaxIdle,
                                       maxAge: config.timing.historyRunMaxAge) else {
                throw StrapLinkError.historyInProgress
            }
            logLine("history: the previous download looked dead (\(Int(idle / 60)) min silent, \(Int(age / 60)) min old) — "
                    + "dropped it and starting a new one")
            old.abandon("dropped: no activity for \(Int(idle / 60)) min")
            historyRun = nil
        }
        // Wave W12b: paused while the read-without-deleting test runs (it reads the first chunk without acking it).
        guard historyProbe == nil else { throw StrapLinkError.notReady("the read-without-deleting test is running") }
        // Wave W8: an offload competes with the live ECG trace for the link (noop BLEManager L4474-4508 aborts history
        // before 124 for that reason); history waits until the reading is over.
        guard ecgReading == nil else { throw StrapLinkError.notReady("an ECG reading is running") }

        let run = HistoryRun(channel: channel, sink: historySink, clock: clock, strapId: sid, timing: config.timing,
                             runBudget: config.timing.maxHistoryRunsPerConnection - historyRunsThisConnection,
                             ledger: ackedLedger, log: logLine)
        run.onProgress = { [weak self] progress in self?.setState(.downloadingHistory(progress)) }
        run.onFiftyHz = { [weak self] ts, n in self?.onFiftyHz?(ts, n) }      // r9q: 50 Hz optical windows seen
        run.watchdog = HistoryRun.Watchdog(
            maxSeconds: config.timing.rawOpticalOffloadLimit, maxNoProgress: config.timing.rawOpticalNoProgressLimit,
            armed: { [weak self] in self?.wantRawOptical ?? false },
            tripped: { [weak self] reason in await self?.rawOpticalWatchdogTripped(reason) })
        historyRun = run
        logLine("history: download started (\(historyRunsThisConnection) of "
                + "\(config.timing.maxHistoryRunsPerConnection) runs used on this connection)")
        let summary = await run.execute()
        // T9997 + review Oct 16 2026: a dropped run must not clear its replacement, and its cleanup (raw optical resume, run
        // count, lastHistory, state) belongs to the current run only.
        guard historyRun === run else { return summary }
        historyRun = nil
        streamsQuietSince = clock.now      // T9996: raw streams may have been paused during the download
        // 0.5.8.1 (Oct 15 2026, Mo: raw streams all night with the phone locked): the watchdog stops raw optical only so this
        // download can finish; once it has ended, raw optical comes back on its own instead of staying off until the switch
        // is toggled (the trip used to be cleared only by switching raw optical off and on again).
        if let trip = rawOpticalTrip {
            rawOpticalTrip = nil
            logLine("raw optical: resumed after the download (was stopped: \(trip))")
            await applyRawOptical()
        }
        lastHistory = summary
        // T9997: the cap stops an offload loop (the strap re-serving). A run that brought new rows is not a loop, however
        // it ended (stalled, aborted, cut by the link), so only runs that stored nothing new use the cap up.
        if summary.recordsInserted == 0 { historyRunsThisConnection += run.runsUsed }
        // Wave W11 (2026-10-11): the cap is there to stop an offload loop (the strap re-serving; noop
        // BackfillContinuation's 24 auto-continues per backfill). A download that ended `.complete` drained the strap,
        // so the next one starts with the full budget — a connection kept up all day for 15-min pulls (W11 fix 2)
        // otherwise ran out after 24 runs and every later pull ended `.chunkCap` without asking the strap.
        if summary.endReason == .complete { historyRunsThisConnection = 0 }
        if case .persistStalled(let reason) = summary.endReason { persistStalledReason = reason }
        if handshakeDone, case .downloadingHistory = state { setState(.ready) }
        return summary
    }

    /// Stop a download in flight: ABORT_HISTORICAL_TRANSMITS (20) is a stop request, not a trim — unacked
    /// chunks stay on the strap (noop BLEManager L2668-2700).
    public func abortHistory() {
        historyRun?.abort()
    }
}
