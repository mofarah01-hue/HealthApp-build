import Foundation
import WhoopProtocol

/// HR broadcast on the WHOOP 4.0 (WHOOP4-WIRE 4, Mo 2026-11-05: the HR broadcast switch does the same on the 4.0): the strap's
/// standard 0x180D heart-rate profile, which a Wahoo/Garmin head unit or gym kit can pair with.
///
/// ONE write, WITH RESPONSE: command 14 TOGGLE_GENERIC_HR_PROFILE, payload one byte `01` on / `00` off. Sources: docs/research/
/// WHOOP4-INVENTORY-2026-11-05.md §5 and §7 (command 14, "Known; works with Wahoo head units"), ryanbr/noop docs/PROTOCOL_COMMANDS.md
/// ("Generic HR profile: one byte 0/1; others fail ... updates a nonvolatile policy"; command 14 is supported on both families).
/// The 5/MG's second write (119 `whoop_live_hr_in_adv_ind_pkt`, read back with 121) has no known 4.0 equivalent, so it is not sent.
/// The read-back is the strap's own event, 24 BLE HR profile enabled / 25 disabled (inventory §6 event table); until one arrives the
/// status says what the command answered. DECODED, untested on Mo's strap.
extension Whoop4Link {
    /// The Settings switch. Stores it, and when connected writes it now (14) and reports what the strap answered.
    public func setHRBroadcast(_ on: Bool) async {
        hrBroadcastWanted = on
        if handshakeDone { try? await deferWhileDownloading("the HR broadcast change") }   // queued behind a running download
        await applyHRBroadcast()
    }

    /// Called once per connection after the handshake when the switch is on (the profile is a nonvolatile policy, but a strap that
    /// restarted must be told again at no cost) and by `setHRBroadcast`. Does nothing before the switch was ever set or while not
    /// connected.
    func applyHRBroadcast() async {
        guard handshakeDone, let on = hrBroadcastWanted else { return }
        do {
            let r = try await channel.send(.test(opcode: Whoop4Command.toggleGenericHRProfile, payload: [on ? 0x01 : 0x00]),
                                           awaitResponse: true)
            let word = r?.result.label ?? "no response"
            logLine("whoop4: HR broadcast \(on ? "on" : "off"): 14 → \(word)")
            if r?.result == .success {
                // Event 24 / 25 follows from the strap and is the confirmation; until then this is what was asked.
                if status.hrBroadcast == nil || status.hrBroadcast != (on ? "on" : "off") {
                    status.hrBroadcast = on ? "on (asked, strap answered ok)" : "off (asked, strap answered ok)"
                }
            } else {
                status.hrBroadcast = "not set: strap answered \(word)"
            }
        } catch {
            logLine("whoop4: HR broadcast \(on ? "on" : "off") failed — \(describeError(error))")
            status.hrBroadcast = "not set: \(describeError(error))"
        }
    }
}
