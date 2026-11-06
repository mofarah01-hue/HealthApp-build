import Foundation
import WhoopProtocol

// Strap commands (ARCHITECTURE D5, §4.4.3). CHANGED 2026-10-13 (T87, Mo: CLAUDE.md rule 5 removed): no runtime or static
// wall refuses a command. `SanctionedCommand` and `PolicyGatedCommand` are the app's own named commands and
// `StrapCommand.test` is any number from the Command test page; `CommandFramer` frames all three. Before: `CommandFramer`
// refused any opcode in `ForbiddenOpcodes.all` and any gated command the `StrapPolicy` did not allow, and
// app/tools/check_strap_safety.py failed the build (that tool now lives in superseded/).
// Opcode numbers: noop:Packages/WhoopProtocol/Sources/WhoopProtocol/Resources/whoop_protocol.json `CommandNumber`
// (byte-identical to whoop-live/whoop_protocol.json for every opcode used here), except 146/147, which that table
// lacks: noop:docs/PROTOCOL_COMMANDS.md matrix rows 146 SET_CLOCK / 147 GET_CLOCK.

// The one persistent strap write besides the clock (2026-10-11). Mo approved in chat: ONE write, enable_r22_packets = '1',
// with the prior value read and saved first, read back after, and a restore that writes the saved prior back; no R22
// version-flag write without a new yes. This replaces the 16-flag "deep-data unlock" (noop Whoop5Config @ e580175
// `enableR22Sequence`), which wrote '2' to enable_r22_packets — and on fw 50.42.1.0 '2' turns R22 OFF ('1' permits,
// '0' and '2' do not: noop docs/PROTOCOL_CONFIGURATION.md L181/L206 "Feature flag inventory"; openwhoop
// docs/whoop-redir-unlock-plan.md §2 from the Android APK; OpenStrap lib/src/commands.dart @ b4384588).

/// The R22 master feature flag — the only feature-flag key this app can write.
public enum R22Flag {
    public static let key = "enable_r22_packets"
    /// ASCII '1': permits historical packet 47 / layout 22 on fw 50.42.1.0 (sources above).
    public static let enableValue: UInt8 = 0x31
}

/// A value the restore may write back: one tri-state digit, '0' / '1' / '2' (noop PROTOCOL_CONFIGURATION "Value types
/// and storage": "Exact NUL-terminated ASCII 0, 1 or 2"). Anything else read from the strap cannot be restored.
public struct R22SavedValue: Equatable, Hashable, Sendable {
    public let byte: UInt8

    /// From the value text as read ("2"), or as the old write log spelled it ("0x32").
    public init?(text: String) {
        var t = text.trimmingCharacters(in: .whitespaces)
        if t.lowercased().hasPrefix("0x"), let b = UInt8(t.dropFirst(2), radix: 16) {
            t = String(UnicodeScalar(b))
        }
        guard t.count == 1, let b = t.utf8.first, (0x30...0x32).contains(b) else { return nil }
        byte = b
    }

    public var text: String { String(UnicodeScalar(byte)) }
}

/// What a SET_FF_VALUE (120) for enable_r22_packets writes: '1', or the saved prior value.
public enum R22PacketsValue: Equatable, Sendable {
    case enable
    case restore(R22SavedValue)

    public var byte: UInt8 {
        switch self {
        case .enable: return R22Flag.enableValue
        case .restore(let saved): return saved.byte
        }
    }

    public var text: String { String(UnicodeScalar(byte)) }
}

/// The 64 bytes after the revision byte of a named SET (120): key NUL-padded to 32, value text NUL-padded to 32 —
/// the 65-byte firmware contract with the leading [01] (noop PROTOCOL_CONFIGURATION L134 "The current named SET body is
/// 65 bytes"; openwhoop; OpenStrap). The 40-byte body noop's Whoop5Config builds is a "shorter historical request" that
/// "does not establish the complete request contract" (same doc) and is not used.
func namedSetFields(key: String, value: [UInt8]) -> [UInt8] {
    func field(_ bytes: [UInt8]) -> [UInt8] {
        let b = Array(bytes.prefix(31))
        return b + [UInt8](repeating: 0, count: 32 - b.count)
    }
    return field(Array(key.utf8)) + field(value)
}

// MARK: - The strap's own alarm and the one-shot buzz (CLAUDE.md rule 5 as changed 2026-10-11 12:35 PT, Mo: "apply
// rule 5 its fine"): SET_ALARM_TIME (66, revision 4, slot 1, default pattern), GET_ALARM_TIME (67), DISABLE_ALARM (69,
// slot 1) and RUN_HAPTIC_PATTERN_MAVERICK (19) with 1-8 pulses. Nothing else of the alarm/haptic family: RUN_ALARM (68)
// stays forbidden. STOP_HAPTICS (122) was policy-gated until 2026-10-12, when Mo approved it (see the STOP_HAPTICS note below
// and DECISIONS.md D-030 UPDATE). Layouts: noop docs/PROTOCOL_ALARMS.md "WHOOP 5/MG" (live,
// fetched 2026-10-11: SET 21-byte record incl. crescendo, GET [4, ID], DISABLE [2, ID], repeat byte < 8, repeat 7 needs
// duration 30-120) and HapticPayloads.swift L21/L44-46/L60-70 @ e580175. Frames are byte-checked against noop's goldens
// (DeviceFamilyFramingTests L296-358) in MGBLETests/StrapAlarmCommandTests. DECODED; one strap-driven wake was seen on
// MG fw 50.41.1.0 (noop #864), none on 50.42 — the app treats the strap alarm as experimental, with an iPhone backstop.

