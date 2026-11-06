import Foundation
import MGDomain
import WhoopProtocol

// The strap's own alarm (slot 1) and the one-shot buzz — CLAUDE.md rule 5 as changed 2026-10-11 12:35 PT with Mo's
// go-ahead. Every write here goes WITH RESPONSE through `CommandChannel` (through the framer, which refuses nothing since T87), and
// is logged in the strap write log with what slot 1 held before and after (GET_ALARM_TIME, 67). The alarm page's
// switches are Mo's consent; `consentAt` is when he last saved them (logged as a standing consent, like SET_CLOCK).
//
// Facts (noop docs/PROTOCOL_ALARMS.md "WHOOP 5/MG", live 2026-10-11): SET needs seconds strictly later than the strap's
// current second, so the time is converted to the STRAP clock (phone time + the last clock readback offset) and must be
// at least `strapAlarmMinLead` away; a due alarm is cleared when it fires (one-shot — the app re-arms); SET answers
// [4, detail] (1 = valid); GET [4, ID] returns the 21-byte record; the buzz answers revision + detail (final success 5).
// While a haptic is active a newly due alarm can be cleared without vibrating — the caller must not buzz on top of the
// strap alarm. DECODED: one strap-driven wake seen on MG fw 50.41.1.0 (noop #864), none shown on 50.42.

/// What one alarm or buzz write did, for the alarm page.
public struct StrapAlarmReport: Equatable, Sendable {
    public enum Action: String, Equatable, Sendable {
        case arm, disable, buzz
        /// STOP_HAPTICS (122): the phone's Silence button (Mo 2026-10-12, DECISIONS.md D-030 UPDATE).
        case silence
    }

    public var action: Action
    public var at: Date
    public var payloadHex: String
    /// The strap took it: SUCCESS (SET: validation detail 1, and a matching read-back when one could be read). A buzz
    /// whose write was acknowledged but whose final answer did not come within the response timeout also counts.
    public var ok: Bool
    /// Words for the page and the write log ("ok", "strap answered FAILURE: time is not later than …").
    public var result: String
    /// Slot 1 before / after, when GET_ALARM_TIME could be read and decoded.
    public var before: StrapAlarmRecord?
    public var after: StrapAlarmRecord?
    /// The strap-clock instant that was armed (arm only).
    public var strapTime: Date?
    /// Arm only: did GET_ALARM_TIME read the slot back holding the armed time? true = the strap holds it; false = it read
    /// back something else; nil = the read-back could not be decoded (so "armed" is NOT proven). T9816 / C9.
    public var readbackMatches: Bool?

    public init(action: Action, at: Date, payloadHex: String, ok: Bool, result: String, before: StrapAlarmRecord? = nil,
                after: StrapAlarmRecord? = nil, strapTime: Date? = nil, readbackMatches: Bool? = nil) {
        self.action = action
        self.at = at
        self.payloadHex = payloadHex
        self.ok = ok
        self.result = result
        self.before = before
        self.after = after
        self.strapTime = strapTime
        self.readbackMatches = readbackMatches
    }
}

