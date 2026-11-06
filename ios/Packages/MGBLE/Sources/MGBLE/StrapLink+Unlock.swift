import Foundation
import MGDomain
import WhoopProtocol

/// The R22 research stream (APP-002, D7, ARCHITECTURE §4.4.5 as changed 2026-10-11): ONE persistent write,
/// enable_r22_packets = '1', approved by Mo in chat. Order of a run:
///   1. `prepareUnlock` takes a full strap settings snapshot (117/118/128) and STORES it — the prior value is on disk
///      before anything is written; it stops only when the master cannot be read or already reads '1'. CHANGED
///      2026-10-11 (Mo: "Single write, then see"): it used to stop when no R22 version flag read '1'; now the one write
///      goes ahead and the app watches the next offloads for R22 records (`R22Watch`). No code path writes a version
///      flag;
///   2. the confirm sheet shows old → new; nothing is written unless it returns `.confirmed`;
///   3. `runUnlock` re-reads the value (it must still be what the sheet showed), writes SET_FF_VALUE (120) WITH
///      RESPONSE (65-byte body), reads it back with 128, and logs prior / payload / read-back;
///   4. `restoreUnlock` writes the saved prior back the same way (confirm sheet, read-back, log `restored: true`).
/// Nothing refuses these calls on policy (CLAUDE.md rule 5, 2026-10-13); the confirm sheet is the information step.
/// The frames are DECODED (byte-checked against a stdlib framer that reproduces noop's golden), not hardware-verified.
extension StrapLink {
    struct FlagWrite {
        let value: R22PacketsValue
        /// The value read just before writing (nil = could not be read).
        let prior: String?
        let isRestore: Bool
    }

    static let r22Risks = [
        "enable_r22_packets stays on the strap until it is written again. The value read now is stored first; "
            + "Restore writes it back.",
        "On this firmware '1' permits R22; '0' and '2' do not (noop PROTOCOL_CONFIGURATION). The old 16-flag list wrote "
            + "'2', which would have turned R22 off.",
        "R22 records (about one 188-byte record a second) are banked into history and downloaded with it: more strap "
            + "battery and radio time. They are kept raw until a decoder is verified.",
        "Only this one flag is written. No R22 version flag is written — that needs a new yes from Mo.",
    ]

    /// Reads and stores a full settings snapshot, then builds the one-write plan. Throws (nothing written) when the
    /// master cannot be read or already reads '1'.
    public func prepareUnlock() async throws -> StrapWritePlan {
        guard handshakeDone else { throw StrapLinkError.notReady("strap not connected") }
        let snapshot = try await readFlagSnapshot()
        guard let master = snapshot.readings.first(where: { $0.key == R22Flag.key }), master.status == "ok",
              let current = master.value else {
            let why = snapshot.readings.first { $0.key == R22Flag.key }?.status ?? "not listed"
            throw StrapLinkError.refused("\(R22Flag.key) could not be read (\(why)) — nothing written")
        }
        if current == R22PacketsValue.enable.text {
            throw StrapLinkError.refused("\(R22Flag.key) already reads '1' — nothing to write")
        }
        var risks = Self.r22Risks
        if let hint = Self.r22VersionHint(snapshot) {
            risks.append("No R22 version flag reads '1' on this strap. The write goes ahead (Mo: \"single write, then "
                + "see\"); if the next offloads bring no R22 records, the strap may also need \(hint) = 1 (not written "
                + "by this app yet).")
        }
        let command = SanctionedCommand.setR22Packets(.enable)
        return StrapWritePlan(
            id: UUID(), title: "R22 research stream: enable_r22_packets → '1'",
            reason: "Lets the strap bank its R22 records (per-second deep sensor data) into history, so they reach the "
                + "phone and the PC. One setting; every strap setting was read and stored first.",
            items: [PlannedWrite(name: R22Flag.key, command: Int(command.opcode), payloadHex: command.payload.hexLower,
                                 currentValue: current)],
            restorable: R22SavedValue(text: current) != nil, risks: risks)
    }