// MARK: - STOP_HAPTICS (122), the phone-side "Silence" (Mo 2026-10-12 10:05 PM PT, app-wp1/docs/DECISIONS.md "D-030 UPDATE":
// "1 yes that is what it means and do it thats fine"; his yes for this one command under CLAUDE.md rule 5's "any other
// write only on Mo's yes for that command"). ONE command, body [01] (revision 1 alone), sent WITH RESPONSE through
// `CommandChannel` like the buzz, logged in the strap write log, never retried silently. DECODED, UNTESTED: it has never been
// captured on a real 5/MG and noop's own app does not send it on a 5/MG ("we have NOT confirmed the 5/MG honours cmd 122").
// Opcode 122: whoop_protocol.json CommandNumber L54 (whoop-live, noop, _ARCHIVE copies identical). Body: ryanbr/noop
// docs/PROTOCOL_COMMANDS.md L355 "STOP_HAPTICS takes revision 1 alone and returns pending then a final result, each with
// body [1]" and docs/PROTOCOL_ALARMS.md L176 "Command 122 takes revision 1 alone"; OpenStrap protocol lib/src/commands.dart
// L983-984 `cmdStopHaptics` = [revision1] and its gen5 test gen5_command_surface_test.dart L430-440 (inner[3] == 0x01).
// Older sources send [00] (noop Strand/App/AppModel.swift L1477, a WHOOP 4 usage; OpenStrap research_playground.py L676);
// [01] is used here because it matches the revision-first body of command 19 (this file, `.buzz`).

/// Fixed bytes of the alarm and the buzz. app/tools/check_strap_safety.py (rule STRAP-ALARM) pins every literal here.
public enum StrapAlarm {
    /// The wake alarm's slot (the 5/MG has six, 1-6; noop PROTOCOL_ALARMS.md). Timers use 2-6 (`TimerAlarmSlot`, bug 2,
    /// 2026-10-14; built and tested, not yet sent by the app).
    public static let slot: UInt8 = 0x01
    /// WHOOP's waveform-effect pair 47, 152 and six empty effects — the default of both the buzz and the wake alarm
    /// (noop HapticPayloads.swift L21 `waveformEffects`).
    public static let effects: [UInt8] = [0x2F, 0x98, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
    /// The default wake pattern after the effects: loop control u16 0, overall repeat 7, duration 30 s, crescendo 0
    /// (noop HapticPayloads.swift L69 and PROTOCOL_ALARMS.md offset 20; the 20-byte form pads to the same frame).
    public static let wakeTail: [UInt8] = [0x00, 0x00, 0x07, 0x1E, 0x00]

    /// SET's response body is [4, detail] (noop PROTOCOL_ALARMS.md, table under "WHOOP 5/MG"). Words for the log.
    public static func setDetailWords(_ body: [UInt8]) -> String {
        guard body.count >= 2, body[0] == 0x04 else { return "no validation detail (body \(body.hexLower))" }
        switch body[1] {
        case 1: return "input passed validation"
        case 2: return "effect byte out of range"
        case 3: return "repeat count out of range"
        case 4: return "duration out of range for repeat count 7"
        case 10: return "time is not later than the strap's current second"
        case 11: return "alarm ID out of range"
        case 12: return "crescendo out of range"
        default: return "validation detail \(body[1])"
        }
    }
}

/// The instant a SET_ALARM_TIME carries, on the STRAP's clock: whole unix seconds + 1/32768-s ticks (noop
/// HapticPayloads.swift L62-63: ticks = (ms % 1000) × 32768 / 1000).
public struct StrapAlarmTime: Equatable, Hashable, Sendable {
    public let seconds: UInt32
    public let ticks: UInt16

    /// nil for an instant the u32 field cannot hold (before 1970 or after 2106).
    public init?(strapUnixMs ms: Int64) {
        guard ms >= 0, ms / 1000 <= Int64(UInt32.max) else { return nil }
        seconds = UInt32(ms / 1000)
        ticks = UInt16((ms % 1000) * 32768 / 1000)
    }

    public var bytes: [UInt8] { le32(seconds) + le16(ticks) }
    public var date: Date { Date(timeIntervalSince1970: TimeInterval(seconds) + TimeInterval(ticks) / 32768) }
}

/// How many pulses a buzz gives: 1-8. The repeat byte counts the pulses AFTER the first (noop #926, hardware-confirmed:
/// 3 → four buzzes) and the 5/MG firmware requires it below 8 (noop PROTOCOL_COMMANDS.md "Haptics and alarms").
public struct BuzzPulses: Equatable, Hashable, Sendable {
    public let count: Int