/// The alarm and buzz surface of the strap link (added 2026-10-11; separate from the frozen `StrapLinking`).
@MainActor
public protocol StrapAlarmLinking: AnyObject {
    /// Arms slot 1 for `phoneTime` (converted to the strap clock). Throws (nothing written) when the strap is not
    /// connected, its clock has not been read on this connection, or the time is less than `strapAlarmMinLead` away.
    func armStrapAlarm(at phoneTime: Date, consentAt: Date) async throws -> StrapAlarmReport
    /// Clears slot 1 (DISABLE_ALARM [02 01]).
    func disableStrapAlarm(consentAt: Date) async throws -> StrapAlarmReport
    /// One buzz of 1-8 pulses (RUN_HAPTIC_PATTERN_MAVERICK).
    func buzz(_ pulses: BuzzPulses, consentAt: Date) async throws -> StrapAlarmReport
    /// STOP_HAPTICS [01] (122): silences a buzzing strap. WITH RESPONSE, logged, one attempt. Decoded, untested on a real 5/MG.
    func silenceHaptics(consentAt: Date) async throws -> StrapAlarmReport
    /// GET_ALARM_TIME [04 01]; nil when the reply could not be decoded.
    func readStrapAlarm() async throws -> StrapAlarmRecord?
    /// Bug 2 (2026-10-14): arms TIMER slot 2-6 for `phoneTime` with `pattern` (same rules as slot 1: strap clock, 10 s lead,
    /// response check, a matching slot is not rewritten). Throws (nothing written) like `armStrapAlarm`.
    func armTimerAlarm(slot: TimerAlarmSlot, at phoneTime: Date, pattern: TimerAlarmPattern, consentAt: Date) async throws -> StrapAlarmReport
    /// Clears one timer slot (DISABLE_ALARM [02 slot]); never slot 1, never [02 FF].
    func disableTimerAlarm(slot: TimerAlarmSlot, consentAt: Date) async throws -> StrapAlarmReport
    /// GET_ALARM_TIME [04 slot]; nil when the reply could not be decoded.
    func readTimerAlarm(slot: TimerAlarmSlot) async throws -> StrapAlarmRecord?
}

extension StrapLink: StrapAlarmLinking {
    /// SET needs seconds strictly later than the strap's current second; 10 s also covers the round trip.
    public static let strapAlarmMinLead: TimeInterval = 10
    /// Slot 1 within this many strap seconds of the wanted time counts as already armed (no rewrite on reconnect).
    public static let strapAlarmSameWithin: Int64 = 5

    public func armStrapAlarm(at phoneTime: Date, consentAt: Date) async throws -> StrapAlarmReport {
        guard handshakeDone else { throw StrapLinkError.notReady("strap not connected") }
        guard let offset = info?.clockOffsetSeconds else {
            throw StrapLinkError.refused("the strap clock was not read on this connection, so the strap alarm can't be "
                                         + "placed on it — not armed")
        }
        let now = clock.now
        guard phoneTime.timeIntervalSince(now) >= Self.strapAlarmMinLead else {
            throw StrapLinkError.refused("the alarm is less than \(Int(Self.strapAlarmMinLead)) s away — not armed")
        }
        let strapMs = Int64(((phoneTime.timeIntervalSince1970 + offset) * 1000).rounded(.down))
        guard let time = StrapAlarmTime(strapUnixMs: strapMs) else {
            throw StrapLinkError.refused("the alarm time does not fit the strap's clock field — not armed")
        }
        let command = SanctionedCommand.setStrapAlarm(time)
        let before = await readSlot()
        // Re-arming on every new connection must not write when slot 1 already holds this alarm: a judes.club note says
        // 66 at connect can buzz, and overnight reconnects would then wake Mo. A few seconds of strap-clock drift is
        // harmless for a wake alarm; a reset clock or another alarm is far more than `strapAlarmSameWithin` off.
        if let held = before, !held.isUnset, held.isDefaultPattern,
           abs(Int64(held.seconds) - Int64(time.seconds)) <= Self.strapAlarmSameWithin {
            let result = "already set (slot 1 reads back the same time) — not rewritten"
            logLine("strap alarm: slot 1 already holds \(phoneTime) (strap \(held.seconds)) → \(result)")
            return StrapAlarmReport(action: .arm, at: now, payloadHex: command.payload.hexLower, ok: true, result: result,
                                    before: held, after: held, strapTime: held.date)
        }
        var after: StrapAlarmRecord?
        var ok = false
        var result: String
        do {
            let response = try await channel.send(.sanctioned(command), awaitResponse: true)
            after = await readSlot()
            let matches = after.map { $0.seconds == time.seconds }
            if let r = response {
                let detail = StrapAlarm.setDetailWords(r.body)
                if r.result == .success, r.body.count >= 2, r.body[0] == 0x04, r.body[1] == 1 {
                    switch matches {
                    case true?: ok = true; result = "ok"
                    case false?: result = "strap said valid, but slot 1 reads back \(after!.words)"
                    case nil: ok = true; result = "ok (slot 1 read-back could not be decoded)"
                    }
                } else {
                    result = "strap answered \(r.result.label): \(detail)"
                }
            } else if matches == true {
                ok = true
                result = "ok (no answer to the set within the timeout; slot 1 reads back the time)"
            } else {
                result = "no answer to the set; slot 1 reads back \(after?.words ?? "nothing decodable")"
            }
        } catch {
            result = "write failed: \(describeError(error))"
        }
        await logWrite(command, prior: before?.words, readback: after?.words, confirmedAt: consentAt, result: result,
                       standingConsent: true)
        logLine("strap alarm: arm slot 1 for \(phoneTime) (strap \(time.seconds)) → \(result)")
        return StrapAlarmReport(action: .arm, at: now, payloadHex: command.payload.hexLower, ok: ok, result: result,
                                before: before, after: after, strapTime: time.date)
    }

