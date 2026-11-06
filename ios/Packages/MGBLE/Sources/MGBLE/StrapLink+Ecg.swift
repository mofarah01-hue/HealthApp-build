import Foundation
import MGDomain
import WhoopProtocol

/// What `ecg` publishes (wave W8, 2026-10-11 19:50 PT).
public struct EcgStatus: Equatable, Sendable {
    public enum Phase: String, Sendable { case idle, starting, running, stopping }
    /// The app switch "ECG (MG)", off by default.
    public var switchOn: Bool = false
    public var phase: Phase = .idle
    public var wrist: EcgWrist?
    public var startedAt: Date?
    /// R17 packets received (this reading, or stray ones while none runs).
    public var packets: Int = 0
    public var lastPacketAt: Date?
    /// An ON write went out and the full stop (124 [01 01], 125 [01 00], 139 [01 00]) has not.
    public var stopOwed: Bool = false
    /// The last outcome in words: wrist refused, start refused, acknowledged without data, stopped, …
    public var outcome: String?

    public init() {}
}

/// One live R17 filtered-ECG packet (packet 43, layout 17), decoded by WhoopProtocol `Whoop5Ecg.r17FromFrame` (CRC-gated;
/// noop Whoop5Ecg.swift L527 `parseR17`). Samples are signed raw counts; no voltage scale or rate is established
/// (noop docs/PROTOCOL_ECG.md L186-195, L293-296).
public struct EcgLivePacket: Equatable, Sendable {
    public var packet: EcgTracePacket
    public var samples: [Int16]
    /// The strap's terminal frame: progress 100 or classifier state 2 (noop LabradorR17 `isTerminal`).
    public var terminal: Bool
}

/// The ON writes of a reading, in words (e.g. "123 [0102] → SUCCESS").
public struct EcgStartReport: Equatable, Sendable {
    public var steps: [String]
}

/// A reading in progress (main actor only).
@MainActor
final class EcgReadingRun {
    let startedAt: Date
    let wrist: EcgWrist
    var deadline: Task<Void, Never>?

    init(startedAt: Date, wrist: EcgWrist) {
        self.startedAt = startedAt
        self.wrist = wrist
    }
}

/// The MG ECG reading. CLAUDE.md rule 5 (as changed 2026-10-11 12:35 PT) allows exactly: start = SELECT_WRIST (123),
/// TOGGLE_LABRADOR_FILTERED (139) [01 01], TOGGLE_LABRADOR_RAW_SAVE (125) [01 01], TOGGLE_LABRADOR_DATA_GENERATION (124)
/// [01 02]; stop = 124 [01 01], 125 [01 00], 139 [01 00] — each with response, behind an off-by-default switch.
/// Order and session rules: noop docs/PROTOCOL_ECG.md L69-75 (select and acknowledge the wrist before start, choose the
/// outputs, then request generation; report wrist refusal, start refusal, acknowledged-without-data and received records
/// separately; cleanup stops generation and disables the gates), L85-93 (serialise sessions; never restart a reading by
/// resending start on reconnect); noop Strand/BLE/BLEManager.swift L4459-4472 (start: 139 on, 125 on, then 124 = 2) and
/// L4514-4535 (stop: 124 = 1, 125 off, 139 off; turning off is never gated by the opt-in). noop also sends ABORT 20 just
/// before 124 (L4474-4508); this app instead refuses to start while a history download runs (the reason noop gives for 20)
/// and downloads no history while a reading runs.
/// The ON writes refuse while the switch is off; the stop is always available. A stop is owed from the wrist write on, so a
/// link loss mid-reading is answered with the stop at the next handshake; a stray R17 stream (an app crash mid-reading) is
/// answered with the stop at most once per 30 s.
extension StrapLink {
    /// The hard cap on one reading (the strap's own reading completed at 38-39 s in noop #891).
    public static let ecgMaxSeconds: Double = 120

    /// Every live R17 packet, decoded.
    public var ecgPackets: AsyncStream<EcgLivePacket> { ecgHub.stream() }