    public init?(_ count: Int) {
        guard (1...8).contains(count) else { return nil }
        self.count = count
    }

    public var repeatByte: UInt8 { UInt8(count - 1) }

    public static let one = BuzzPulses(1)!
    public static let eight = BuzzPulses(8)!
}

/// Bug 2 (2026-10-14): a strap alarm slot a timer may hold. The 5/MG has six (1-6, noop PROTOCOL_ALARMS.md; ID out of
/// range = SET detail 11); slot 1 stays the wake alarm's (`StrapAlarm.slot`), so timers get 2-6 (Mo e-7, R-075).
public struct TimerAlarmSlot: Equatable, Hashable, Sendable, Codable {
    public let id: UInt8

    public init?(_ id: Int) {
        guard (2...6).contains(id) else { return nil }
        self.id = UInt8(id)
    }

    public static let all: [TimerAlarmSlot] = (2...6).compactMap { TimerAlarmSlot($0) }
    public static let first = TimerAlarmSlot(2)!

    /// The lowest slot not in `used`; nil when all five hold timers (the sixth timer gets the phone alert and the in-app
    /// buzz only, and says so).
    public static func free(excluding used: Set<TimerAlarmSlot>) -> TimerAlarmSlot? {
        all.first { !used.contains($0) }
    }
}

/// Bug 2 (2026-10-14): what a timer's strap alarm does when it fires. The strap describes a buzz loop only as
/// effects + loop control + overall repeat + duration (noop PROTOCOL_ALARMS.md: repeat byte below 8; repeat 7 needs a
/// duration of 30-120 s), so Mo's "20 s, then 4 buzzes / 1 s / 4 until double tap" (e-7 (a)) cannot be one record: the
/// strap alarm is the part that works with the app in the background, and the app (when alive) carries on with the
/// 4 / 1 s / 4 loop. DECODED, UNTESTED: whether a double tap stops a strap alarm early is not confirmed on Mo's strap.
public enum TimerAlarmPattern: Equatable, Hashable, Sendable {
    /// "Double tap to stop": the longest loop the strap holds by itself, repeat 7 for 120 s (no app-side cap, D-029a).
    case untilDoubleTap
    /// "Buzz X times": X pulses, as the in-app buzz (repeat byte X-1); duration 30 s, valid for every repeat count.
    case pulses(BuzzPulses)

    public static let longestSeconds: UInt8 = 120

    /// The 5 bytes after the effects: loop control u16 LE 0, overall repeat, duration (s), crescendo 0.
    public var tail: [UInt8] {
        switch self {
        case .untilDoubleTap: return [0x00, 0x00, 0x07, Self.longestSeconds, 0x00]
        case .pulses(let p): return [0x00, 0x00, p.repeatByte, 0x1E, 0x00]
        }
    }
}

/// A GET_ALARM_TIME (67) reply body: the same 21-byte record SET writes (noop PROTOCOL_ALARMS.md: "GET takes [4, ID]
/// and, for a valid ID, returns the same 21-byte record"). The 20-byte form (no crescendo) is accepted too. An
/// all-zero time can mean "cleared/unset" OR a read fallback (same source) — `isUnset` says only the former is possible.
/// DECODED from that source; not yet observed from Mo's strap.
public struct StrapAlarmRecord: Equatable, Sendable {
    public let slot: UInt8
    public let seconds: UInt32
    public let ticks: UInt16
    public let effects: [UInt8]
    public let loopControl: UInt16
    public let repeats: UInt8
    public let duration: UInt8
    public let crescendo: UInt8?

    public static func parse(_ body: [UInt8]) -> StrapAlarmRecord? {
        guard body.count >= 20, body[0] == 0x04 else { return nil }
        let s = UInt32(body[2]) | (UInt32(body[3]) << 8) | (UInt32(body[4]) << 16) | (UInt32(body[5]) << 24)
        return StrapAlarmRecord(slot: body[1], seconds: s, ticks: UInt16(body[6]) | (UInt16(body[7]) << 8),
                                effects: Array(body[8..<16]), loopControl: UInt16(body[16]) | (UInt16(body[17]) << 8),
                                repeats: body[18], duration: body[19], crescendo: body.count > 20 ? body[20] : nil)
    }

    public var isUnset: Bool { seconds == 0 }
    public var date: Date? { isUnset ? nil : Date(timeIntervalSince1970: TimeInterval(seconds)) }
    /// The default pattern this app writes (`StrapAlarm.effects` + `wakeTail`).
    public var isDefaultPattern: Bool {
        effects == StrapAlarm.effects && loopControl == 0 && repeats == 7 && duration == 30 && (crescendo ?? 0) == 0
    }