    public func disableStrapAlarm(consentAt: Date) async throws -> StrapAlarmReport {
        guard handshakeDone else { throw StrapLinkError.notReady("strap not connected") }
        let now = clock.now
        let command = SanctionedCommand.disableStrapAlarm
        let before = await readSlot()
        var after: StrapAlarmRecord?
        var ok = false
        var result: String
        do {
            let response = try await channel.send(.sanctioned(command), awaitResponse: true)
            after = await readSlot()
            if let r = response, r.result != .success {
                result = "strap answered \(r.result.label) (body \(r.body.hexLower))"
            } else if let a = after, !a.isUnset {
                result = "slot 1 still reads \(a.words)"
            } else {
                ok = true
                result = response == nil ? "ok (no answer within the timeout; slot 1 reads empty)" : "ok"
            }
        } catch {
            result = "write failed: \(describeError(error))"
        }
        await logWrite(command, prior: before?.words, readback: after?.words, confirmedAt: consentAt, result: result,
                       standingConsent: true)
        logLine("strap alarm: disable slot 1 → \(result)")
        return StrapAlarmReport(action: .disable, at: now, payloadHex: command.payload.hexLower, ok: ok, result: result,
                                before: before, after: after)
    }

    public func buzz(_ pulses: BuzzPulses, consentAt: Date) async throws -> StrapAlarmReport {
        guard handshakeDone else { throw StrapLinkError.notReady("strap not connected") }
        let now = clock.now
        let command = SanctionedCommand.buzz(pulses)
        var ok = false
        var result: String
        do {
            let response = try await channel.send(.sanctioned(command), awaitResponse: true)
            if let r = response {
                ok = r.result == .success
                result = ok ? "ok" : "strap answered \(r.result.label) (body \(r.body.hexLower))"
            } else {
                ok = true      // the write itself was acknowledged; the final answer can follow the effect
                result = "sent (write acknowledged; no final answer within the timeout)"
            }
        } catch {
            result = "write failed: \(describeError(error))"
        }
        await logWrite(command, prior: nil, readback: nil, confirmedAt: consentAt, result: result, standingConsent: true)
        return StrapAlarmReport(action: .buzz, at: now, payloadHex: command.payload.hexLower, ok: ok, result: result)
    }

