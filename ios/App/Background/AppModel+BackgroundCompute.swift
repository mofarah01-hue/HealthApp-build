import Foundation
import MGBLE
import MGContext
import MGDomain
import MGStore
import MGSync

// T9995 / T10008 (2026-10-17, audit section 2 item 2): what the `.compute` BGProcessingTask does. The old job ran three days of
// full night + day pipelines in the background: the heaviest run of the day, the one iOS cut off at 90 s of CPU in 92 s. Now:
//   1. raw streams keep the app awake (the strap link is up and raw optical or raw motion is on): do not compute at all. The
//      app is already running, its own light run and the wake chain do the night, and the PC owns the heavy optical features;
//   2. otherwise ask the PC to run last night (POST /v1/run-night, uploading the day first when it has none) and stop: the
//      results come back with the next sync;
//   3. only when the PC cannot take it (not paired, not reachable, refused): last night on the phone, and only that (today's
//      wake day), light like every other background run.
// Then, still on power, the database maintenance (`runMaintenance`, MGStore; AppModel+Maintenance.swift) when the run was not
// cancelled. It runs whether or not step 1 skipped the compute.
// Every decision is written to the compute log and to this run's note in Settings > Usage > Background tasks.

extension AppModel {
    func backgroundComputeJob() async {
        let today = LocalDay(date: clock.now, calendar: calendar)
        func say(_ text: String) {
            BackgroundRunLog.note(.compute, text)
            ComputeLog.shared.append(.note, "background compute: " + text, at: clock.now)
        }
        if isSample {
            say("skipped: sample data is on")
            return
        }
        let streams = StrapStreamPolicy.keepsRealtimeOn(rawMotionOn: settings.rawMotionOn, rawOpticalOn: settings.rawOpticalOn,
                                                        opticalNightsOnly: settings.rawOpticalNightsOnly, sample: isSample)
        var linkUp = false
        if case .ready = strapLinkState { linkUp = true }
        if streams && linkUp {
            say("skipped: raw streams keep the app awake (the strap link is up), so its own light run and the wake chain do the night")
        } else {
            await backgroundNightViaPC(today: today, say: say)
        }
        guard !Task.isCancelled else { return }
        // r9u: not skipped by the streaming rule above; the same path as the foreground one, with its own report in the log.
        say(await runStoreMaintenance(reason: "charging background task", allowFullVacuum: true))
    }

    private func backgroundNightViaPC(today: LocalDay, say: (String) -> Void) async {
        let credentials = KeychainCredentialStore()
        var answer = await PCNightRun.request(date: today, credentials: credentials)
        if case .notStored = answer, !Task.isCancelled {
            say("the PC has no drop for \(today.iso): uploading first")
            _ = await services.syncCoordinator.syncNow()
            answer = await PCNightRun.request(date: today, credentials: credentials)
        }
        guard !Task.isCancelled else { return say("cancelled while asking the PC") }
        let why: String
        switch answer {
        case .state(let s):
            say("asked the PC to run \(today.iso) (\(s)); its results come with the next sync, no compute on the phone")
            return
        case .notPaired: why = "no PC is paired"
        case .unreachable(let w): why = "the PC is not reachable (\(w))"
        case .notStored: why = "the PC still has no drop for \(today.iso)"
        case .refused(let w): why = "the PC refused (\(w))"
        }
        say("\(why): last night only, on the phone")
        let report = await services.compute.runNow(.background, days: [today])
        say("local run: \(report.line)")
    }
}