    public var words: String {
        guard let d = date else { return "slot \(slot) empty" }
        return "slot \(slot) at strap time \(Int64(d.timeIntervalSince1970))"
            + (isDefaultPattern ? "" : " (pattern not the default: repeat \(repeats), \(duration) s)")
    }
}

// MARK: - MG ECG and raw motion (CLAUDE.md rule 5 as changed 2026-10-11 12:35 PT, Mo: "apply rule 5 its fine"; added
// 2026-10-11 19:50 PT, wave W8). Exactly: ECG start 123, 139, 125, 124 and stop 124, 125, 139; raw motion start 81 + 106
// [01 01] and stop 82 + 106 [01 00]. Every body is pinned here (app/tools/check_strap_safety.py rule ECG-IMU), every write
// goes WITH RESPONSE, and each family sits behind its own off-by-default app switch (StrapLink+Ecg / +RawMotion refuse an
// ON write while the switch is off). Layouts (live, ryanbr/noop @ e580175, fetched 2026-10-11): docs/PROTOCOL_ECG.md
// L38-45 (every command revision 01; 123 [01 01] right / [01 02] left; 124 [01 01] stop / [01 02] start, 0 fails;
// 125 and 139 [01 00] off / [01 01] on) and L69-75 (select wrist, choose outputs, start; cleanup stops generation and the
// gates); docs/RAW_DATA_CAPTURE.md L21-28 (81 [01], 106 [01 01]; stop 82 [01], 106 [01 00] — hardware-verified there);
// Strand/BLE/BLEManager.swift L2205-2220, L2233-2251 (raw motion), L4459-4472 / L4514-4535 (ECG start / stop order).
// Frames are byte-checked against noop's own builders (Whoop5Ecg.*Frame) and a stdlib Python framer in
// MGBLETests/EcgMotionCommandTests. DECODED for ECG (no frame from Mo's strap yet); the raw-motion sequence is what noop
// verified on 5/MG hardware.

/// SELECT_WRIST argument: the wrist the strap is WORN on (noop Whoop5Ecg.swift L404-406 `WristSelection`: right = 1,
/// left = 2; PROTOCOL_ECG.md L40). Whether the strap keeps it across a reboot is not established (L50-52).
public enum EcgWrist: UInt8, CaseIterable, Codable, Sendable {
    case right = 0x01
    case left = 0x02
}

/// TOGGLE_LABRADOR_DATA_GENERATION argument (noop Whoop5Ecg.swift L429-431 `ControlSignal`; PROTOCOL_ECG.md L41: 0 and
/// other arguments fail; 3 also starts, never sent here).
public enum EcgGeneration: UInt8, CaseIterable, Sendable {
    case stop = 0x01
    case start = 0x02
}

/// The verbatim 8-byte block of a HISTORY_END that the ack must echo (frame[21..<29] on 5/MG).
/// noop:Strand/Collect/Backfiller.swift L378-385; noop:docs/PROTOCOL_TRANSPORT.md "History sequencing":
/// "preserve its eight-byte acknowledgement block verbatim … Do not reconstruct that block".
public struct HistoryEndToken: Hashable, Sendable {
    public let bytes: [UInt8]

    public init?(bytes: [UInt8]) {
        guard bytes.count == 8 else { return nil }
        self.bytes = bytes
    }

    /// Slices the token out of a complete 5/MG HISTORY_END frame. nil when the frame is too short to hold it
    /// in front of its CRC32 trailer.
    public init?(endFrame: [UInt8]) {
        guard endFrame.count >= 29 + 4 else { return nil }
        self.init(bytes: Array(endFrame[21..<29]))
    }

    public var hex: String { bytes.hexLower }