    /// When no R22 version flag reads '1': the most-preferred one the strap answered for (noop PROTOCOL_CONFIGURATION
    /// "R22 version preferences": 9, 6, 5, 4, 3, 2, then 1 as fallback), else the first of the list. nil when one
    /// already reads '1'. Words only — nothing writes it.
    public static func r22VersionHint(_ snapshot: StrapFlagSnapshot) -> String? {
        guard !r22VersionFlags.contains(where: { snapshot.value(of: $0) == "1" }) else { return nil }
        let answered = r22VersionFlags.first { k in snapshot.readings.contains { $0.key == k && $0.status == "ok" } }
        return answered ?? r22VersionFlags[0]
    }

    public func runUnlock(_ plan: StrapWritePlan) async throws -> UnlockReport {
        guard handshakeDone else { throw StrapLinkError.notReady("strap not connected") }
        let write = try Self.validateR22Plan(plan)
        return await runFlagWrites(plan: plan, writes: [write])
    }

    /// Writes the saved prior value back (a confirmed plan too). The prior comes from this app session's write, else
    /// from the persisted write log through `priorValueLookup` (MGStore `latestPriorValue`, which skips entries
    /// logged `restored: true`). No saved prior, or one that is not '0' / '1' / '2' → "can't restore", nothing written.
    public func restoreUnlock() async throws -> UnlockReport {
        guard handshakeDone else { throw StrapLinkError.notReady("strap not connected") }
        let started = clock.now
        var logged = r22Prior
        if logged == nil, let lookup = priorValueLookup {
            logged = await lookup(120, R22Flag.key)   // 120 = SET_FF_VALUE
        }
        func stop(_ result: String, prior: String? = nil, note: String) -> UnlockReport {
            UnlockReport(planId: UUID(), startedAt: started, endedAt: clock.now,
                         items: [UnlockItemResult(name: R22Flag.key, command: 120, payloadHex: "", priorValue: prior,
                                                  readback: nil, result: result)],
                         stoppedEarly: true, note: note)
        }
        guard let prior = logged else {
            return stop("can't restore: no saved prior value", note: "nothing to restore")
        }
        guard let saved = R22SavedValue(text: prior) else {
            return stop("can't restore: saved prior '\(prior)' is not '0', '1' or '2'", prior: prior,
                        note: "nothing written")
        }
        let current = await readR22()
        if current.status == "ok", current.value == saved.text {
            return stop("already '\(saved.text)' — nothing written", prior: current.value, note: "nothing to restore")
        }
        let command = SanctionedCommand.setR22Packets(.restore(saved))
        let plan = StrapWritePlan(
            id: UUID(), title: "Restore enable_r22_packets → '\(saved.text)'",
            reason: "Writes back the value read and stored before the R22 write.",
            items: [PlannedWrite(name: R22Flag.key, command: Int(command.opcode), payloadHex: command.payload.hexLower,
                                 currentValue: current.status == "ok" ? current.value : nil)],
            restorable: true, risks: [Self.r22Risks[0]])
        let prior2 = current.status == "ok" ? current.value : nil
        return await runFlagWrites(plan: plan, writes: [FlagWrite(value: .restore(saved), prior: prior2,
                                                                  isRestore: true)])
    }

    /// Confirm, then write. Nothing is written unless the confirmer returns `.confirmed`.
    func runFlagWrites(plan: StrapWritePlan, writes: [FlagWrite]) async -> UnlockReport {
        let started = clock.now
        guard case .confirmed(let confirmedAt) = await confirmer.confirm(plan) else {
            return UnlockReport(planId: plan.id, startedAt: started, endedAt: clock.now, items: [],
                                stoppedEarly: true, note: "declined — nothing written")
        }
        var results: [UnlockItemResult] = []
        var failed = false
        for write in writes {
            let result = await writeFlag(write, confirmedAt: confirmedAt)
            results.append(result)
            if result.result != "ok" {
                failed = true
                break
            }
        }
        return UnlockReport(planId: plan.id, startedAt: started, endedAt: clock.now, items: results,
                            stoppedEarly: failed, note: failed ? "stopped at the first failure" : nil)
    }

