// Ported from ryanbr/noop @ 2a1de76 (main, 2026-10-25): Strand/BLE/Commands.swift (`WhoopCommand.frame`),
// Strand/BLE/BLEManager.swift (setClockPayload L7101-7127, ackHistoricalChunk L2526, endData L7140), Strand/Collect/Backfiller.swift
// (`endData` L378-385), docs/PROTOCOL_WHOOP4.md, docs/PROTOCOL_TRANSPORT.md "WHOOP 4". PolyForm Noncommercial 1.0.0.
// Required Notice: Copyright 2026 NoopApp.
import Foundation
import WhoopProtocol

/// How much a WHOOP 4.0 command can change (inventory §5; CLAUDE.md rule 5: the label is information, never a gate).
public enum Whoop4Safety: String, Sendable {
    /// Reads only.
    case readOnly
    /// Changes a setting; can be undone.
    case changesSetting
    /// Deletes data, restarts the strap, or touches firmware.
    case dangerous

    public var label: String {
        switch self {
        case .readOnly: return "read only"
        case .changesSetting: return "changes a setting"
        case .dangerous: return "can disable the strap or delete data"
        }
    }
}

/// The 4.0 commands the link sends by itself, and the safety table for every number (inventory §5).
public enum Whoop4Command {
    public static let toggleRealtimeHR: UInt8 = 3
    /// TOGGLE_GENERIC_HR_PROFILE, payload `01` / `00` (inventory §5/§7; noop PROTOCOL_COMMANDS). Sent only when the HR broadcast switch is on
    /// or was just changed.
    public static let toggleGenericHRProfile: UInt8 = 14
    public static let reportVersionInfo: UInt8 = 7
    public static let setClock: UInt8 = 10
    public static let getClock: UInt8 = 11
    public static let abortHistoricalTransmits: UInt8 = 20
    public static let sendHistoricalData: UInt8 = 22
    /// HISTORICAL_DATA_RESULT: `01` + the HISTORY_END block. Deletes the chunk just read from the strap.
    public static let historicalDataResult: UInt8 = 23
    public static let getBatteryLevel: UInt8 = 26
    public static let getDataRange: UInt8 = 34
    public static let getHelloHarvard: UInt8 = 35
    public static let sendR10R11Realtime: UInt8 = 63
    /// Alarm and haptics (WHOOP4-WIRE 5; noop PROTOCOL_ALARMS "WHOOP 4"): sent only by the alarm engine, the timers and the buzz/silence buttons.
    public static let setAlarmTime: UInt8 = 66
    public static let getAlarmTime: UInt8 = 67
    public static let runAlarm: UInt8 = 68
    public static let disableAlarm: UInt8 = 69
    public static let runHapticsPattern: UInt8 = 79
    public static let stopHaptics: UInt8 = 122

    /// The inventory's red commands: firmware load/verify 36-38/83/85, DFU 45, reboot 29, power cycle 32, force trim 25, fuel
    /// gauge reset 99, and 23 (it deletes the chunk just read). The link never sends any of them on its own except 23, which
    /// it sends by design once per stored chunk, after the archive write. Everything else here is for the Command test page.
    public static let dangerous: Set<UInt8> = [23, 25, 29, 32, 36, 37, 38, 45, 83, 85, 99]
    /// 40, 42, 44 = GET_LED_DRIVE / GET_TIA_GAIN / GET_BIAS_OFFSET (inventory §5: reads; the SETs 39 / 41 / 43 stay "changes a setting").
    static let readOnly: Set<UInt8> = [7, 11, 20, 22, 26, 34, 35, 40, 42, 44, 84, 98]

    public static func safety(opcode: UInt8) -> Whoop4Safety {
        if dangerous.contains(opcode) { return .dangerous }
        if readOnly.contains(opcode) { return .readOnly }
        return .changesSetting
    }

    /// Opcodes `Whoop4Link` sends without being asked, in a connect + one history download. Nothing outside this set may be
    /// written on its own (`Whoop4LinkTests.testHandshakeBondsFirstThenReadsFirmwareSerialBatteryAndOnlySendsDocumentedCommands`).
    public static let sentAutomatically: Set<UInt8> = [
        getBatteryLevel, getHelloHarvard, reportVersionInfo, setClock, getClock, sendR10R11Realtime, getDataRange,
        sendHistoricalData, historicalDataResult, abortHistoricalTransmits,
        toggleGenericHRProfile,   // only while the app's HR broadcast switch is on (WHOOP4-WIRE 4)
    ]
}

/// WHOOP 4.0 framing and decoding. Layout (noop docs/PROTOCOL_WHOOP4.md "WHOOP 4 envelope"):
/// `AA | len u16 LE (= inner + 4) | crc8 over the 2 length bytes | type seq cmd payload | crc32 u32 LE over the inner`.
public enum Whoop4Frame {
    /// COMMAND (type 35).
    public static let commandType: UInt8 = 35

    /// A command frame, byte for byte what noop's `WhoopCommand.frame(seq:payload:)` builds.
    public static func command(_ opcode: UInt8, seq: UInt8, payload: [UInt8]) -> [UInt8] {
        frameFromPayload(payload, type: commandType, seq: seq, cmd: opcode)
    }

    /// SET_CLOCK, the 8-byte form `[seconds u32 LE][4 zero]` (newer 4.0 firmware latches it; 41.17.x ignores it).
    public static func setClockPayload(now: UInt32) -> [UInt8] { le32(now) + [0, 0, 0, 0] }