    /// The trim cursor: the token's first u32 LE (noop Interpreter `decodeWhoop5Metadata`, `trim_cursor`@21).
    public var trim: UInt32 {
        UInt32(bytes[0]) | (UInt32(bytes[1]) << 8) | (UInt32(bytes[2]) << 16) | (UInt32(bytes[3]) << 24)
    }
}

/// Commands the app may send on its own (D5 "Sanctioned"). Payload shapes cite their source.
public enum SanctionedCommand: Equatable, Sendable {
    /// 145 GET_HELLO, revision 1 — the CLIENT_HELLO bond trigger. At seq 1 this frames to exactly
    /// `DeviceFamily.whoop5ClientHello` (Goose `clientHelloFrameHex`; whoop-live WHOOP5_CLIENT_HELLO).
    case getHello
    /// 3 TOGGLE_REALTIME_HR [01]/[00] (noop BLEManager `send(.toggleRealtimeHR, payload: [0x01])`; dashboard.py L258-264).
    case toggleRealtimeHR(on: Bool)
    /// 63 SEND_R10_R11_REALTIME [01]/[00] (noop BLEManager `send(.sendR10R11Realtime, payload: [0x00/0x01])`).
    case sendR10R11Realtime(on: Bool)
    /// 147 GET_CLOCK, revision 1 (noop:docs/PROTOCOL_TRANSPORT.md "Clock and identity contracts").
    case getClock
    /// 146 SET_CLOCK: [01][unix u32 LE][ticks u16 LE, 1/32768 s, 0…32767] (same source).
    case setClock(unix: UInt32, ticks: UInt16)
    /// 11 GET_CLOCK (deprecated pair), empty body — noop's live 5/MG form (BLEManager L6950 `send(.getClock, payload: [])`).
    case getClockDeprecated
    /// 10 SET_CLOCK (deprecated pair): [unix u32 LE][00 00 00 00] — noop's live 5/MG form (BLEManager.setClockPayload L7087).
    case setClockDeprecated(unix: UInt32)
    /// 22 SEND_HISTORICAL_DATA [00] — empty serves nothing (noop BLEManager L2578-2582, verified on device).
    case sendHistoricalData
    /// 23 HISTORICAL_DATA_RESULT [01] + the END's 8-byte token (noop BLEManager L2504-2505; golden in
    /// noop Whoop5HistoricalTests `testWhoop5HistoricalAckFrameMatchesHardwareProvenBytes`).
    case historicalDataResult(token: HistoryEndToken)
    /// 20 ABORT_HISTORICAL_TRANSMITS [00] — a stop request, not a trim (noop BLEManager L2690-2697; PROTOCOL_TRANSPORT).
    case abortHistoricalTransmits
    /// 117 START_FF_KEY_EXCHANGE [01]: resets the strap's feature-key cursor and answers [rev 1][count u8]. Read-only.
    /// noop:docs/PROTOCOL_CONFIGURATION.md "Named configuration interface" (fw 50.42.1.0); FeatureFlagProbe (#761).
    case startFeatureFlagKeyExchange
    /// 118 SEND_NEXT_FF [01]: advances the strap's own cursor and names one key — the body is revision 1 only, NOT a
    /// caller-supplied index (same source: "advances the feature enumeration cursor"; noop FeatureFlagProbe sends the
    /// same [01] repeatedly). Read-only.
    case sendNextFeatureFlag
    /// 128 GET_FF_VALUE: [01] + key NUL-padded to 32, at most 31 key bytes (noop:docs/PROTOCOL_CONFIGURATION.md
    /// "Configuration reads — commands 121 and 128"; DeviceConfigReadProbe.requestBody). Any key: it is a read.
    case getFeatureFlagValue(key: String)
    /// 121 GET_DEVICE_CONFIG_VALUE: [01] + key NUL-padded to 32 (same source). Read-only.
    case getDeviceConfigValue(key: String)
    /// 84 GET_BODY_LOCATION_AND_STATUS [00] (noop BLEManager L4020, default payload). Read-only.
    case getBodyLocationAndStatus
    /// 151 GET_BATTERY_PACK_INFO, revision 1 (noop:docs/PROTOCOL_TRANSPORT.md "Battery pack — command 151"). Read-only.
    case getBatteryPackInfo
    /// 107 ENABLE_OPTICAL_DATA [01, on]: optical session SAVING (banked R20 in history) — a revision-1 boolean,
    /// session-scoped, no persistent config (noop:docs/PROTOCOL_CONFIGURATION.md L217-220 "Collection, storage and
    /// live transport"; whoop-rs client.rs L426-433; openwhoop docs/spo2-research.md §10). Mo approved 2026-10-11
    /// (behind an off-by-default switch). Payload pinned to [01 01] / [01 00]; the app sends only the OFF form.
    case enableOpticalData(on: Bool)
    /// 108 TOGGLE_OPTICAL_MODE [01, on]: LIVE optical delivery (R20 records, packet type 43, ~1 frame/s of 25 Hz
    /// samples; same sources). Session-scoped. Payload pinned to [01 01] / [01 00].
    case toggleOpticalMode(on: Bool)
    /// 120 SET_FF_VALUE for enable_r22_packets ONLY: [01] + key 32 + value 32 (65 bytes), '1' or the saved prior.
    /// Sent only after `StrapWriteConfirmer` returns `.confirmed` (§4.4.5), with response, then read back with 128.
    case setR22Packets(R22PacketsValue)
    /// 66 SET_ALARM_TIME revision 4: slot 1, the strap-clock instant, the default wake pattern (21 bytes). Persistent
    /// until it fires (one-shot) or is disabled; the strap fires it on its own clock (rule 5, 2026-10-11).
    case setStrapAlarm(StrapAlarmTime)
    /// 67 GET_ALARM_TIME [04 01]: reads slot 1 back. Read-only.
    case getStrapAlarm
    /// 69 DISABLE_ALARM [02 01]: clears slot 1 only (noop PROTOCOL_ALARMS.md "Disable": [2, ID] one, [2, 255] all).
    case disableStrapAlarm
    /// Bug 2 (2026-10-14): 66 SET_ALARM_TIME revision 4 in a TIMER slot (2-6), so a timer's end buzzes on the strap's own
    /// clock with the app in the background (Mo e-7: "yes to slots"). Same 21-byte record as `setStrapAlarm`; only the
    /// slot and the repeat / duration tail differ (`TimerAlarmPattern`). DECODED, UNTESTED on Mo's strap.
    case setTimerAlarm(StrapAlarmTime, slot: TimerAlarmSlot, pattern: TimerAlarmPattern)
    /// 67 GET_ALARM_TIME [04 slot] for a timer slot. Read-only.
    case getTimerAlarm(TimerAlarmSlot)
    /// 69 DISABLE_ALARM [02 slot] for one timer slot (never [02 FF], which would clear the wake alarm too).
    case disableTimerAlarm(TimerAlarmSlot)
    /// 19 RUN_HAPTIC_PATTERN_MAVERICK: one buzz of 1-8 pulses, default effects (12-byte body). One-shot.
    case buzz(BuzzPulses)
    /// 122 STOP_HAPTICS [01]: stops a buzz in progress (the phone's Silence button). Approved by Mo 2026-10-12 (DECISIONS.md
    /// D-030 UPDATE, T159); body and sources in the STOP_HAPTICS note above. DECODED, UNTESTED on a real 5/MG.
    case stopHaptics
    /// 123 SELECT_WRIST [01, wrist] — first write of the ECG start (rule 5). Sent only from `StrapLink.startEcgReading`.
    case ecgSelectWrist(EcgWrist)
    /// 139 TOGGLE_LABRADOR_FILTERED [01, on]: the filtered ECG leaves the strap live (packet 43, layout 17).
    case ecgFilteredLive(on: Bool)
    /// 125 TOGGLE_LABRADOR_RAW_SAVE [01, on]: the raw ECG is saved to history (packet 47, layout 16).
    case ecgSaveRaw(on: Bool)
    /// 124 TOGGLE_LABRADOR_DATA_GENERATION [01, 02] start / [01, 01] stop.
    case ecgGeneration(EcgGeneration)
    /// 81 START_RAW_DATA [01] — must precede 106 [01 01]; 106 alone acks without starting the IMU (RAW_DATA_CAPTURE L21).
    case startRawMotion
    /// 82 STOP_RAW_DATA [01].
    case stopRawMotion
    /// 106 TOGGLE_IMU_MODE [01, on]: live 100 Hz six-axis IMU (packet 43, layout 21).
    case imuMode(on: Bool)
    /// 34 GET_DATA_RANGE [00]: a READ of the strap's history ring (read cursor, write cursor, acknowledged/trim
    /// boundary, capacity); nothing moves. Body = what noop sends: BLEManager L7025 `send(.getDataRange)` with `send`'s
    /// default payload [0x00] (L2281), ryanbr/noop @ e580175; reply layout noop:docs/PROTOCOL_TRANSPORT.md "Data range —
    /// command 34". Added 2026-10-11 23:24 PDT (wave W12b, #111/#119) with Mo's yes ("read without deleting of course").
    /// Built only by the read-without-deleting test (StrapLink+HistoryProbe.swift; app/tools/check_strap_safety.py rule
    /// DATA-RANGE-PROBE).
    case getDataRange

