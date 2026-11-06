import SwiftUI
import UIKit

/// T141 (2026-10-13): the "Open Settings" ghost button, lifted out of the pairing sheet's camera-denied case
/// (`PairingSheet.openSettings`) so Today and Live can show the same button for Bluetooth off / not allowed —
/// the only two causes an iOS Settings toggle actually fixes.
public struct OpenSettingsButton: View {
    public init() {}

    public var body: some View {
        MGButton("Open Settings", style: .ghost) { OpenSettingsButton.open() }
    }

    public static func open() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }
}
