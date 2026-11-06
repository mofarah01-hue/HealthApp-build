import Foundation
import MGBLE
import MGContext
import MGDomain
import MGStore

// 0.6.0.12 — LED settings read on the WHOOP 4.0 (Mo Nov 5 2026), read-only: GET 40, 42, 44 with body `00`; no SET. The "Read LED
// settings" button on the Raw 4.0 screen reads now; the same read runs by itself every 30 minutes from 10 PM to 8 AM (or while
// the app believes Mo is asleep) while the 4.0 is connected. Each reply is stored as raw hex with the time and the wear state
// (raw archive, so the PC gets it too), shown on the Raw 4.0 screen next to the strap's own LED drive bytes (frame 76/78), and
// summarised in the debug channel's `status` block (`ble.whoop4_led`). Nothing interprets the bytes.
//
// WRITTEN, NOT COMPILED here (the app target is built with xtool).

extension AppModel {
    /// The Raw 4.0 screen's button: read now.
    func readWhoop4LedNow() async {
        await readWhoop4Led(auto: false)
    }

    /// Once a minute while the 4.0 link exists (`Whoop4Coordinator.ledTick`): reads when the overnight schedule says so.
    func whoop4LedTick() async {
        guard StrapDeviceChoice.stored == .whoop4, !isSample else { return }
        let hour = calendar.component(.hour, from: clock.now)
        let asleep = await liveSleepState(now: clock.now).asleepSince != nil
        let due = Whoop4LedSchedule.due(now: clock.now, lastAt: whoop4Raw.ledLastAt, connected: services.whoop4.isConnected,
                                        hour: hour, asleep: asleep)
        if due { await readWhoop4Led(auto: true) }
    }

    func readWhoop4Led(auto: Bool) async {
        let m = whoop4Raw
        guard StrapDeviceChoice.stored == .whoop4 else { return }
        guard let link = services.whoop4.link, services.whoop4.isConnected else {
            if !auto { showNotice("Connect the WHOOP 4.0 first, then read its LED settings.") }
            return
        }
        guard !m.ledReading else { return }
        m.ledReading = true
        defer { m.ledReading = false }
        let reads = await link.readLedSettings()
        m.ledLastAt = clock.now                       // also after a failed read: the next automatic try is 30 min on, not every minute
        let sid = link.currentStrapID?.raw ?? "phone"
        var storeError: String?
        for r in reads {
            do { try await services.store.logLedRead(line: r.line, strapId: sid, at: r.at) } catch { storeError = "\(error)" }
        }
        m.ledStoreError = storeError
        m.ledReads = Array((reads.reversed() + m.ledReads).prefix(90))
        let words = reads.map { "\($0.command) \($0.result)" }.joined(separator: ", ")
        services.whoop4.noteExternal("LED settings read (\(auto ? "overnight" : "button"), \(reads.first?.worn.map { $0 ? "worn" : "not worn" } ?? "wear ?")): \(words)")
        if !auto { showNotice("LED settings read: \(words).") }
    }

    /// Reads the saved lines back (after a relaunch the Raw 4.0 screen still shows the last reads).
    func loadSavedWhoop4LedReads() async {
        let lines = (try? await services.store.recentLedReadLines(limit: 90)) ?? []
        let saved = lines.compactMap { Whoop4LedRead.parse(line: $0) }
        guard !saved.isEmpty else { return }
        let have = Set(whoop4Raw.ledReads.map(\.id))
        whoop4Raw.ledReads = (whoop4Raw.ledReads + saved.filter { !have.contains($0.id) }).sorted { $0.at > $1.at }
    }
}