    public var opcode: UInt8 {
        switch self {
        case .getHello: return 145
        case .toggleRealtimeHR: return 3
        case .sendR10R11Realtime: return 63
        case .getClock: return 147
        case .setClock: return 146
        case .getClockDeprecated: return 11
        case .setClockDeprecated: return 10
        case .sendHistoricalData: return 22
        case .historicalDataResult: return 23
        case .abortHistoricalTransmits: return 20
        case .startFeatureFlagKeyExchange: return 117
        case .sendNextFeatureFlag: return 118
        case .getFeatureFlagValue: return 128
        case .getDeviceConfigValue: return 121
        case .getBodyLocationAndStatus: return 84
        case .getBatteryPackInfo: return 151
        case .enableOpticalData: return 107
        case .toggleOpticalMode: return 108
        case .setR22Packets: return 120
        case .setStrapAlarm: return 66
        case .getStrapAlarm: return 67
        case .disableStrapAlarm: return 69
        case .setTimerAlarm: return 66
        case .getTimerAlarm: return 67
        case .disableTimerAlarm: return 69
        case .buzz: return 19
        case .stopHaptics: return 122
        case .ecgSelectWrist: return 123
        case .ecgFilteredLive: return 139
        case .ecgSaveRaw: return 125
        case .ecgGeneration: return 124
        case .startRawMotion: return 81
        case .stopRawMotion: return 82
        case .imuMode: return 106
        case .getDataRange: return 34
        }
    }

