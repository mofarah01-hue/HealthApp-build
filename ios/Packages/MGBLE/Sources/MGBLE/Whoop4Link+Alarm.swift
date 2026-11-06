import Foundation
import MGDomain
import WhoopProtocol

// The WHOOP 4.0's strap alarm and haptics (WHOOP4-WIRE 5, Mo 2026-11-05: "when I select 4.0 it does all of that"), behind the same
// `StrapAlarmLinking` surface the 5/MG's `StrapLink` has, so the wake-alarm engine (App/Alarms) and the timers (App/Timers) drive either.
//
// Sources: ryanbr/noop docs/PROTOCOL_ALARMS.md "WHOOP 4" (live, read 2026-11-05), docs/PROTOCOL_COMMANDS.md "Haptics and alarms",
// docs/research/WHOOP4-INVENTORY-2026-11-05.md §5:
//   66 SET_ALARM_TIME   `01 || epoch u32 LE || subseconds u16 LE`, and the WORKING request appends two more zero bytes (9 bytes in
//                       all). "A seven-byte request was acknowledged but did not vibrate" (noop), so the 9-byte form is sent.
//   67 GET_ALARM_TIME   `01`. The reply layout is "incompletely mapped": the raw body is logged, nothing depends on it.
//   68 RUN_ALARM        `01`, paired with 79 for an immediate buzz ("both as acknowledged writes", noop).
//   69 DISABLE_ALARM    `01`.
//   79 RUN_HAPTICS_PATTERN `02 03 00 00 00` = preset 2, three loops (the only proven pattern); here `02 <loops> 00 00 00`.
//   122 STOP_HAPTICS    `00` (the legacy request).
// A correct strap clock is a separate prerequisite (noop lifecycle step 2): the epoch is the phone's time converted by the clock
// offset read on this connection, and the arm is refused when that offset is unread or more than `clockTolerance` off (the app sets
// the clock at pairing; re-pair to fix it). The 4.0 has ONE alarm slot ("does not establish multiple alarm slots"), so timer slots
// 2-6 are refused with words. DECODED, untested on Mo's strap: no 4.0 alarm has been seen to ring through this app.
extension Whoop4Link {
    /// SET needs a time still ahead of the strap; 10 s also covers the round trip (same lead as the 5/MG).
    public static let strapAlarmMinLead: TimeInterval = 10
    /// Slot already armed by this link within this many strap seconds of the wanted time: no rewrite on reconnect.
    public static let strapAlarmSameWithin: Int64 = 5

    /// SET_ALARM_TIME body: `01` + epoch u32 LE + subseconds u16 (zero) + the two appended zero bytes of the working form.
    public static func alarmPayload(epoch: UInt32) -> [UInt8] { [0x01] + Whoop4Frame.le32(epoch) + [0, 0, 0, 0] }

    /// RUN_HAPTICS_PATTERN body: preset 2, `loops` loops, three zero bytes (noop PROTOCOL_ALARMS "Immediate WHOOP 4 haptics").
    public static func hapticsPayload(loops: Int) -> [UInt8] { [0x02, UInt8(max(1, min(8, loops))), 0, 0, 0] }

    // MARK: StrapAlarmLinking (slot 1 = the one 4.0 alarm)

