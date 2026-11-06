import Foundation
import MGDomain

/// A double tap stops a buzzing alarm or reminder (D-031, Mo 2026-10-12), wake alarms included. A tap that silences a
/// WAKE alarm does NOT count as awake (D-031 UPDATE 10:05 PM: "i may tap it then lay in bed and not get out of bed").
/// Pure, so the App code only calls it. DECODED, untested on a real strap: event 100's cause byte (see `hapticsEndCause`).
public enum RingStop {
    public enum Decision: Equatable, Sendable {
        /// A tap: silence whatever is ringing.
        case silence
        case ignore
    }

    /// Event 14 (DOUBLE_TAP), or event 100 (haptics ended) whose cause byte is 2 (the buzz ended because of a double tap).
    public static func decision(event: StrapEvent) -> Decision {
        switch event.number {
        case 14: return .silence
        case 100: return hapticsEndCause(payloadHex: event.payloadHex) == 2 ? .silence : .ignore
        default: return .ignore
        }
    }

    /// Event 100's cause byte: payload[1] of [rev, cause] (0 time ran out, 1 error, 2 double-tap). `StrapEvent.payloadHex`
    /// starts at frame[11]: id high byte (1), ts u32 (4), subsec u32 (4), then payload[0] = bytes[9], payload[1] = bytes[10]
    /// (OpenStrap research decode_events.py offsets - the same read `AppModel.hapticsEndWords` always used).
    public static func hapticsEndCause(payloadHex: String) -> UInt8? {
        var bytes: [UInt8] = []
        var i = payloadHex.startIndex
        while let j = payloadHex.index(i, offsetBy: 2, limitedBy: payloadHex.endIndex), i < j {
            if let b = UInt8(payloadHex[i..<j], radix: 16) { bytes.append(b) }
            i = j
        }
        return bytes.count > 10 ? bytes[10] : nil
    }

    /// Records the silence: sets `acknowledgedAt` (RingPolicy then finishes the occurrence as "stopped" - wake alarms
    /// too). Never sets `awakeAt`. `viaDoubleTap`: the event-14 path also keeps the tap in the shown list.
    public static func silence(_ st: inout RingState, at: Date, viaDoubleTap: Bool) {
        if viaDoubleTap { st.doubleTaps.append(at) }
        if st.acknowledgedAt == nil { st.acknowledgedAt = at }
    }

    /// Whether the finish counts as "Mo stopped it" (cancels its iPhone alarm). A timer / plain alarm: a tap or Stop.
    /// A wake alarm: only awake evidence - a tap alone leaves its iPhone alarm in place (the safe failure).
    public static func endedByMo(isWake: Bool, _ st: RingState) -> Bool {
        isWake ? st.awakeAt != nil : (st.awakeAt != nil || st.acknowledgedAt != nil)
    }
}