    public var name: String {
        switch self {
        case .getHello: return "GET_HELLO"
        case .toggleRealtimeHR: return "TOGGLE_REALTIME_HR"
        case .sendR10R11Realtime: return "SEND_R10_R11_REALTIME"
        case .getClock: return "GET_CLOCK"
        case .setClock: return "SET_CLOCK"
        case .getClockDeprecated: return "GET_CLOCK_DEPRECATED"
        case .setClockDeprecated: return "SET_CLOCK_DEPRECATED"
        case .sendHistoricalData: return "SEND_HISTORICAL_DATA"
        case .historicalDataResult: return "HISTORICAL_DATA_RESULT"
        case .abortHistoricalTransmits: return "ABORT_HISTORICAL_TRANSMITS"
        case .startFeatureFlagKeyExchange: return "START_FF_KEY_EXCHANGE"
        case .sendNextFeatureFlag: return "SEND_NEXT_FF"
        case .getFeatureFlagValue: return "GET_FF_VALUE"
        case .getDeviceConfigValue: return "GET_DEVICE_CONFIG_VALUE"
        case .getBodyLocationAndStatus: return "GET_BODY_LOCATION_AND_STATUS"
        case .getBatteryPackInfo: return "GET_BATTERY_PACK_INFO"
        case .enableOpticalData: return "ENABLE_OPTICAL_DATA"
        case .toggleOpticalMode: return "TOGGLE_OPTICAL_MODE"
        case .setR22Packets: return "SET_FF_VALUE"
        case .setStrapAlarm: return "SET_ALARM_TIME"
        case .getStrapAlarm: return "GET_ALARM_TIME"
        case .disableStrapAlarm: return "DISABLE_ALARM"
        case .setTimerAlarm: return "SET_ALARM_TIME"
        case .getTimerAlarm: return "GET_ALARM_TIME"
        case .disableTimerAlarm: return "DISABLE_ALARM"
        case .buzz: return "RUN_HAPTIC_PATTERN_MAVERICK"
        case .stopHaptics: return "STOP_HAPTICS"
        case .ecgSelectWrist: return "SELECT_WRIST"
        case .ecgFilteredLive: return "TOGGLE_LABRADOR_FILTERED"
        case .ecgSaveRaw: return "TOGGLE_LABRADOR_RAW_SAVE"
        case .ecgGeneration: return "TOGGLE_LABRADOR_DATA_GENERATION"
        case .startRawMotion: return "START_RAW_DATA"
        case .stopRawMotion: return "STOP_RAW_DATA"
        case .imuMode: return "TOGGLE_IMU_MODE"
        case .getDataRange: return "GET_DATA_RANGE"
        }
    }

    public var payload: [UInt8] {
        switch self {
        case .getHello: return [0x01]
        case .toggleRealtimeHR(let on), .sendR10R11Realtime(let on): return [on ? 0x01 : 0x00]
        case .getClock: return [0x01]
        case .setClock(let unix, let ticks): return [0x01] + le32(unix) + le16(min(ticks, 32767))
        case .getClockDeprecated: return []
        case .setClockDeprecated(let unix): return le32(unix) + [0, 0, 0, 0]
        case .sendHistoricalData: return [0x00]
        case .historicalDataResult(let token): return [0x01] + token.bytes
        case .abortHistoricalTransmits: return [0x00]
        case .startFeatureFlagKeyExchange, .sendNextFeatureFlag: return [0x01]
        case .getFeatureFlagValue(let key): return DeviceConfigReadProbe.requestBody(key: key)
        case .getDeviceConfigValue(let key): return DeviceConfigReadProbe.requestBody(key: key)
        case .getBodyLocationAndStatus: return [0x00]
        case .getBatteryPackInfo: return [0x01]
        case .enableOpticalData(let on), .toggleOpticalMode(let on): return [0x01, on ? 0x01 : 0x00]
        case .setR22Packets(let value):
            return [0x01] + namedSetFields(key: R22Flag.key, value: [value.byte])
        case .setStrapAlarm(let at): return [0x04, StrapAlarm.slot] + at.bytes + StrapAlarm.effects + StrapAlarm.wakeTail
        case .getStrapAlarm: return [0x04, StrapAlarm.slot]
        case .disableStrapAlarm: return [0x02, StrapAlarm.slot]
        case let .setTimerAlarm(at, slot, pattern): return [0x04, slot.id] + at.bytes + StrapAlarm.effects + pattern.tail
        case .getTimerAlarm(let slot): return [0x04, slot.id]
        case .disableTimerAlarm(let slot): return [0x02, slot.id]
        case .buzz(let pulses): return [0x01] + StrapAlarm.effects + [0x00, 0x00, pulses.repeatByte]
        case .stopHaptics: return [0x01]
        case .ecgSelectWrist(let wrist): return [0x01, wrist.rawValue]
        case .ecgFilteredLive(let on), .ecgSaveRaw(let on), .imuMode(let on): return [0x01, on ? 0x01 : 0x00]
        case .ecgGeneration(let signal): return [0x01, signal.rawValue]
        case .startRawMotion, .stopRawMotion: return [0x01]
        case .getDataRange: return [0x00]
        }
    }