    public func armStrapAlarm(at phoneTime: Date, consentAt: Date) async throws -> StrapAlarmReport {
        guard handshakeDone else { throw StrapLinkError.notReady("the WHOOP 4.0 is not connected") }
        try await deferWhileDownloading("arming the strap alarm")
        guard let offset = status.clockOffsetSeconds else {
            throw StrapLinkError.refused("the WHOOP 4.0's clock was not read on this connection, so the alarm can't be placed on it - not armed")
        }
        guard abs(offset) <= config.timing.clockTolerance else {
            throw StrapLinkError.refused(String(format: "the WHOOP 4.0's clock is %.0f s off the phone's - not armed "
                                                + "(tap Pair WHOOP 4.0 so the app sets the clock first)", offset))
        }
        let now = clock.now
        guard phoneTime.timeIntervalSince(now) >= Self.strapAlarmMinLead else {
            throw StrapLinkError.refused("the alarm is less than \(Int(Self.strapAlarmMinLead)) s away - not armed")
        }
        let strapSeconds = (phoneTime.timeIntervalSince1970 + offset).rounded(.down)
        guard strapSeconds > 0, strapSeconds < Double(UInt32.max) else {
            throw StrapLinkError.refused("the alarm time does not fit the strap's clock field - not armed")
        }
        let epoch = UInt32(strapSeconds)
        let payload = Self.alarmPayload(epoch: epoch)
        // Re-arming on every reconnect must not rewrite an alarm this link already armed for the same time (a 66 at connect has been
        // reported to buzz on the 5/MG; the 4.0's read-back is not decodable, so the link's own memory is the check).
        if let held = armedAlarmEpoch, abs(Int64(held) - Int64(epoch)) <= Self.strapAlarmSameWithin {
            let result = "already set by this app (same time) - not rewritten"
            logLine("whoop4: strap alarm \(result)")
            return StrapAlarmReport(action: .arm, at: now, payloadHex: payload.hexLower, ok: true, result: result,
                                    strapTime: Date(timeIntervalSince1970: TimeInterval(held)))
        }
        var ok = false
        var result: String
        do {
            let r = try await channel.send(.test(opcode: Whoop4Command.setAlarmTime, payload: payload), awaitResponse: true)
            if let r, r.result == .success {
                ok = true
                armedAlarmEpoch = epoch
                let readback = await readAlarmRaw()
                result = "ok (strap answered ok; the 4.0's read-back layout is not mapped, raw \(readback ?? "no answer"), so the slot is not proven)"
            } else {
                result = "strap answered \(r?.result.label ?? "nothing") (body \(r?.body.hexLower ?? "-"))"
            }
        } catch {
            result = "write failed: \(describeError(error))"
        }
        await logAlarmWrite(opcode: Whoop4Command.setAlarmTime, name: "SET_ALARM_TIME (WHOOP 4.0)", payload: payload,
                            consentAt: consentAt, result: result)
        logLine("whoop4: strap alarm arm for \(phoneTime) (strap \(epoch)) → \(result)")
        return StrapAlarmReport(action: .arm, at: now, payloadHex: payload.hexLower, ok: ok, result: result,
                                strapTime: Date(timeIntervalSince1970: TimeInterval(epoch)))
    }

    public func disableStrapAlarm(consentAt: Date) async throws -> StrapAlarmReport {
        guard handshakeDone else { throw StrapLinkError.notReady("the WHOOP 4.0 is not connected") }
        let now = clock.now
        let payload: [UInt8] = [0x01]
        var ok = false
        var result: String
        do {
            let r = try await channel.send(.test(opcode: Whoop4Command.disableAlarm, payload: payload), awaitResponse: true)
            if let r, r.result == .success {
                ok = true
                armedAlarmEpoch = nil
                result = "ok"
            } else {
                result = "strap answered \(r?.result.label ?? "nothing") (body \(r?.body.hexLower ?? "-"))"
            }
        } catch {
            result = "write failed: \(describeError(error))"
        }
        await logAlarmWrite(opcode: Whoop4Command.disableAlarm, name: "DISABLE_ALARM (WHOOP 4.0)", payload: payload,
                            consentAt: consentAt, result: result)
        logLine("whoop4: strap alarm disable → \(result)")
        return StrapAlarmReport(action: .disable, at: now, payloadHex: payload.hexLower, ok: ok, result: result)
    }

    /// One buzz: 79 RUN_HAPTICS_PATTERN, then 68 RUN_ALARM (noop: the paired form is the reliable one). 68 runs the SAVED alarm, so it is
    /// skipped while this link holds an armed wake alarm (a timer buzz must not fire or consume it).
    public func buzz(_ pulses: BuzzPulses, consentAt: Date) async throws -> StrapAlarmReport {
        guard handshakeDone else { throw StrapLinkError.notReady("the WHOOP 4.0 is not connected") }
        try await deferWhileDownloading("the buzz")
        let now = clock.now
        let pattern = Self.hapticsPayload(loops: pulses.count)
        var ok = false
        var result: String
        do {
            let pat = try await channel.send(.test(opcode: Whoop4Command.runHapticsPattern, payload: pattern), awaitResponse: true)
            var run: CommandResponse?
            var ranAlarm = false
            if !alarmIsArmed {
                run = try await channel.send(.test(opcode: Whoop4Command.runAlarm, payload: [0x01]), awaitResponse: true)
                ranAlarm = true
            }
            let patOk = pat?.result == .success
            let runOk = !ranAlarm || run?.result == .success
            ok = patOk && runOk
            if ok {
                result = ranAlarm ? "ok" : "ok (79 only: 68 skipped, the wake alarm is armed)"
            } else if pat == nil {
                ok = true      // the write itself was acknowledged; the answer can follow the effect (as on the 5/MG)
                result = "sent (write acknowledged; no final answer within the timeout)"
            } else {
                result = "strap answered 79: \(pat?.result.label ?? "nothing")" + (ranAlarm ? ", 68: \(run?.result.label ?? "nothing")" : "")
            }
        } catch {
            result = "write failed: \(describeError(error))"
        }
        await logAlarmWrite(opcode: Whoop4Command.runHapticsPattern, name: "RUN_HAPTICS_PATTERN (WHOOP 4.0)", payload: pattern,
                            consentAt: consentAt, result: result)
        return StrapAlarmReport(action: .buzz, at: now, payloadHex: pattern.hexLower, ok: ok, result: result)
    }

