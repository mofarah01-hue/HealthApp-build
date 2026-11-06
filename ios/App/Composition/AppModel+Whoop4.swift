import Foundation
import MGBLE
import MGContext
import MGDomain

// WHOOP4-LINK (2026-11-05; D-WHOOP4-LINK-1) — Settings › Strap & sync › Device. "WHOOP 4.0" vs "MG / none" (what the app did
// before), saved in UserDefaults (`StrapDeviceChoice`, read at launch before any link starts). With "WHOOP 4.0" selected the
// 5/MG link is disconnected and refuses to scan or connect (`StrapLinkConfig.connectGate`); the 4.0 link starts instead.
// WRITTEN, NOT COMPILED here (the app target is built with xtool).
extension AppModel {
    func chooseStrapDevice(_ choice: StrapDeviceChoice) async {
        guard choice != StrapDeviceChoice.stored else { return }
        guard !isSample else { return showNotice("Sample data is on - no strap is asked.") }
        if choice == .whoop4 {
            await services.strap.disconnectAndWait()   // the 5/MG link: raw streams off and disconnected BEFORE the 4.0 starts
        }
        services.whoop4.select(choice)                 // saves the choice: the 5/MG gate reads it from here on
        switch choice {
        case .whoop4:
            if Whoop4Coordinator.wasPaired { startStrapLink() }
            showNotice(StrapNotices.selected(whoop4: true))
        case .mgOrNone:
            startStrapLink()                           // the 5/MG link as before (the hand-back switch still applies)
            showNotice(StrapNotices.selected(whoop4: false))
        }
        await refresh()
    }

    /// 0.6.0.11 "Stop buzzing": STOP_HAPTICS + DISABLE_ALARM on the 4.0 (Whoop4Coordinator.stopBuzzing).
    func stopWhoop4Buzzing() async {
        showNotice(await services.whoop4.stopBuzzing())
    }

    /// "Pair WHOOP 4.0" (and the main Pair button while "WHOOP 4.0" is selected): scan for the 4.0 service only, bond with the
    /// first confirmed write, set the strap's clock (this tap is the standing consent), read its history.
    func pairWhoop4() {
        guard StrapDeviceChoice.stored == .whoop4 else { return showNotice("Choose WHOOP 4.0 under Device first.") }
        guard let salt = installSalt else { return showNotice("The strap can't start yet: the install salt isn't read.") }
        services.whoop4.hrBroadcastWanted = isSample ? nil : settings.hrBroadcastOn
        services.whoop4.pair(installSalt: salt)
        showNotice("Looking for your WHOOP 4.0. Keep it close, close the WHOOP app, and tap the strap until the blue light shows.")
    }
}
