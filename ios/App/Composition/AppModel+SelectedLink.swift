import Foundation
import MGBLE

// WHOOP4-WIRE (2026-11-05; Mo: "when I select 4.0 it does all of that"). One place that says which strap link the app's history
// pulls, follow-ups, debug channel and log lines talk to: the WHOOP 4.0 link when "WHOOP 4.0" is the chosen device, the 5/MG link
// otherwise. The two links never run together (`StrapLinkConfig.connectGate`, AppModel+Whoop4), so exactly one of them is live.
// WRITTEN, NOT COMPILED here (the app target is built with xtool).

/// What the keep-up, the wake chain and the debug `pull_history` need from a link. `StrapLink` and `Whoop4Link` both have it.
@MainActor
protocol HistoryPulling: AnyObject {
    var state: StrapLinkState { get }
    func downloadHistory() async throws -> HistorySummary
    /// Stops a history run (ABORT_HISTORICAL_TRANSMITS; nothing is trimmed). Both links already have it.
    func abortHistory()
}

/// The alarm engine and the timers also write alarms and buzzes (`StrapAlarmLinking`); WHOOP4-WIRE 5 gives the 4.0 link that surface.
@MainActor
protocol AlarmLink: StrapAlarmLinking, HistoryPulling {}

extension StrapLink: HistoryPulling {}
extension Whoop4Link: HistoryPulling {}
extension StrapLink: AlarmLink {}
extension Whoop4Link: AlarmLink {}

extension AppModel {
    /// The selected device's link, nil while it is not started.
    var selectedHistoryLink: (any HistoryPulling)? {
        StrapDeviceChoice.stored == .whoop4 ? services.whoop4.link : services.strap.link
    }

    /// The selected strap's battery, for the keep-up's "strap battery low" rule.
    var selectedStrapBatteryPercent: Double? {
        StrapDeviceChoice.stored == .whoop4 ? services.whoop4.status.batteryPercent : strapInfo?.batteryPercent
    }

    /// A line for the selected device's diagnostics log (`strap-log.txt` for the 5/MG, `whoop4-log.txt` for the 4.0).
    func noteSelectedStrap(_ line: String) {
        if StrapDeviceChoice.stored == .whoop4 { services.whoop4.noteExternal(line) } else { services.strap.noteExternal(line) }
    }
}