    /// STOP_HAPTICS (122) `[00]`: one attempt, with response. Does not clear the alarm (noop: stopping a buzz "does not prove that a
    /// scheduled alarm was removed").
    public func silenceHaptics(consentAt: Date) async throws -> StrapAlarmReport {
        guard handshakeDone else { throw StrapLinkError.notReady("the WHOOP 4.0 is not connected") }
        let now = clock.now
        let payload: [UInt8] = [0x00]
        var ok = false
        var result: String
        do {
            let r = try await channel.send(.test(opcode: Whoop4Command.stopHaptics, payload: payload), awaitResponse: true)
            if let r {
                ok = r.result == .success
                result = ok ? "ok" : "strap answered \(r.result.label) (body \(r.body.hexLower))"
            } else {
                result = "sent (write acknowledged; the strap gave no answer within the timeout, so it may still be buzzing)"
            }
        } catch {
            result = "write failed: \(describeError(error))"
        }
        await logAlarmWrite(opcode: Whoop4Command.stopHaptics, name: "STOP_HAPTICS (WHOOP 4.0)", payload: payload,
                            consentAt: consentAt, result: result)
        logLine("whoop4: silence → \(result)")
        return StrapAlarmReport(action: .silence, at: now, payloadHex: payload.hexLower, ok: ok, result: result)
    }

    /// The 4.0's GET_ALARM_TIME layout is not mapped (noop), so there is no decoded record; the raw body goes to the log.
    public func readStrapAlarm() async throws -> StrapAlarmRecord? {
        guard handshakeDone else { throw StrapLinkError.notReady("the WHOOP 4.0 is not connected") }
        try await deferWhileDownloading("reading the strap alarm")
        let raw = await readAlarmRaw()
        logLine("whoop4: GET_ALARM_TIME raw body \(raw ?? "no answer") (layout not mapped)")
        return nil
    }

    // MARK: Timer slots: the 4.0 has one alarm slot

    public func armTimerAlarm(slot: TimerAlarmSlot, at phoneTime: Date, pattern: TimerAlarmPattern,
                              consentAt: Date) async throws -> StrapAlarmReport {
        throw StrapLinkError.refused(Self.noTimerSlots)
    }

    public func disableTimerAlarm(slot: TimerAlarmSlot, consentAt: Date) async throws -> StrapAlarmReport {
        throw StrapLinkError.refused(Self.noTimerSlots)
    }

    public func readTimerAlarm(slot: TimerAlarmSlot) async throws -> StrapAlarmRecord? { nil }

    static let noTimerSlots = "the WHOOP 4.0 has one alarm slot, kept for the wake alarm - a timer buzzes from the app when it ends, "
        + "not from the strap"

    // MARK: Internals

    /// This link armed a wake alarm whose time is still ahead (a due alarm clears itself on the strap).
    var alarmIsArmed: Bool {
        guard let epoch = armedAlarmEpoch else { return false }
        return Double(epoch) > clock.now.timeIntervalSince1970 + (status.clockOffsetSeconds ?? 0)
    }

    /// GET_ALARM_TIME `[01]` → the raw reply body in hex (nil when no usable answer).
    func readAlarmRaw() async -> String? {
        guard let r = try? await channel.send(.test(opcode: Whoop4Command.getAlarmTime, payload: [0x01]), awaitResponse: true),
              r.result == .success else { return nil }
        return r.body.hexLower
    }

    private func logAlarmWrite(opcode: UInt8, name: String, payload: [UInt8], consentAt: Date, result: String) async {
        let entry = StrapWriteEntry(command: Int(opcode), name: name, payloadHex: payload.hexLower, priorValue: nil, readback: nil,
                                    confirmedAt: consentAt, result: result, standingConsent: true, restored: nil)
        do { try await writeLog?.log(entry) } catch { logLine("whoop4: write log failed for \(name) — \(describeError(error))") }
    }
}

extension Whoop4Link: StrapAlarmLinking {}
