import Foundation
import MGDomain

// "Hand the strap back to WHOOP" — leave-no-trace mode (wave W12b, tracker #103; Mo 2026-10-11 ~23:30 PT, relayed:
// "leave no trace mode as long as we don't lose any of the data we're collecting at all"). Puts back what HealthApp
// changed on the strap, stops its streams, then disconnects and stays disconnected (the app does not start the link while
// the mode is on). Only CLAUDE.md rule-5 writes, each through its existing guarded path:
//   * enable_r22_packets → the saved prior value (SET_FF_VALUE 120, `restoreUnlock`: prior from the write log, confirm
//     sheet, read back with 128);
//   * the strap alarm slot 1 → DISABLE_ALARM 69 [02 01], only when HealthApp's newest alarm write was an arm (66);
//   * raw optical 108 [01 00], raw motion 82 [01] + 106 [01 00], the ECG stop 124/125/139, realtime 3 [00] / 63 [00] —
//     only what is on.
// Nothing else: no history request (an ack would take records WHOOP has not offloaded yet), no clock write, no data
// deleted anywhere. Bytes already collected stay on the phone and the PC; buffered live records are flushed on the way out.

public struct HandBackReport: Equatable, Sendable {
    public var startedAt: Date
    public var endedAt: Date
    /// What was put back, stopped or left, in words — the Settings summary.
    public var lines: [String]

    public init(startedAt: Date, endedAt: Date, lines: [String]) {
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.lines = lines
    }
}

public enum HandBack {
    /// HealthApp left an alarm armed on the strap: its newest strap-alarm write (66 SET / 69 DISABLE) in the write log
    /// is a SET that went through (or found the same time already set). Entries in any order.
    public static func alarmArmedByApp(_ entries: [StrapWriteEntry]) -> Bool {
        let alarm = entries.filter { $0.command == 66 || $0.command == 69 }.max { $0.confirmedAt < $1.confirmedAt }
        guard let last = alarm, last.command == 66 else { return false }
        return last.result.hasPrefix("ok") || last.result.hasPrefix("already set")
    }
}

extension StrapLink {
    /// Leave-no-trace. Connected: restores and stops what applies, then disconnects without reconnecting. Not connected:
    /// writes nothing, says so, and stays disconnected.
    public func handBackToWhoop(alarmArmedByApp: Bool, consentAt: Date) async -> HandBackReport {
        let started = clock.now
        var lines: [String] = []
        guard handshakeDone else {
            disconnect()
            return HandBackReport(startedAt: started, endedAt: clock.now, lines: [
                "Strap not connected — nothing could be put back. HealthApp stays disconnected; turn the switch off and "
                    + "on again with the strap near to put its values back."])
        }
        // 1. Streams HealthApp started.
        let streams = [rawOpticalLiveOn ? "raw optical (108 off)" : nil,
                       rawMotionLiveOn ? "raw motion (82 + 106 off)" : nil,
                       (ecgReading != nil || ecgNeedsStop) ? "ECG (stop sequence)" : nil].compactMap { $0 }
        if wantRealtimeHR || wantMotion {
            wantRealtimeHR = false
            wantMotion = false
            do {
                try await sendRealtimeToggles()
                lines.append("Live heart rate / motion streams: turned off (3 [00], 63 [00]).")
            } catch {
                lines.append("Live streams: turning off failed — \(describeError(error)).")
            }
        }
        // 2. enable_r22_packets → the value saved before HealthApp's write.
        do {
            let report = try await restoreUnlock()
            let item = report.items.first
            if let item, item.result.hasPrefix("can't restore: no saved prior") {
                lines.append("enable_r22_packets: HealthApp never changed it — nothing to put back.")
            } else if let item, item.result.hasPrefix("already") {
                lines.append("enable_r22_packets: already '\(item.priorValue ?? "?")', the value before HealthApp — "
                             + "nothing written.")
            } else if let item {
                lines.append("enable_r22_packets: \(item.result)" + (item.readback.map { ", reads back '\($0)'" } ?? "")
                             + (report.stoppedEarly ? " (\(report.note ?? "stopped"))" : "") + ".")
            } else {
                lines.append("enable_r22_packets: not put back — \(report.note ?? "nothing written").")
            }
        } catch {
            lines.append("enable_r22_packets: not put back — \(describeError(error)).")
        }
        // 3. The strap alarm HealthApp armed.
        if alarmArmedByApp {
            do {
                let r = try await disableStrapAlarm(consentAt: consentAt)
                lines.append("Strap alarm (slot 1): " + (r.ok ? "cleared (69)." : "not cleared — \(r.result)."))
            } catch {
                lines.append("Strap alarm: not cleared — \(describeError(error)).")
            }
        } else {
            lines.append("Strap alarm: none armed by HealthApp — nothing to clear.")
        }
        // 4. Stop raw optical, raw motion and an ECG reading, flush, disconnect (no reconnect).
        await disconnectStoppingRawOptical()
        lines.append(streams.isEmpty ? "Research streams: none were on." : "Stopped: " + streams.joined(separator: ", ") + ".")
        lines.append("Disconnected; HealthApp won't connect while this is on. The clock HealthApp set stays correct (WHOOP "
                     + "sets it too). Everything already collected stays on the phone and the PC. No history was asked for "
                     + "on the way out, so WHOOP still gets every record left on the strap.")
        for line in lines { logLine("hand back: \(line)") }
        return HandBackReport(startedAt: started, endedAt: clock.now, lines: lines)
    }
}
