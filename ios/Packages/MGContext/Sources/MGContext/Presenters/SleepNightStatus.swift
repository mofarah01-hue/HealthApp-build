import Foundation
import MGDomain

// Sleep card states (Mo, Nov 6 2026: "if our sleep fails, fallbacks to other sources are important"; approved mock-up section 1).
// The states and the words only: the card keeps its existing look. Everything here is decided from what the snapshot already
// knows; nothing is invented, and a blank always says exactly what is missing.

public enum SleepCardPhase: String, Equatable, Sendable {
    /// The night is coming off the strap right now (a download that is really moving).
    case downloading
    /// Our own night is not here and no fallback has one either: says what is missing and what we do have.
    case notProcessed
    /// Apple Health's night is shown because ours is incomplete.
    case fallback
    /// Our own night, or no need to say more.
    case done
}

/// "41% · 1:05 AM of 7:40 AM so far · about 3 min left"; `fraction` nil while the strap's end is not known.
public struct SleepCardProgress: Equatable, Sendable {
    public var fraction: Double?
    public var text: String
    public init(fraction: Double?, text: String) {
        self.fraction = fraction
        self.text = text
    }
}

struct SleepNightStatus: Equatable {
    var phase: SleepCardPhase
    /// The sentence under the heading while downloading or not processed.
    var headline: String?
    var progress: SleepCardProgress?
    /// "Live heart rate: 8:34 PM – 2:51 AM · Apple Health: not here yet (459 batches waiting)".
    var have: String?
    /// "Our strap night is incomplete (...) · it replaces this when it arrives".
    var fallbackNote: String?
}

extension PresenterSnapshot {
    /// First to last stored heart-rate bucket in the 18 hours before now (the night and the evening before it); nil = none.
    func liveHRSpan() -> DateInterval? {
        let from = now.addingTimeInterval(-18 * 3600)
        var first: Date?
        var last: Date?
        for x in (dialSeries + series) where x.name == DialSeries.hrName && x.stepS > 0 {
            for (i, v) in x.values.enumerated() {
                guard let v, v.isFinite else { continue }
                let t = x.start.addingTimeInterval(Double(i) * x.stepS)
                guard t >= from, t <= now else { continue }
                if first.map({ t < $0 }) ?? true { first = t }
                if last.map({ t > $0 }) ?? true { last = t }
            }
        }
        guard let a = first, let b = last else { return nil }
        return DateInterval(start: a, end: b)
    }

    /// "Apple Health: not here yet (459 batches waiting)".
    func appleHealthStatusWords() -> String {
        var t = "Apple Health: not here yet"
        if let n = strapSync.healthQueuedBatches, n > 0 { t += " (\(n) batch\(n == 1 ? "" : "es") waiting)" }
        return t
    }

    private func strapClock(_ ts: Int64) -> String { hm(Date(timeIntervalSince1970: TimeInterval(ts))) }

    /// The download's progress line, from the strap's own clock.
    func downloadProgress(_ h: HistoryProgress) -> SleepCardProgress {
        var parts: [String] = []
        if let f = h.fraction { parts.append("\(Int((f * 100).rounded(.down)))%") }
        if let n = h.newestTs {
            if let t = h.targetTs { parts.append("\(strapClock(n)) of \(strapClock(t)) so far") }
            else { parts.append("\(strapClock(n)) so far") }
        } else {
            parts.append("waiting for the first chunk")
        }
        let elapsed = now.timeIntervalSince(h.startedAt)
        if let covered = h.coveredSeconds, let total = h.totalSeconds, covered > 0, elapsed >= 30, total > covered {
            let perSecond = Double(covered) / elapsed
            let minutes = Int((Double(total - covered) / perSecond / 60).rounded(.up))
            parts.append(minutes <= 1 ? "under a minute left" : "about \(minutes) min left")
        }
        return SleepCardProgress(fraction: h.fraction, text: parts.joined(separator: " · "))
    }

    /// Decides which card state this is and writes its words. `f` is the resolver's decision (`sleepFill()`), passed on so the
    /// night is decided once.
    func sleepNightStatus(_ f: SleepFillResult) -> SleepNightStatus {
        let strapName = whoop4Selected ? "WHOOP 4.0" : "strap"
        let span = liveHRSpan()
        if f.fill == .notProcessed {
            if sleepDownloadPending(), let h = inputs.history {
                return SleepNightStatus(phase: .downloading, headline: "Last night is coming off your \(strapName).",
                                        progress: downloadProgress(h), have: nil, fallbackNote: nil)
            }
            let stalled = historyStalled()
            let stopped = stalled.map { h -> String in
                h.newestTs.map { "The download stopped at \(strapClock($0))." } ?? "The download stopped before any data arrived."
            }
            var headline: String
            if span != nil {
                // A part night: heart rate only, no sleep record. Said as such, not as a bare "not processed".
                headline = "Part of your night is here: live heart rate only, no sleep record from the \(strapName) yet."
                if let stopped { headline += " \(stopped) The rest is still on the strap." }
            } else if let stopped {
                headline = "Your night is still on the \(strapName). \(stopped)"
            } else {
                headline = f.reason ?? Self.notProcessedNoFlag
            }
            let hr = span.map { "Live heart rate: \(hm($0.start)) – \(hm($0.end))" } ?? "Live heart rate: none stored"
            return SleepNightStatus(phase: .notProcessed, headline: headline, progress: nil,
                                    have: [hr, appleHealthStatusWords()].joined(separator: " · "), fallbackNote: nil)
        }
        if f.fill == .imported {
            let why: String
            if let h = historyStalled() {
                why = h.newestTs.map { "the download stopped at \(strapClock($0))" } ?? "history still on the strap"
            } else if span != nil, strapAsleepSpan() == nil {
                why = "only live heart rate so far"
            } else {
                why = "history still on the strap"
            }
            return SleepNightStatus(phase: .fallback, headline: nil, progress: nil, have: nil,
                                    fallbackNote: "Our strap night is incomplete (\(why)) · it replaces this when it arrives")
        }
        return SleepNightStatus(phase: .done, headline: nil, progress: nil, have: nil, fallbackNote: nil)
    }
}