    /// STOP_HAPTICS (122), body [01]: Mo's yes 2026-10-12 (DECISIONS.md D-030 UPDATE). Built like `buzz`: with response, logged
    /// to the strap write log, one attempt — a failure or a missing answer is reported, never retried silently. This does
    /// NOT clear slot 1 (noop PROTOCOL_ALARMS.md: stopping a buzz "does not disable stored alarms"). DECODED, UNTESTED: no 5/MG
    /// has ever been seen to answer 122; noop skips it on a 5/MG as unconfirmed. A refusal here is data, not a bug.
    public func silenceHaptics(consentAt: Date) async throws -> StrapAlarmReport {
        guard handshakeDone else { throw StrapLinkError.notReady("strap not connected") }
        let now = clock.now
        let command = SanctionedCommand.stopHaptics
        var ok = false
        var result: String
        do {
            let response = try await channel.send(.sanctioned(command), awaitResponse: true)
            if let r = response {
                ok = r.result == .success
                result = ok ? "ok" : "strap answered \(r.result.label) (body \(r.body.hexLower))"
            } else {
                // Unlike the buzz, nothing else will follow: an unanswered stop is NOT shown as done.
                result = "sent (write acknowledged; the strap gave no answer within the timeout, so it may still be buzzing)"
            }
        } catch {
            result = "write failed: \(describeError(error))"
        }
        await logWrite(command, prior: nil, readback: nil, confirmedAt: consentAt, result: result, standingConsent: true)
        logLine("strap silence: STOP_HAPTICS → \(result)")
        return StrapAlarmReport(action: .silence, at: now, payloadHex: command.payload.hexLower, ok: ok, result: result)
    }

    public func readStrapAlarm() async throws -> StrapAlarmRecord? {
        guard handshakeDone else { throw StrapLinkError.notReady("strap not connected") }
        return await readSlot()
    }

    /// GET_ALARM_TIME [04 01] → the decoded record, or nil (no answer, not SUCCESS, or not the 21-byte layout).
    func readSlot() async -> StrapAlarmRecord? {
        guard let r = try? await channel.send(.sanctioned(.getStrapAlarm), awaitResponse: true),
              r.result == .success else { return nil }
        return StrapAlarmRecord.parse(r.body)
    }

    // MARK: Timer slots 2-6 (bug 2, 2026-10-14)

    public func armTimerAlarm(slot: TimerAlarmSlot, at phoneTime: Date, pattern: TimerAlarmPattern,
                              consentAt: Date) async throws -> StrapAlarmReport {
        guard handshakeDone else { throw StrapLinkError.notReady("strap not connected") }
        guard let offset = info?.clockOffsetSeconds else {
            throw StrapLinkError.refused("the strap clock was not read on this connection, so the timer can't be placed "
                                         + "on the strap — not armed")
        }
        let now = clock.now
        guard phoneTime.timeIntervalSince(now) >= Self.strapAlarmMinLead else {
            throw StrapLinkError.refused("the timer ends less than \(Int(Self.strapAlarmMinLead)) s from now — not armed on the strap")
        }
        let strapMs = Int64(((phoneTime.timeIntervalSince1970 + offset) * 1000).rounded(.down))
        guard let time = StrapAlarmTime(strapUnixMs: strapMs) else {
            throw StrapLinkError.refused("the timer time does not fit the strap's clock field — not armed")
        }
        let command = SanctionedCommand.setTimerAlarm(time, slot: slot, pattern: pattern)
        let before = await readSlot(slot.id)
        // Same rule as slot 1: re-arming on reconnect must not rewrite a slot that already holds this timer.
        let tail = pattern.tail
        if let held = before, Self.timerRecordMatches(held, slot: slot, seconds: time.seconds, tail: tail) {
            let result = "already set (slot \(slot.id) reads back the same time and pattern) — not rewritten"
            logLine("timer alarm: \(result)")
            return StrapAlarmReport(action: .arm, at: now, payloadHex: command.payload.hexLower, ok: true, result: result,
                                    before: held, after: held, strapTime: held.date, readbackMatches: true)
        }
        var after: StrapAlarmRecord?
        var ok = false
        var result: String
        do {
            let response = try await channel.send(.sanctioned(command), awaitResponse: true)
            after = await readSlot(slot.id)
            let matches = after.map { Self.timerRecordMatches($0, slot: slot, seconds: time.seconds, tail: tail) }
            if let r = response {
                if r.result == .success, r.body.count >= 2, r.body[0] == 0x04, r.body[1] == 1 {
                    switch matches {
                    case true?: ok = true; result = "ok"
                    case false?: result = "strap said valid, but slot \(slot.id) reads back \(after!.words)"
                    case nil: ok = true; result = "ok (slot \(slot.id) read-back could not be decoded)"
                    }
                } else {
                    result = "strap answered \(r.result.label): \(StrapAlarm.setDetailWords(r.body))"
                }
            } else if matches == true {
                ok = true
                result = "ok (no answer to the set within the timeout; slot \(slot.id) reads back the time)"
            } else {
                result = "no answer to the set; slot \(slot.id) reads back \(after?.words ?? "nothing decodable")"
            }
        } catch {
            result = "write failed: \(describeError(error))"
        }
        await logWrite(command, prior: before?.words, readback: after?.words, confirmedAt: consentAt, result: result,
                       standingConsent: true)
        let matches = after.map { Self.timerRecordMatches($0, slot: slot, seconds: time.seconds, tail: tail) }
        logLine("timer alarm: arm slot \(slot.id) for \(phoneTime) (strap \(time.seconds)) → \(result); read-back "
                + "\(matches.map { $0 ? "matches" : "DIFFERS" } ?? "not decodable")")
        return StrapAlarmReport(action: .arm, at: now, payloadHex: command.payload.hexLower, ok: ok, result: result,
                                before: before, after: after, strapTime: time.date, readbackMatches: matches)
    }