    /// SET_CLOCK, the legacy 9-byte form `[seconds u32 LE][5 zero]` (41.17.x latches only this one; newer firmware
    /// acknowledges it without latching, so sending both is harmless: BLEManager `sendSetClockBothForms`, noop #120).
    public static func setClockPayloadLegacy(now: UInt32) -> [UInt8] { le32(now) + [0, 0, 0, 0, 0] }

    static func le32(_ v: UInt32) -> [UInt8] {
        [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)]
    }

    /// The 8 bytes of a HISTORY_END the ack must echo: frame[17..<25] (noop Backfiller `endData`, family .whoop4). nil when the
    /// frame is too short to hold them. The block can run into the CRC32 trailer of a short frame (a real 25-byte capture
    /// does); it is an opaque echo and is never rebuilt or trimmed.
    public static func endToken(of frame: [UInt8]) -> HistoryEndToken? {
        guard frame.count >= 25 else { return nil }
        return HistoryEndToken(bytes: Array(frame[17..<25]))
    }

    /// HISTORICAL_DATA_RESULT payload: `01` + the HISTORY_END block, unchanged (noop BLEManager `ackHistoricalChunk`).
    public static func historyAckPayload(_ token: HistoryEndToken) -> [UInt8] { [0x01] + token.bytes }

    /// Packet type (frame[4]) of a 4.0 frame; nil when too short.
    public static func packetType(_ frame: [UInt8]) -> UInt8? { frame.count > 4 ? frame[4] : nil }

    /// COMMAND_RESPONSE (type 36). Offsets (noop PROTOCOL_TRANSPORT.md "WHOOP 4"): command 6, originating request seq 7,
    /// result 8, body from 9 to the CRC32 trailer. nil unless the frame passes the full 4.0 integrity check.
    public static func response(_ frame: [UInt8]) -> CommandResponse? {
        guard frame.count >= 9 + 4, frame[4] == 36, verifyFrame(frame, family: .whoop4).ok else { return nil }
        let bodyEnd = frame.count - 4
        return CommandResponse(command: frame[6], originSeq: frame[7], result: CommandResult(byte: frame[8]),
                               body: bodyEnd > 9 ? Array(frame[9..<bodyEnd]) : [], frame: frame)
    }

    /// GET_BATTERY_LEVEL body: `u16 LE` tenths of a percent (the standard 2A19 is a constant-100 stub on a 4.0, noop #77).
    public static func batteryPercent(_ body: [UInt8]) -> Double? {
        guard body.count >= 2 else { return nil }
        let raw = Int(body[0]) | Int(body[1]) << 8
        return raw <= 1100 ? Double(raw) / 10 : nil
    }

    /// GET_CLOCK reply body: strap unix seconds `u32 LE` first (noop PostHooks `GET_CLOCK`).
    public static func clockSeconds(_ body: [UInt8]) -> UInt32? {
        guard body.count >= 4 else { return nil }
        let s = UInt32(body[0]) | UInt32(body[1]) << 8 | UInt32(body[2]) << 16 | UInt32(body[3]) << 24
        return s == 0 ? nil : s
    }

    /// GET_DATA_RANGE reply (frame, type 36, cmd 34): the strap's newest stored record, unix seconds. Port of noop
    /// `WhoopProtocol/DataRange.newestUnix(from:wallNowUnix:futureSkewSeconds:)` (ryanbr/noop main, Packages/WhoopProtocol/Sources/
    /// WhoopProtocol/DataRange.swift): the u32 is not on a fixed grid (offset 8 on a 4.0), so every byte offset of the frame is
    /// read as a LE u32 and the newest word inside 2023-11..2030-03 wins, preferring one not more than `futureSkew` past
    /// `wallNow` (a garbage future word must not latch), falling back to the newest-any word. nil: no plausible word.
    public static func dataRangeNewestUnix(_ frame: [UInt8], wallNow: Int, futureSkew: Int = 48 * 3600) -> Int? {
        guard frame.count >= 4 else { return nil }
        let cutoff = wallNow + futureSkew
        var notFuture: Int?
        var any: Int?
        var i = 0
        while i + 4 <= frame.count {
            let w = Int(frame[i]) | Int(frame[i + 1]) << 8 | Int(frame[i + 2]) << 16 | Int(frame[i + 3]) << 24
            if w >= 1_700_000_000, w <= 1_900_000_000 {
                any = max(any ?? 0, w)
                if w <= cutoff { notFuture = max(notFuture ?? 0, w) }
            }
            i += 1
        }
        return notFuture ?? any
    }

    /// REPORT_VERSION_INFO reply: the Harvard firmware "a.b.c.d" (WhoopProtocol PostHooks `fw_harvard`).
    public static func firmware(_ frame: [UInt8]) -> String? {
        parseFrame(frame, family: .whoop4).parsed["fw_harvard"]?.stringValue
    }

    /// GET_HELLO_HARVARD reply: the 9-character serial at body offset 14 (WhoopProtocol `Whoop4HelloSerial`). The 54 bytes of key
    /// material beside it are never read.
    public static func serial(_ frame: [UInt8]) -> String? {
        guard frame.count > 9 + 4, frame[4] == 36, verifyFrame(frame, family: .whoop4).ok else { return nil }
        let length = Int(frame[1]) | Int(frame[2]) << 8
        guard length <= frame.count, 9 < length else { return nil }
        return Whoop4HelloSerial.decode(payload: Array(frame[9..<length]))
    }
}
