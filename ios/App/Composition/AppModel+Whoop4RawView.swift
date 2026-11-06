import Combine
import Foundation
import MGBLE
import MGContext
import MGDomain
import MGStore

// 0.6.0.12 — the "Raw WHOOP 4.0 data" screen (Strap & sync › Device with the 4.0 selected, and the Live tab). It reads the newest
// type-47 history frames from the raw archive and shows the once-a-second fields of the v24 record (red/IR, optical, skin
// temperature raw, ambient, LED drive, respiration raw, quality, gravity) as raw counts with a small chart of the last hours.
// Every number is "raw counts, decoded, untested" (CLAUDE.md rule 4): offsets from `docs/research/WHOOP4-INVENTORY-2026-11-05.md`.
//
// WRITTEN, NOT COMPILED here (the app target is built with xtool).

/// The screen's model: `AppModel.reloadWhoop4Raw()` fills it, `Whoop4RawScreen` observes it.
@MainActor
final class Whoop4RawModel: ObservableObject {
    @Published var series = Whoop4RawSeries.build(frames: [])
    @Published var status = "Not read yet."
    @Published var loading = false
    @Published var loadedAt: Date?
    /// LED settings reads (GET 40 / 42 / 44), newest first, raw reply hex (AppModel+Whoop4Led).
    @Published var ledReads: [Whoop4LedRead] = []
    @Published var ledReading = false
    @Published var ledLastAt: Date?
    /// Set when a read could not be saved to the store; the screen says so.
    @Published var ledStoreError: String?
}

extension AppModel {
    /// Frames to read: about 3 hours at one record a second, with room for the other frame kinds sharing the packet type.
    static let whoop4RawFrameLimit = 12_000
    static let whoop4RawHours = 3.0

    func openWhoop4Raw() async {
        if paths[tab]?.last != .whoop4Raw { push(.whoop4Raw) }
        await reloadWhoop4Raw()
    }

    func reloadWhoop4Raw() async {
        let m = whoop4Raw
        guard !m.loading else { return }
        m.loading = true
        defer { m.loading = false }
        await loadSavedWhoop4LedReads()
        do {
            let frames = try await services.store.recentHistoryFrames(limit: Self.whoop4RawFrameLimit)
            let s = Whoop4RawSeries.build(frames: frames, hours: Self.whoop4RawHours)
            m.series = s
            m.loadedAt = clock.now
            if let latest = s.latest, let oldest = s.oldest {
                m.status = "\(s.records.count) records, \(MGFormat.time(oldest.date, calendar: calendar)) to "
                    + "\(MGFormat.time(latest.date, calendar: calendar)) on the strap's clock. "
                    + (s.skipped > 0 ? "\(s.skipped) other frames of the same kind were not 4.0 v24 records." : "")
            } else if frames.isEmpty {
                m.status = "No history records on the phone yet. The 4.0 downloads its history after it connects."
            } else {
                m.status = "\(frames.count) history frames are stored, but none is a WHOOP 4.0 v24 record."
            }
        } catch {
            m.status = "Could not read the stored records: \(error)"
        }
    }
}