    /// One value of every case, for the policy tests and audits. Add a line here when adding a case.
    public static let everyCase: [SanctionedCommand] = [
        .getHello, .toggleRealtimeHR(on: true), .sendR10R11Realtime(on: true), .getClock,
        .setClock(unix: 1_780_000_000, ticks: 0), .getClockDeprecated, .setClockDeprecated(unix: 1_780_000_000),
        .sendHistoricalData, .historicalDataResult(token: HistoryEndToken(bytes: [0, 0, 0, 0, 0, 0, 0, 0])!),
        .abortHistoricalTransmits, .startFeatureFlagKeyExchange, .sendNextFeatureFlag,
        .getFeatureFlagValue(key: "enable_r22_packets"), .getDeviceConfigValue(key: "k"),
        .getBodyLocationAndStatus, .getBatteryPackInfo, .enableOpticalData(on: false), .toggleOpticalMode(on: true),
        .setR22Packets(.enable), .setStrapAlarm(StrapAlarmTime(strapUnixMs: 1_780_000_000_000)!), .getStrapAlarm,
        .disableStrapAlarm,
        .setTimerAlarm(StrapAlarmTime(strapUnixMs: 1_780_000_000_000)!, slot: .first, pattern: .untilDoubleTap),
        .getTimerAlarm(.first), .disableTimerAlarm(.first), .buzz(.one), .stopHaptics, .ecgSelectWrist(.left), .ecgFilteredLive(on: true), .ecgSaveRaw(on: true),
        .ecgGeneration(.start), .startRawMotion, .stopRawMotion, .imuMode(on: true), .getDataRange,
    ]
}

/// Commands that exist in code and are no longer refused at runtime (T87, 2026-10-13: rule 5 removed; D5
/// "Policy-gated" used to refuse them). Their bodies are NOT pinned: they are passed through verbatim and must be reviewed against
/// noop before a flag is flipped. 19 (the buzz) left this set on 2026-10-11: it is `SanctionedCommand.buzz` with a
/// pinned 1-8 pulse body (rule 5 as changed that day).
/// CHANGED 2026-10-11 19:50 PT (wave W8, rule 5 as changed 12:35 PT): the ECG family 123 SELECT_WRIST, 124
/// TOGGLE_LABRADOR_DATA_GENERATION, 125 TOGGLE_LABRADOR_RAW_SAVE, 139 TOGGLE_LABRADOR_FILTERED and the raw-motion family
/// 81 START_RAW_DATA, 82 STOP_RAW_DATA, 106 TOGGLE_IMU_MODE left this enum for `SanctionedCommand` (.ecgSelectWrist,
/// .ecgGeneration, .ecgSaveRaw, .ecgFilteredLive, .startRawMotion, .stopRawMotion, .imuMode) with pinned bodies.
/// Previously they were here as `selectWrist(body:)`, `labradorDataGeneration(body:)`, `labradorRawSave(body:)`,
/// `labradorFiltered(body:)`, `startRawData` / `stopRawData` (body [00], which noop's verified sequence contradicts:
/// it sends [01], RAW_DATA_CAPTURE.md L24/L27) and `toggleIMUMode(body:)`.
/// CHANGED 2026-10-12 (Mo's yes, DECISIONS.md D-030 UPDATE): 122 STOP_HAPTICS left this enum for `SanctionedCommand.stopHaptics`
/// (pinned body [01]). It was `stopHaptics` here with body [00], requirement `.haptics`; no gated command needs `.haptics` now.
public enum PolicyGatedCommand: Equatable, Sendable {
    /// 14 TOGGLE_GENERIC_HR_PROFILE (HR broadcast).
    case toggleGenericHRProfile(on: Bool)
    /// 119 SET_DEVICE_CONFIG_VALUE: [01] + key NUL-padded to 32 + value (Whoop5Config.deviceConfigBody).
    case setDeviceConfigValue(key: String, value: UInt8)

    public var opcode: UInt8 {
        switch self {
        case .toggleGenericHRProfile: return 14
        case .setDeviceConfigValue: return 119
        }
    }

    public var name: String {
        switch self {
        case .toggleGenericHRProfile: return "TOGGLE_GENERIC_HR_PROFILE"
        case .setDeviceConfigValue: return "SET_DEVICE_CONFIG_VALUE"
        }
    }

    public var payload: [UInt8] {
        switch self {
        case .toggleGenericHRProfile(let on): return [on ? 0x01 : 0x00]
        case .setDeviceConfigValue(let key, let value):
            return [0x01] + Whoop5Config.deviceConfigBody(name: key, value: value)
        }
    }

    /// One value of every case. Add a line here when adding a case.
    public static let everyCase: [PolicyGatedCommand] = [
        .toggleGenericHRProfile(on: true), .setDeviceConfigValue(key: "k", value: 0x31),
    ]
}

/// CHANGED 2026-10-13 (T87, Mo: CLAUDE.md rule 5 removed); `r22Write` deleted 2026-10-17 (round 9 r9d):
/// `haptics`, `selectWrist`, `ecg`, `hrBroadcast` and `rawCapture` no longer govern any command: nothing
/// refuses a command on policy. They stay so `StrapPolicy` keeps its shape. Before, a policy-gated command was refused
/// unless its switch was on, and `b1` had every switch off.
public struct StrapPolicy: Equatable, Sendable {
    public var haptics: Bool
    public var selectWrist: Bool
    public var ecg: Bool
    public var hrBroadcast: Bool
    public var rawCapture: Bool

    public init(haptics: Bool = false, selectWrist: Bool = false, ecg: Bool = false, hrBroadcast: Bool = false,
                rawCapture: Bool = false) {
        self.haptics = haptics
        self.selectWrist = selectWrist
        self.ecg = ecg
        self.hrBroadcast = hrBroadcast
        self.rawCapture = rawCapture
    }

    public static let b1 = StrapPolicy()
}

@inline(__always) func le32(_ v: UInt32) -> [UInt8] {
    [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)]
}

@inline(__always) func le16(_ v: UInt16) -> [UInt8] {
    [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)]
}
