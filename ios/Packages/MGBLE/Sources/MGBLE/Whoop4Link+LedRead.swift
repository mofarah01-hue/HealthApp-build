import Foundation
import WhoopProtocol

extension Whoop4Link {
    /// Read-only: GET_LED_DRIVE (40), GET_TIA_GAIN (42), GET_BIAS_OFFSET (44), body `00`, once each, WITH RESPONSE, in that order. No
    /// retry with another body, no SET (39, 41, 43), nothing else is sent. Each reply is returned as raw hex with the time and the
    /// wear state; a refused or unanswered read ("no reply", "failed") is returned with its reason, never swallowed. Throws nothing: an unconnected link
    /// returns three "failed" reads so the caller logs that nothing could be read.
    public func readLedSettings() async -> [Whoop4LedRead] {
        var out: [Whoop4LedRead] = []
        for command in Whoop4LedRead.commands {
            let at = clock.now
            let worn = status.worn
            do {
                let r = try await sendTestCommand(opcode: command, payload: Whoop4LedRead.body)
                out.append(Whoop4LedRead(at: at, command: command, worn: worn, result: r?.result.label ?? "no reply",
                                         replyHex: r.map { $0.frame.hexLower } ?? "",
                                         error: r == nil ? "the strap did not answer in time" : nil))
            } catch {
                out.append(Whoop4LedRead(at: at, command: command, worn: worn, result: "failed", replyHex: "",
                                         error: "\(error)".replacingOccurrences(of: "\n", with: " ")))
            }
        }
        logLine("whoop4: LED settings read: " + out.map { "\($0.command) \($0.result)" }.joined(separator: ", "))
        return out
    }
}
