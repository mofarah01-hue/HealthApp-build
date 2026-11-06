import SwiftUI
import MGContext
import MGDesign
import MGDomain

// One settings page (Mo, Nov 6 2026: "we have two settings pages ... we need to get this a bit cleaner"). The strap's page
// (Strap & sync) is the Device section of Settings: the same content the sheet drew (`StrapSyncContent`), without its sheet header
// and without PC Lab / Apple Health, which Settings has itself. Nothing was removed: the Streams section is near the top of it, the
// rare research rows are at the bottom of it, and the write log and strap settings list are still one tap away.

/// What the Device section needs from the app.
struct SettingsStrapEmbed {
    let state: StrapSyncState
    let writeLog: [StrapWriteEntry]
    let deviceSection: AnyView?
}

struct SettingsStrapSection: View {
    let embed: SettingsStrapEmbed?
    let send: (UIIntent) -> Void

    @Environment(\.mgColors) private var colors

    var body: some View {
        if let embed {
            StrapSyncContent(state: embed.state, writeLog: embed.writeLog, send: send, close: {}, closeThen: nil,
                             deviceSection: embed.deviceSection, embedded: true)
        } else {
            Text("Reading the strap…").mgFont(.body).foregroundStyle(colors.ink2.color)
                .padding(.vertical, MGSpace.s)
        }
    }
}

/// The Today strap chip asks Settings to scroll to a cluster ("device"); the screen reads it once it is laid out and clears it.
@MainActor
final class SettingsScrollModel: ObservableObject {
    static let shared = SettingsScrollModel()
    @Published var target: String?
}
