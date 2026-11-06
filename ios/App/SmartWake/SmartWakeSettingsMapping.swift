import Foundation
import MGContext
import MGSignal

// T9841 (R-097, e-17) - the smart-wake setting (mode, time gate, minimum rest share) as the plan's options.

extension AppModel {
    /// The options ALG-035's plan takes for the morning ending at `wakeAt` (the "must be up by" instant). The gate is a
    /// clock time on that morning's date; a time-gate mode with no gate set runs as "open" (documented in the plan).
    func smartWakeOptions(forWakeAt wakeAt: Date?) -> SmartWakeOptions {
        let mode = SmartWakeOptions.Mode(rawValue: settings.smartWakeMode) ?? .window
        var gate: Int64?
        if mode == .timeGate, let wakeAt, let m = settings.smartWakeGateMinutes, (0..<1440).contains(m),
           let day = calendar.date(bySettingHour: m / 60, minute: m % 60, second: 0, of: wakeAt) {
            gate = AppModel.unix(day)
        }
        return SmartWakeOptions(mode: mode, gateAt: gate, minRestFraction: Double(settings.smartWakeRestPercent) / 100.0)
    }
}