    private func writeFlag(_ write: FlagWrite, confirmedAt: Date) async -> UnlockItemResult {
        let command = SanctionedCommand.setR22Packets(write.value)
        // The value must still be what the sheet showed: a change since then means the plan is stale. Nothing is sent.
        let fresh = await readR22()
        let freshValue = fresh.status == "ok" ? fresh.value : nil
        guard freshValue != nil, freshValue == write.prior else {
            let now = freshValue.map { "'\($0)'" } ?? fresh.status
            return UnlockItemResult(name: R22Flag.key, command: Int(command.opcode),
                                    payloadHex: command.payload.hexLower, priorValue: freshValue, readback: nil,
                                    result: "not written: the strap now reads \(now), the sheet showed "
                                        + "'\(write.prior ?? "—")'")
        }
        var result: String
        var readback: String?
        do {
            let response = try await channel.send(.sanctioned(command), awaitResponse: true)
            // Remember the pre-write value the moment a write reaches the strap, for restoreUnlock.
            if !write.isRestore, r22Prior == nil { r22Prior = write.prior }
            if let r = response, r.result != .success {
                result = "strap answered \(r.result.label)"
            } else {
                let rb = await readR22()   // the write ack is not the proof; the read is
                readback = rb.status == "ok" ? rb.value : nil
                if rb.status == "ok", rb.value == write.value.text {
                    result = "ok"
                } else if rb.status == "ok" {
                    result = "readback '\(rb.value ?? "")' ≠ written '\(write.value.text)'"
                } else {
                    result = "no readback (\(rb.status))"
                }
                if response == nil, result != "ok" { result += "; no response to the write" }
            }
        } catch {
            result = "write failed: \(describeError(error))"
        }
        if write.isRestore, result == "ok" { r22Prior = nil }
        // A restore write's prior is the R22-on value; `restored: true` keeps it from ever being offered as the value
        // to restore (MGStore `latestPriorValue`). The enable write leaves it nil.
        await logWrite(command, prior: write.prior, readback: readback, confirmedAt: confirmedAt, result: result,
                       standingConsent: false, restored: write.isRestore ? true : nil)
        return UnlockItemResult(name: R22Flag.key, command: Int(command.opcode), payloadHex: command.payload.hexLower,
                                priorValue: write.prior, readback: readback, result: result)
    }

    /// GET_FF_VALUE (128) for enable_r22_packets, judged by `FeatureFlagValueReply` (SUCCESS + key echoed).
    func readR22() async -> StrapFlagReading {
        let response = try? await channel.send(.sanctioned(.getFeatureFlagValue(key: R22Flag.key)), awaitResponse: true)
        return FeatureFlagValueReply.reading(key: R22Flag.key, response: response)
    }

    /// The plan must be exactly the one enable write: enable_r22_packets, command 120, the '1' payload, and a
    /// current value that was read.
    static func validateR22Plan(_ plan: StrapWritePlan) throws -> FlagWrite {
        let expected = SanctionedCommand.setR22Packets(.enable)
        guard plan.items.count == 1, let item = plan.items.first else {
            throw StrapLinkError.planMismatch("expected 1 item, got \(plan.items.count)")
        }
        guard item.name == R22Flag.key, item.command == Int(expected.opcode),
              item.payloadHex == expected.payload.hexLower else {
            throw StrapLinkError.planMismatch("item '\(item.name)' is not enable_r22_packets = '1'")
        }
        guard let prior = item.currentValue else {
            throw StrapLinkError.planMismatch("the value before the write was not read — nothing to restore to")
        }
        return FlagWrite(value: .enable, prior: prior, isRestore: false)
    }
}

// MARK: - Strap settings snapshot (read-only; added 2026-10-11, strap-raw-optical phase A)

extension StrapLink {
    /// Keys read with 128 even when the 117/118 walk did not list them: the R22 master and the R22 version
    /// preferences, whose values decide whether the R22 plan may run (noop:docs/PROTOCOL_CONFIGURATION.md
    /// "R22 version preferences", fw 50.42.1.0: 9, 6, 5, 4, 3, 2, then 1 as fallback; v8 is not in that path).
    public static let r22VersionFlags = ["enable_r22_v9_packets", "enable_r22_v6_packets", "enable_r22_v5_packets",
                                         "enable_r22_v4_packets", "enable_r22_v3_packets", "enable_r22_v2_packets"]

