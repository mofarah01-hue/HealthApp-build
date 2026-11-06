import Foundation
import WhoopProtocol

/// HR broadcast to gym kit and other apps (T77, Mo 2026-10-13): the strap advertises its heart rate as a standard 0x180D
/// sensor. Two writes, both WITH RESPONSE: 14 TOGGLE_GENERIC_HR_PROFILE [on], then 119 SET_DEVICE_CONFIG_VALUE for
/// `whoop_live_hr_in_adv_ind_pkt` ('1' / '0'; body `Whoop5Config.deviceConfigBody`), then the value is read back with 121.
/// Sources: noop CHANGELOG 2.6.5 (opt-in, reversible, re-applied on each connection), noop `Whoop5Config.setDeviceConfigCmd`
/// (hardware-validated on a Garmin Edge 840, noop #181), `whoop_protocol.json` command 14. noop's sources differ on whether
/// the strap keeps the key after a disconnect, so the read-back is what the app shows. DECODED, not yet seen from Mo's strap.
extension StrapLink {
    /// The Settings switch. Stores it, and when connected writes it now (14, 119) and reads the strap's value back.
    public func setHRBroadcast(_ on: Bool) async {
        hrBroadcastWanted = on
        hrBroadcastUnsent = true
        await applyHRBroadcast(writing: true)
    }

    /// Called at the handshake (writing only when the switch is on) and by `setHRBroadcast`. Does nothing before the
    /// switch was ever set, or while not connected.
    func applyHRBroadcast(writing: Bool) async {
        guard handshakeDone, let on = hrBroadcastWanted else { return }
        let key = DeviceConfigWriteGate.broadcastHrKey
        if writing {
            hrBroadcastUnsent = false
            do {
                let toggle = try await channel.send(.gated(.toggleGenericHRProfile(on: on)), awaitResponse: true)
                let write = try await channel.send(.gated(.setDeviceConfigValue(key: key, value: on ? 0x31 : 0x30)),
                                                   awaitResponse: true)
                logLine("HR broadcast \(on ? "on" : "off"): 14 → \(toggle?.result.label ?? "no response"); "
                        + "119 → \(write?.result.label ?? "no response")")
            } catch {
                logLine("HR broadcast \(on ? "on" : "off") failed — \(describeError(error))")
            }
        }
        let reading = FeatureFlagValueReply.reading(
            key: key, response: try? await channel.send(.sanctioned(.getDeviceConfigValue(key: key)), awaitResponse: true),
            command: 121)
        switch reading.value ?? "" {
        case "1": hrBroadcastReading = "on"
        case "0": hrBroadcastReading = "off"
        default: hrBroadcastReading = "unknown (\(reading.value.map { "value '\($0)'" } ?? reading.status))"
        }
    }
}
