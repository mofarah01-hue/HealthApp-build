import Combine
import Foundation
import MGContext
import MGDomain
import MGStore

// Live › research (W10, tracker #91, 2026-10-11): the record inspector, capture sessions and raw retention, which
// said "isn't built in this version yet". Reads are MGStore ResearchReads; a capture is a `marker` event
// "capture: <label>" (start → stop) using the raw switches already on — this screen never switches one on (CLAUDE.md
// rule 5) — and at stop its raw frames are pinned. Pure wording: MGContext ResearchPresenter.

@MainActor
final class ResearchModel: ObservableObject {
    @Published var state: InfoScreenState?
    var kind = "inspector"
}

extension AppModel {
    static let capturePrefix = "capture: "

    func openResearch(_ kind: String) async {
        research.kind = ResearchPresenter.kinds.contains(kind) ? kind : "inspector"
        research.state = nil
        push(.research(research.kind))
        await researchLoad()
    }

    func researchAction(_ action: ResearchAction) async {
        switch action {
        case .refresh:
            break
        case .startCapture(let label):
            guard !isSample else { return showNotice("Sample data is on — nothing is recorded.") }
            guard settings.rawOpticalOn || settings.rawMotionOn else {
                return showNotice("Turn on raw optical or raw motion in Strap & sync first.")
            }
            if let running = await activeCapture(), running.end == nil {
                return showNotice("A capture is already running: \(running.label).")
            }
            let e = EventRecord(at: clock.now, source: .manual,
                                payload: .marker(MarkerFields(label: Self.capturePrefix + label, end: nil)))
            if await write(e, undoable: false) != nil {
                if settings.rawMotionOn, let why = await services.strap.rawMotionSession(seconds: 30 * 60) {
                    showNotice("Capture started; raw motion session not started: \(why)")
                } else {
                    showNotice("Capture started: \(label).")
                }
            }
        case .stopCapture:
            guard let (event, start) = await activeCaptureEvent() else { return showNotice("No capture is running.") }
            var e = event
            let end = clock.now
            if case .marker(var f) = e.payload {
                f.end = end
                e.payload = .marker(f)
            }
            _ = await write(e, undoable: false)
            if settings.rawMotionOn { _ = await services.strap.rawMotionSession(seconds: 0) }
            let pinned = (try? await services.store.pinRawFrames(from: start, to: end)) ?? 0
            showNotice("Capture stopped and kept (\(pinned) raw frames pinned).")
        case .saveRecent:
            // Decode lab (T122): phone-side only (a marker plus pinned frames), nothing is sent to the strap.
            guard !isSample else { return showNotice("Sample data is on — nothing is recorded.") }
            let end = clock.now
            let start = end.addingTimeInterval(-Double(ResearchPresenter.decodeWindowMinutes) * 60)
            let e = EventRecord(at: start, source: .manual,
                                payload: .marker(MarkerFields(label: Self.capturePrefix + "decode lab", end: end)))
            _ = await write(e, undoable: false)
            let pinned = (try? await services.store.pinRawFrames(from: start, to: end)) ?? 0
            showNotice("Kept \(pinned) raw frames; they reach the PC with the next sync.")
        }
        await researchLoad()
    }

    /// The newest capture marker of the last 2 days (running when `end` is nil).
    func activeCapture() async -> ResearchInput.Capture? {
        guard let events = try? await services.store.events(from: clock.now.addingTimeInterval(-2 * 86_400),
                                                             to: clock.now, types: [.marker]) else { return nil }
        for e in events.sorted(by: { $0.at > $1.at }) where !e.removed {
            if case .marker(let f) = e.payload, f.label.hasPrefix(Self.capturePrefix) {
                return ResearchInput.Capture(label: String(f.label.dropFirst(Self.capturePrefix.count)), start: e.at,
                                             end: f.end)
            }
        }
        return nil
    }

