import Foundation
import MGContext
import MGDomain
import MGSignal

// Wave 4 (#77, 2026-10-11): an EXPERIMENTAL SpO₂ reading on demand. No strap command takes one (#62), so this holds the
// existing live raw optical (108 [01 01] / [01 00], rule 5, only while the raw-optical switch is on) for 60 s and
// computes the ratio of ratios on the red / IR blocks (MGSignal ALG022Spot). The blocks come from the PC's LED
// experiment when it named a pair, else OpenStrap's unproven claim; the metric says which. Shown as an experimental
// estimate (spo2_pct, ALG-022:spot, research tier) — never as a measurement.

extension AppModel {
    static let spo2SpotSeconds: TimeInterval = 60

    func measureSpO2Now() async {
        guard !isSample else {
            let reason = "Sample data is on — the strap is not asked for raw optical."
            showNotice(reason)
            await appendTestRun(kind: .spo2, at: clock.now, result: reason, ok: false)
            return
        }
        guard settings.rawOpticalOn else {
            let reason = "Turn on Raw optical in Strap & sync first (it uses strap battery)."
            showNotice(reason)
            await appendTestRun(kind: .spo2, at: clock.now, result: reason, ok: false)
            return
        }
        guard spo2SpotUntil == nil else {
            let reason = "An SpO2 test is already running."
            showNotice(reason)
            await appendTestRun(kind: .spo2, at: clock.now, result: reason, ok: false)
            return
        }
        let start = clock.now
        let token = UUID()
        spo2SpotRun = token
        spo2SpotUntil = start.addingTimeInterval(Self.spo2SpotSeconds)
        applyRawOptical()
        showNotice("Measuring SpO₂ (experimental) — keep still for about a minute.")
        await refresh()
        try? await Task.sleep(for: .seconds(Self.spo2SpotSeconds + 2))
        guard spo2SpotRun == token else { return }        // R9f: cancelled while waiting; Cancel already cleaned up
        spo2SpotUntil = nil
        applyRawOptical()
        try? await Task.sleep(for: .seconds(5))           // the last live records reach the store
        guard spo2SpotRun == token else { return }
        spo2SpotRun = nil
        let offset = strapInfo?.clockOffsetSeconds ?? 0
        let from = Int64((start.timeIntervalSince1970 + offset).rounded(.down)) - 2
        let recs = ((try? await services.store.r20Records(from: from, to: from + Int64(Self.spo2SpotSeconds) + 10,
                                                           strapId: nil)) ?? []).filter { $0.source == "live" }
        let channels = LedExperiment.redIR(LedExperiment.status(lastSnapshot?.pcResults ?? []))
        let est = ALG022Spot.estimate(records: recs, red: channels.red, ir: channels.ir)
        let now = clock.now
        let m = ALG022Spot.metric(est, basis: channels.basis, at: now)
        do {
            _ = try await services.store.upsertMetrics([m], day: LocalDay(date: now, calendar: calendar))
        } catch {
            showNotice("SpO₂ spot reading not saved: \(error)")
        }
        switch est {
        case .success(let e):
            let line = "SpO2 about \(Int(e.spo2.rounded())) % - estimate, not checked against WHOOP"
            showNotice(line)
            await appendTestRun(kind: .spo2, at: now, result: line, ok: true)
        case .failure(let why):
            showNotice("SpO₂ spot reading: no value — \(why.reason)")
            await appendTestRun(kind: .spo2, at: now, result: why.reason, ok: false)
        }
        await refresh()
    }

    /// R9f (T10022 leftover, UI-SCRUB-B S10): Settings › Tests › SpO₂ test › Cancel. Ends the 60 s hold on raw optical now
    /// (the raw-optical switch decides again), drops the run token so the waiting run stops without computing, and saves a
    /// "cancelled" row so the Tests list and the view's "Measuring…" state both end.
    func cancelSpO2Now() async {
        guard spo2SpotRun != nil else { return }
        spo2SpotRun = nil
        spo2SpotUntil = nil
        applyRawOptical()
        let reason = "SpO₂ test cancelled."
        showNotice(reason)
        await appendTestRun(kind: .spo2, at: clock.now, result: reason, ok: false)
        await refresh()
    }
}