    /// The one exact rule for "this slot holds this timer": same slot, same time (strap seconds), repeat and duration.
    static func timerRecordMatches(_ r: StrapAlarmRecord, slot: TimerAlarmSlot, seconds: UInt32, tail: [UInt8]) -> Bool {
        !r.isUnset && r.slot == slot.id && r.seconds == seconds && r.repeats == tail[2] && r.duration == tail[3]
    }

    public func disableTimerAlarm(slot: TimerAlarmSlot, consentAt: Date) async throws -> StrapAlarmReport {
        guard handshakeDone else { throw StrapLinkError.notReady("strap not connected") }
        let now = clock.now
        let command = SanctionedCommand.disableTimerAlarm(slot)
        let before = await readSlot(slot.id)
        var after: StrapAlarmRecord?
        var ok = false
        var result: String
        do {
            let response = try await channel.send(.sanctioned(command), awaitResponse: true)
            after = await readSlot(slot.id)
            if let r = response, r.result != .success {
                result = "strap answered \(r.result.label) (body \(r.body.hexLower))"
            } else if let a = after, !a.isUnset {
                result = "slot \(slot.id) still reads \(a.words)"
            } else if after == nil {
                // An undecodable read-back proves nothing: the slot may still be armed, so it is NOT confirmed cleared.
                result = "slot \(slot.id) read-back after the clear could not be decoded — not confirmed cleared"
            } else {
                ok = true
                result = response == nil ? "ok (no answer within the timeout; slot \(slot.id) reads empty)" : "ok"
            }
        } catch {
            result = "write failed: \(describeError(error))"
        }
        await logWrite(command, prior: before?.words, readback: after?.words, confirmedAt: consentAt, result: result,
                       standingConsent: true)
        logLine("timer alarm: disable slot \(slot.id) → \(result)")
        return StrapAlarmReport(action: .disable, at: now, payloadHex: command.payload.hexLower, ok: ok, result: result,
                                before: before, after: after)
    }

    public func readTimerAlarm(slot: TimerAlarmSlot) async throws -> StrapAlarmRecord? {
        guard handshakeDone else { throw StrapLinkError.notReady("strap not connected") }
        return await readSlot(slot.id)
    }

    /// GET_ALARM_TIME for a timer slot (2-6) → the decoded record, or nil.
    func readSlot(_ id: UInt8) async -> StrapAlarmRecord? {
        guard let slot = TimerAlarmSlot(Int(id)),
              let r = try? await channel.send(.sanctioned(.getTimerAlarm(slot)), awaitResponse: true),
              r.result == .success else { return nil }
        return StrapAlarmRecord.parse(r.body)
    }
}