    func activeCaptureEvent() async -> (EventRecord, Date)? {
        guard let events = try? await services.store.events(from: clock.now.addingTimeInterval(-2 * 86_400),
                                                             to: clock.now, types: [.marker]) else { return nil }
        for e in events.sorted(by: { $0.at > $1.at }) where !e.removed {
            if case .marker(let f) = e.payload, f.label.hasPrefix(Self.capturePrefix), f.end == nil { return (e, e.at) }
        }
        return nil
    }

    func researchLoad() async {
        var i = ResearchInput(kind: research.kind, now: clock.now, sample: isSample)
        let store = services.store
        if !isSample {
            do {
                switch research.kind {
                case "capture":
                    i.capture = await activeCapture()
                    i.rawOpticalOn = settings.rawOpticalOn
                    i.rawMotionOn = settings.rawMotionOn
                    if let c = i.capture {
                        i.frameCounts = try await store.rawFrameCounts(from: c.start, to: c.end ?? clock.now)
                    }
                case "decode":
                    i.rawOpticalOn = settings.rawOpticalOn
                    i.rawMotionOn = settings.rawMotionOn
                    i.ecgOn = settings.ecgOn
                    i.historyReadTest = historyReadTestLines
                    i.historyReadTestRunning = historyReadTestRunning
                    i.streams = try await store.rawStreamStats(from: clock.now.addingTimeInterval(
                        -Double(ResearchPresenter.decodeWindowMinutes) * 60), to: clock.now).map {
                        ResearchInput.Stream(packetType: $0.packetType, frames: $0.frames, last: $0.last)
                    }
                    // T90: the strap's on-chip values over the last 24 h next to ours. Ours exist for HR only (the PPG night
                    // median, ALG-108); we store no beat-to-beat series, battery, skin-temp or SpO2 of our own, so those say none.
                    let strap = try await store.strapOnChip(from: clock.now.addingTimeInterval(-86_400), to: clock.now)
                    typealias V = ResearchInput.StrapVsOurs.Value
                    let today = LocalDay(date: clock.now, calendar: calendar)
                    let ours = try await store.metrics(named: MetricKey.ppgHr.rawValue, from: today.adding(days: -1), to: today)
                        .last?.metric.value
                    i.strapVsOurs = ResearchInput.StrapVsOurs(
                        hr: .init(strap: strap.hr.map { V(mean: $0.mean, n: $0.n) }, ours: ours.map { V(mean: $0, n: 1) }),
                        rr: .init(strap: strap.rr.map { V(mean: $0.mean, n: $0.n) }), battery: strap.batteryPercent,
                        skinTempRaw: strap.skinTempRaw.map { V(mean: $0.mean, n: $0.n) },
                        spo2Byte: strap.spo2Byte.map { V(mean: $0.mean, n: $0.n) })
                case "retention":
                    let r = try await store.rawRetentionStatus()
                    i.rawFrames = r.rawFrames
                    i.rawBytes = r.rawBytes
                    i.rawUnconfirmed = r.rawUnconfirmed
                    i.oldestRaw = r.oldestRaw
                    i.oldestConfirmedRaw = r.oldestConfirmedRaw
                    i.oldestUnconfirmedRaw = r.oldestUnconfirmedRaw
                    i.perSecond = r.perSecond.map {
                        ResearchInput.PerSecond(name: $0.table, rows: $0.rows,
                                                oldest: $0.oldest.map { Date(timeIntervalSince1970: TimeInterval($0)) })
                    }
                    if let last = try await store.lastPhoneRetention() {
                        i.lastCleanupAt = last.at
                        i.lastCleanupFrames = last.rawFrames
                    }
                default:
                    i.records = try await store.recentRecords(limit: 40).map {
                        ResearchInput.Record(kind: $0.kind, at: $0.at, fields: $0.fields)
                    }
                }
            } catch {
                i.problem = "The phone's store couldn't be read: \(error)"
            }
        } else {
            i.problem = "Sample data is on — it has no strap records."
        }
        research.state = ResearchPresenter.make(i, calendar: calendar)
    }
}
