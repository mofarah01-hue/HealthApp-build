import Foundation
import MGBLE
import MGContext
import MGDomain
import MGHealth
import MGSync
import UIKit

// Mo, Nov 6 2026: "if our sleep fails, fallbacks to other sources are important"; a "process button ... on that sleep card ...
// If we detect that you just slept and it's not processed yet, to force it to process now".
//
// 1. `readPhoneAppleSleep`: Apple Health's night read on the phone (read-only HealthKit query; the merge is MGDomain's
//    `PhoneAppleSleep.build`), cached five minutes, handed to the snapshot as `phoneAppleSleep`. Nothing leaves the phone for
//    this read; the existing Apple Health auto-sync is unchanged.
// 2. `processSleepNow`: the "Process now" sheet. Runs `runWakeChain` directly (no `wakeChainCheck`, no attempts cap; the day's
//    attempt counters are left alone) after stopping a stalled history run, with the screen kept awake while it runs.
// 3. `notifyLastNightIfReady`: the "Last night is ready" notification, once a day, naming the device.
// WRITTEN, NOT COMPILED here (the app target is built with xtool).

/// The sheet's state, shared so a run keeps going when the sheet is closed ("Keep going in the background").
@MainActor
final class ProcessNowModel: ObservableObject {
    static let shared = ProcessNowModel()
    @Published var state = ProcessNowState()
    var poll: Task<Void, Never>?
    /// The strap clock time the download reached, for the failure sentence.
    var lastDownloadTail: String?
}

@MainActor
enum PhoneAppleSleepCache {
    static var at = Date.distantPast
    static var value: PhoneAppleSleep?
    static let ttl: TimeInterval = 300
    static let readyDayKey = "sleepready.day"
}

extension AppModel {
    var strapDeviceWords: String { StrapDeviceChoice.stored == .whoop4 ? "WHOOP 4.0" : "strap" }

    // MARK: Apple Health on the phone

    func readPhoneAppleSleep(now: Date) async -> PhoneAppleSleep? {
        guard !isSample, healthState?.isUsable ?? false else { return nil }
        if now.timeIntervalSince(PhoneAppleSleepCache.at) < PhoneAppleSleepCache.ttl { return PhoneAppleSleepCache.value }
        let from = now.addingTimeInterval(-PhoneAppleSleep.lookbackSeconds - 6 * 3600)
        let samples = await HealthKitSleepRead.samples(from: from, to: now.addingTimeInterval(600))
        let night = PhoneAppleSleep.build(samples, now: now)
        PhoneAppleSleepCache.at = now
        PhoneAppleSleepCache.value = night
        return night
    }

    // MARK: Process now