    /// The app switch. Turning it off stops a reading in progress (and an owed stop).
    public func setEcgSwitch(_ on: Bool) async {
        ecgSwitchOn = on
        publishEcg()
        if !on, ecgReading != nil || ecgNeedsStop {
            _ = await stopEcgReading(reason: "the ECG switch went off")
        }
    }

    /// Starts a reading: 123 [01 wrist] → 139 [01 01] → 125 [01 01] → 124 [01 02], each with response. Throws (and sends
    /// nothing more) when the switch is off, the strap is not ready, a history download runs or a reading is open. A
    /// refused wrist stops there (no gate was opened); a refused 139 or 124 runs the full stop. A refused 125 is reported
    /// and the reading continues (it only gates the banked raw copy). Ends by itself after `maxSeconds` (≤ 120 s).
    @discardableResult
    public func startEcgReading(wrist: EcgWrist, maxSeconds: Double = 60) async throws -> EcgStartReport {
        guard ecgSwitchOn else {
            throw StrapLinkError.refusedByPolicy(reason: "the ECG switch is off (Strap & sync › ECG)")
        }
        guard handshakeDone else { throw StrapLinkError.notReady("strap not connected") }
        guard historyRun == nil, historyProbe == nil else { throw StrapLinkError.historyInProgress }   // W12b: + test
        guard ecgReading == nil, !ecgStopping else { throw StrapLinkError.refused("an ECG reading is already running") }
        if ecgNeedsStop {
            // PROTOCOL_ECG.md L85-86: resolve the previous session before starting another.
            _ = await stopEcgReading(reason: "stopped before a new reading")
            guard !ecgNeedsStop else {
                throw StrapLinkError.refused("the last ECG reading could not be stopped — try again")
            }
        }
        let run = EcgReadingRun(startedAt: clock.now, wrist: wrist)
        ecgReading = run
        ecg.phase = .starting
        ecg.wrist = wrist
        ecg.startedAt = run.startedAt
        ecg.packets = 0
        ecg.lastPacketAt = nil
        ecg.outcome = nil
        publishEcg()
        var steps: [String] = []

        let w = await ecgStep(.ecgSelectWrist(wrist))
        steps.append(w.words)
        guard w.ok else {
            ecgReading = nil
            ecg.phase = .idle
            ecg.outcome = "wrist selection refused: \(w.words)"
            publishEcg()
            throw StrapLinkError.refused("The strap did not accept the wrist selection (\(w.words)). Nothing else was sent.")
        }
        ecgNeedsStop = true           // owed from here on, whatever happens next (noop L4461 latches before the sends)
        let filtered = await ecgStep(.ecgFilteredLive(on: true))
        steps.append(filtered.words)
        if filtered.ok {
            let save = await ecgStep(.ecgSaveRaw(on: true))
            steps.append(save.words + (save.ok ? "" : " (raw copy not saved; the live trace continues)"))
            let start = await ecgStep(.ecgGeneration(.start))
            steps.append(start.words)
            if start.ok {
                ecg.phase = .running
                ecg.outcome = "start acknowledged — waiting for ECG records"
                publishEcg()
                let limit = min(max(maxSeconds, 5), Self.ecgMaxSeconds)
                run.deadline = Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(limit * 1_000_000_000))
                    guard let self, !Task.isCancelled, self.ecgReading === run else { return }
                    _ = await self.stopEcgReading(reason: "time limit (\(Int(limit)) s)")
                }
                logLine("ECG: started — " + steps.joined(separator: "; "))
                return EcgStartReport(steps: steps)
            }
        }
        logLine("ECG: start refused — " + steps.joined(separator: "; "))
        _ = await stopEcgReading(reason: "start refused")
        ecg.outcome = "start refused: " + steps.joined(separator: "; ")
        publishEcg()
        throw StrapLinkError.refused("The strap refused the ECG start (\(steps.joined(separator: "; "))). It was stopped again.")
    }

    /// The full stop: 124 [01 01], 125 [01 00], 139 [01 00], each with response. Returns true when all three writes went
    /// out (whatever the strap answered); otherwise the stop stays owed and is sent at the next handshake.
    @discardableResult
    public func stopEcgReading(reason: String = "stopped") async -> Bool {
        guard !ecgStopping else { return false }
        ecgReading?.deadline?.cancel()
        guard handshakeDone else {
            ecgReading = nil
            ecg.phase = .idle
            ecg.outcome = "not connected — the stop is sent at the next connection"
            publishEcg()
            return false
        }
        ecgStopping = true
        defer { ecgStopping = false }
        ecg.phase = .stopping
        publishEcg()
        var sent = true
        var steps: [String] = []
        for command in [SanctionedCommand.ecgGeneration(.stop), .ecgSaveRaw(on: false), .ecgFilteredLive(on: false)] {
            let s = await ecgStep(command)
            steps.append(s.words)
            if !s.written { sent = false }
        }
        ecgReading = nil
        if sent { ecgNeedsStop = false }
        ecgUnexpectedStopAt = clock.now
        ecg.phase = .idle
        ecg.outcome = "\(reason) — " + steps.joined(separator: "; ")
        publishEcg()
        logLine("ECG: \(reason) — " + steps.joined(separator: "; "))
        return sent
    }

    /// Handshake: a stop the last link owed goes out now. Never a restart.
    func stopEcgIfOwed() async {
        guard ecgNeedsStop else { return }
        _ = await stopEcgReading(reason: "stopped after reconnecting (the link dropped during a reading)")
    }

    /// The link dropped: the reading is over on this side; the stop stays owed.
    func ecgLinkLost() {
        guard ecgReading != nil || ecgNeedsStop else { return }
        ecgReading?.deadline?.cancel()
        ecgReading = nil
        ecg.phase = .idle
        ecg.outcome = "link lost during the reading — the stop is sent at the next connection"
        publishEcg()
    }

    /// A live packet-43 frame: R17 (layout 17, 240 bytes) → `ecgPackets`. The raw frame itself is already kept (route()).
    func noteLiveEcg(_ frame: [UInt8]) {
        guard frame.count == Whoop5Ecg.rawRecordLength, frame[9] == Whoop5Ecg.r17Revision,
              let r = Whoop5Ecg.r17FromFrame(frame) else { return }
        let packet = EcgTracePacket(
            receivedAt: clock.now.timeIntervalSince1970, sequence: r.sequence, strapWord: r.strapSeconds,
            strapSubword: r.subseconds, sampleCount: Int(r.sampleCount), quality: Int(r.signalQualityRaw),
            flags: Int(r.flags.raw), resultCode: Int(r.arrhythmiaCheckResultRaw), classifierState: Int(r.classifierState),
            progress: Int(r.progress.raw), unreadable: Int(r.unreadable.raw), averageHR: Int(r.averageHR),
            liveHR: Int(r.liveHR))
        ecg.packets += 1
        ecg.lastPacketAt = clock.now
        if ecgReading != nil, ecg.phase == .running, ecg.packets == 1 { ecg.outcome = "receiving ECG records" }
        if ecgReading == nil, !ecgNeedsStop, !ecgStopping, handshakeDone {
            let last = ecgUnexpectedStopAt ?? .distantPast
            if clock.now.timeIntervalSince(last) >= 30 {
                ecgUnexpectedStopAt = clock.now
                ecgNeedsStop = true
                logLine("ECG: R17 arrived while no reading runs — stop sent")
                Task { @MainActor [weak self] in _ = await self?.stopEcgReading(reason: "stray ECG stream stopped") }
            }
        }
        publishEcg()
        ecgHub.yield(EcgLivePacket(packet: packet, samples: r.samples, terminal: r.isTerminal))
    }

    /// One ECG write with response. `ok` = the strap answered SUCCESS; `written` = the write itself went out.
    private func ecgStep(_ command: SanctionedCommand) async -> (ok: Bool, written: Bool, words: String) {
        let what = "\(command.opcode) [\(command.payload.hexLower)]"
        do {
            let r = try await channel.send(.sanctioned(command), awaitResponse: true)
            return (r?.result == .success, true, "\(what) → \(r?.result.label ?? "no response")")
        } catch {
            return (false, false, "\(what) failed — \(describeError(error))")
        }
    }

    func publishEcg() {
        var s = ecg
        s.switchOn = ecgSwitchOn
        s.stopOwed = ecgNeedsStop
        if ecg != s { ecg = s }
    }
}
