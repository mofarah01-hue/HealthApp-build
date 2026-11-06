import Foundation
import MGBLE
import MGContext
import MGDomain

// Settings › Strap & sync › "Hand the strap back to WHOOP" — leave-no-trace mode (wave W12b, tracker #103; Mo 2026-10-11
// ~23:30 PT, relayed: "leave no trace mode as long as we don't lose any of the data we're collecting at all"). On: put
// back what HealthApp changed on the strap (MGBLE `handBackToWhoop`: the saved prior enable_r22_packets value from the
// write log, the alarm HealthApp armed via DISABLE_ALARM 69), stop the raw streams, disconnect and stop connecting. Off:
// connect again and re-apply (the raw switches as they are set, the strap alarm on the next connection, R22 again through
// its confirm sheet when the hand-back had put it back). Nothing collected is deleted, on the phone or the PC.
extension AppModel {
    func setHandBackToWhoop(_ on: Bool) async {
        guard !isSample else { return showNotice("Sample data is on — the strap is not asked.") }
        guard on != settings.handBackToWhoop else { return }
        if on {
            // The values can only be put back over a connection: connect first when needed (up to 30 s).
            if !strapIsReady {
                startStrapLink()
                await waitForStrapReady(seconds: 30)
            }
            settings.handBackToWhoop = true          // from here startStrapLink() does nothing
            await saveState()
            let entries = (try? await services.store.strapWriteEntries(limit: 1000)) ?? []
            let report = await services.strap.handBack(alarmArmedByApp: HandBack.alarmArmedByApp(entries),
                                                       consentAt: alarmsConsentAt)
            if report.lines.contains(where: { $0.hasPrefix("Strap alarm (slot 1): cleared") }) {
                alarmsSlotClearedByHandBack()
            }
            settings.handBackR22Restored = report.lines.contains { $0.hasPrefix("enable_r22_packets: ok") }
            settings.handBackLines = ["Handed back at \(Self.clock12(report.endedAt, calendar))."] + report.lines
            await saveState()
            showNotice("Strap handed back to WHOOP. HealthApp won't connect until you switch this off.")
        } else {
            settings.handBackToWhoop = false
            settings.handBackLines = ["Switched off at \(Self.clock12(clock.now, calendar)) — connecting again; your "
                                      + "switches apply on connection."]
            await saveState()
            startStrapLink()
            applyRawOptical()
            applyRawMotion()
            services.strap.setEcgSwitch(settings.ecgOn)
            if settings.handBackR22Restored {
                await waitForStrapReady(seconds: 60)
                if strapIsReady {
                    switch await services.strap.enableR22() {      // the confirm sheet, as for any R22 write
                    case .success(let r):
                        settings.handBackLines.append("enable_r22_packets: "
                                                      + (r.items.first?.result ?? r.note ?? "nothing written") + ".")
                        if r.items.first?.result == "ok" { settings.handBackR22Restored = false }
                    case .failure(let e):
                        settings.handBackLines.append("enable_r22_packets not re-applied: \(e.text).")
                    }
                    await saveState()
                } else {
                    settings.handBackLines.append("enable_r22_packets not re-applied yet: the strap did not connect.")
                }
            }
            showNotice("HealthApp connects to the strap again.")
        }
        await refresh()
    }

    var strapIsReady: Bool {
        switch strapLinkState {
        case .ready, .downloadingHistory: return true
        default: return false
        }
    }

    func waitForStrapReady(seconds: Double) async {
        var left = Int(seconds * 2)                       // half-second steps; a counter, so a fixed clock can't hang it
        while !strapIsReady, left > 0 {
            left -= 1
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
    }
}