    /// Reads every feature flag the strap lists, with its value, and stores the snapshot through
    /// `flagSnapshotSink` before returning (it throws `.notSaved` when that fails — nothing is ever written to the
    /// strap here: only 117, 118 and 128, all reads, which project CLAUDE.md rule 5 allows).
    ///
    /// Walk: 117 [01] once, then 118 [01] until the strap ends its own list (index 0xFF) or a client-side bound
    /// (announced count + 4, 128 replies) — WhoopProtocol `FeatureFlagProbeReport` decides, unchanged from noop (#761).
    /// When the walk yields no names, noop's known key list is read instead (DeviceConfigReadProbe.knownFlagKeys).
    public func readFlagSnapshot() async throws -> StrapFlagSnapshot {
        guard handshakeDone, let sid = strapId else { throw StrapLinkError.notReady("strap not connected") }
        guard !flagReadRunning else { throw StrapLinkError.notReady("strap settings are already being read") }
        flagReadRunning = true
        defer { flagReadRunning = false }
        let generation = connectionGeneration
        let waitSeconds = Int(config.timing.responseTimeout.rounded(.up))
        var walk = FeatureFlagProbeReport(family: .whoop5)
        var frames: [RawFrame] = []
        func keep(_ r: CommandResponse) {
            frames.append(RawFrame(receivedAt: clock.now, packetType: Int(r.frame[8]), bytes: Data(r.frame)))
        }

        var walkAllowed = false
        var startNote: String?
        if let start = try await channel.send(.sanctioned(.startFeatureFlagKeyExchange), awaitResponse: true) {
            keep(start)
            switch FeatureFlagProbe.parseStart(frame: start.frame, family: .whoop5) {
            case .success(let r):
                walk.noteStart(r)
                walkAllowed = r.resultCode == 1
                if !walkAllowed { startNote = "117 answered \(start.result.label)" }
            case .failure(let f):
                walk.noteFailure(f, command: 117, frame: start.frame)
            }
        } else {
            walk.noteTimeout(command: 117, seconds: waitSeconds)
        }
        walking: while walkAllowed, !walk.hasStopped, generation == connectionGeneration, handshakeDone {
            guard let next = try await channel.send(.sanctioned(.sendNextFeatureFlag), awaitResponse: true) else {
                walk.noteTimeout(command: 118, seconds: waitSeconds)
                break walking
            }
            keep(next)
            switch FeatureFlagProbe.parseNext(frame: next.frame, family: .whoop5) {
            case .success(let r):
                if !walk.noteNext(r) { break walking }
            case .failure(let f):
                walk.noteFailure(f, command: 118, frame: next.frame)
                break walking
            }
        }

        var keys = walk.keys
        if keys.isEmpty { keys = DeviceConfigReadProbe.knownFlagKeys(for: .whoop5) }
        for k in [R22Flag.key] + Self.r22VersionFlags where !keys.contains(k) { keys.append(k) }
        var readings: [StrapFlagReading] = []
        for key in keys.prefix(FeatureFlagProbe.maxFlags) {
            guard generation == connectionGeneration, handshakeDone else {
                readings.append(StrapFlagReading(key: key, value: nil, status: "not read: link lost"))
                continue
            }
            guard FeatureFlagValueReply.keyField(key) != nil else {
                readings.append(StrapFlagReading(key: key, value: nil,
                                                 status: "not read: key is not 1–31 printable ASCII bytes"))
                continue
            }
            let r = try await channel.send(.sanctioned(.getFeatureFlagValue(key: key)), awaitResponse: true)
            if let r { keep(r) }
            readings.append(FeatureFlagValueReply.reading(key: key, response: r))
        }

        let snapshot = StrapFlagSnapshot(strapId: sid, firmware: info?.firmware, readAt: clock.now,
                                         announcedCount: walk.reportedCount,
                                         walkStop: startNote ?? walk.stopReason ?? "walk ended without a stop reason",
                                         readings: readings, replyFrames: frames)
        guard let sink = flagSnapshotSink else {
            throw StrapLinkError.notSaved("no store is wired for strap settings")
        }
        do { try await sink(snapshot) } catch {
            throw StrapLinkError.notSaved("strap settings not stored: \(describeError(error))")
        }
        lastFlagSnapshot = snapshot
        let ok = readings.filter { $0.status == "ok" }.count
        logLine("strap settings: \(readings.count) key(s) read, \(ok) ok; walk: \(snapshot.walkStop)")
        return snapshot
    }
}