    func processSleepNow() async {
        let model = ProcessNowModel.shared
        guard !model.state.running else { return }                      // a run is going: the sheet just shows it
        let name = strapDeviceWords
        model.state = ProcessNowState(deviceName: name)
        model.lastDownloadTail = nil
        guard !isSample else {
            model.state.end(failure: "Sample data is on, so there is nothing to process.")
            return
        }
        UIApplication.shared.isIdleTimerDisabled = true
        model.state.begin(.connect)

        // A chain already running in the background: wait for it, then run ours.
        var waited = 0
        while WakeChainState.running, waited < 300 {
            model.state.update(.connect, detail: "A run is already going; waiting for it")
            try? await Task.sleep(for: .seconds(3))
            waited += 3
        }
        guard !WakeChainState.running else {
            model.state.finish(.connect, ok: false, detail: "Another run is still going")
            model.state.end(failure: "Another run is still going. Try again in a minute.")
            UIApplication.shared.isIdleTimerDisabled = false
            return
        }
        WakeChainState.running = true

        // A history run that has stopped moving holds the link: stop it first (the abort does not trim the strap).
        if let link = selectedHistoryLink, case .downloadingHistory(let h) = link.state,
           clock.now.timeIntervalSince(h.lastAckAt ?? h.startedAt) >= PresenterSnapshot.downloadStallSeconds {
            link.abortHistory()
            try? await Task.sleep(for: .seconds(3))
        }
        // Up to 30 s for the link to be ready.
        var tries = 0
        while tries < 30 {
            if let link = selectedHistoryLink, case .ready = link.state { break }
            try? await Task.sleep(for: .seconds(1))
            tries += 1
        }
        var connected = false
        if let link = selectedHistoryLink, case .ready = link.state { connected = true }
        model.state.finish(.connect, ok: connected,
                           detail: connected ? "connected" : "The \(name) isn't connected. Using the night as it is on the phone.")

        let now = clock.now
        let day = LocalDay(date: now, calendar: calendar)
        let outcome = await runWakeChain(seen: now, day: day, progress: { stepName, result in
            let m = ProcessNowModel.shared
            switch (stepName, result) {
            case ("history", nil):
                m.state.begin(.download)
                m.poll?.cancel()
                m.poll = Task { @MainActor [weak self] in
                    while !Task.isCancelled {
                        if let self, let h = self.lastInputs?.history {
                            let cal = self.calendar
                            m.lastDownloadTail = h.newestTs.map { MGFormat.time(Date(timeIntervalSince1970: TimeInterval($0)), calendar: cal) }
                            m.state.update(.download, detail: ProcessNowState.downloadDetail(h) { MGFormat.time($0, calendar: cal) })
                        }
                        try? await Task.sleep(for: .seconds(2))
                    }
                }
            case ("history", let r?):
                m.poll?.cancel()
                m.state.finish(.download, ok: r.ok, detail: r.detail)
            case ("compute", nil):
                m.state.begin(.compute)
            case ("compute", let r?):
                m.state.finish(.compute, ok: r.ok, detail: r.ok ? nil : r.detail)
            case ("upload", nil):
                m.state.begin(.send)
            default:
                break
            }
        })
        model.poll?.cancel()

        // The send step is done when the PC's numbers came back; a stop says where.
        model.state.finish(.send, ok: outcome.delivered,
                           detail: outcome.delivered ? "PC Lab · numbers are back" : (outcome.stoppedAt ?? "not finished"))
        var failure: String?
        if let d = model.state.steps.first(where: { $0.id == .download }), d.status == .failed {
            failure = ProcessNowState.downloadFailure(reason: d.detail ?? "The strap stopped answering",
                                                      progress: model.lastDownloadTail)
        } else if !outcome.delivered, let why = outcome.stoppedAt {
            failure = "The night is worked out on the phone, but the PC did not finish: \(why)."
        }
        await refresh()                                                  // the card shows the new night, or the fallback
        if failure != nil, let snap = try? await buildSnapshot(now: clock.now) {
            model.state.fallbackLine = ProcessNowState.fallbackLine(SleepBreakdownPresenter.card(snap))
        }
        model.state.end(failure: failure)
        UIApplication.shared.isIdleTimerDisabled = false
    }

    /// "Send details to the PC": the debug `logs` answer, posted now to the PC Lab (the same files `debug send logs` pulls).
    func sendProcessDetailsToPC() async -> Bool {
        let started = clock.now
        let command = RemoteDebug.Command(id: "app-\(Int(started.timeIntervalSince1970))", kind: RemoteDebug.Kind.logs.rawValue)
        let outcome = await runRemoteDebug(command)
        let answer = RemoteDebug.Answer(id: command.id, kind: command.kind, ok: outcome.ok, startedAt: started,
                                        finishedAt: clock.now, result: outcome.result, error: outcome.error, files: outcome.files)
        guard let body = try? MGJSON.encoder().encode(answer) else { return false }
        return await PCLabDebug.postResult(body, credentials: KeychainCredentialStore())
    }

    // MARK: "Last night is ready"

    /// Once a day, when the card shows our own night: a silent notification naming the device ("from your WHOOP 4.0").
    func notifyLastNightIfReady(day: LocalDay) async {
        guard !isSample, UserDefaults.standard.string(forKey: PhoneAppleSleepCache.readyDayKey) != day.iso,
              let snap = try? await buildSnapshot(now: clock.now) else { return }
        let card = SleepBreakdownPresenter.card(snap)
        guard card.phase == .done, card.durationText != nil else { return }
        UserDefaults.standard.set(day.iso, forKey: PhoneAppleSleepCache.readyDayKey)
        _ = await services.notifyCenter.lastNightReady(day: day.iso, deviceName: strapDeviceWords)
    }
}
