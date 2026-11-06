import DeviceActivity
import MGDesign
import SwiftUI

// Screen Time: the DeviceActivityReport extension (Mac build, Nov 2026), an ExtensionKit extension (point
// com.apple.deviceactivityui.report-extension). The app embeds `DeviceActivityReport(context, filter:)` and iOS draws these
// views inside it. Apple's sandbox keeps the numbers here: the app and the PC never receive them, so every card says where the
// numbers come from. Looks like the rest of the app: MGDesign's card, fonts and theme (cream by day, emerald in dark mode).
// WRITTEN, NOT COMPILED: first runner build.

@main
struct ActivityReportExtension: DeviceActivityReportExtension {
    var body: some DeviceActivityReportScene {
        TotalsScene { TotalsCard(summary: $0) }
        EveningScene { EveningCard(summary: $0) }
    }
}

struct UsageSummary {
    struct AppRow: Identifiable {
        let id: String
        let name: String
        let seconds: TimeInterval
        let pickups: Int
    }
    var totalSeconds: TimeInterval = 0
    var pickups = 0
    var notifications = 0
    var apps: [AppRow] = []
}

/// "1 h 12 min", "8 min", "under 1 min". Never 24-hour times: this shows durations only.
func durationText(_ seconds: TimeInterval) -> String {
    let m = Int((seconds / 60).rounded())
    if seconds > 0 && m == 0 { return "under 1 min" }
    if m < 60 { return "\(m) min" }
    return "\(m / 60) h \(m % 60) min"
}

private func summarize(_ data: DeviceActivityResults<DeviceActivityData>) async -> UsageSummary {
    var s = UsageSummary()
    var byApp: [String: (name: String, seconds: TimeInterval, pickups: Int)] = [:]
    for await d in data {
        for await segment in d.activitySegments {
            s.totalSeconds += segment.totalActivityDuration
            for await category in segment.categories {
                for await app in category.applications {
                    let name = app.application.localizedDisplayName ?? app.application.bundleIdentifier ?? "App"
                    let key = app.application.bundleIdentifier ?? name
                    var row = byApp[key] ?? (name, 0, 0)
                    row.seconds += app.totalActivityDuration
                    row.pickups += app.numberOfPickups
                    byApp[key] = row
                    s.pickups += app.numberOfPickups
                    s.notifications += app.numberOfNotifications
                }
            }
        }
    }
    s.apps = byApp.map { UsageSummary.AppRow(id: $0.key, name: $0.value.name, seconds: $0.value.seconds, pickups: $0.value.pickups) }
        .sorted { $0.seconds > $1.seconds }
    return s
}

struct TotalsScene: DeviceActivityReportScene {
    let context = DeviceActivityReport.Context("totals")
    let content: (UsageSummary) -> TotalsCard

    func makeConfiguration(representing data: DeviceActivityResults<DeviceActivityData>) async -> UsageSummary {
        await summarize(data)
    }
}

struct EveningScene: DeviceActivityReportScene {
    let context = DeviceActivityReport.Context("evening")
    let content: (UsageSummary) -> EveningCard

    func makeConfiguration(representing data: DeviceActivityResults<DeviceActivityData>) async -> UsageSummary {
        await summarize(data)
    }
}

/// Picks the app's two themes from the system appearance (the extension cannot read the app's Theme setting).
private struct Themed<Content: View>: View {
    @Environment(\.colorScheme) private var scheme
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View { content.mgTheme(scheme == .dark ? .emerald : .cream) }
}

struct TotalsCard: View {
    let summary: UsageSummary

    var body: some View {
        Themed { TotalsBody(summary: summary) }
    }
}

private struct TotalsBody: View {
    let summary: UsageSummary
    @Environment(\.mgColors) private var colors

    var body: some View {
        MGCard {
            VStack(alignment: .leading, spacing: 6) {
                Text("Today, all apps").mgFont(.headline).foregroundStyle(colors.ink.color)
                Text(durationText(summary.totalSeconds)).mgFont(.title).foregroundStyle(colors.ink.color)
                Text("\(summary.pickups) pickups · \(summary.notifications) notifications")
                    .mgFont(.detail).foregroundStyle(colors.ink2.color)
                ForEach(summary.apps.prefix(5)) { app in
                    HStack {
                        Text(app.name).mgFont(.detail).foregroundStyle(colors.ink.color).lineLimit(1)
                        Spacer(minLength: 8)
                        Text(durationText(app.seconds)).mgFont(.detail).foregroundStyle(colors.ink.color)
                    }
                }
                Text("Source: iOS Screen Time, drawn by iOS. HealthApp cannot copy these numbers.")
                    .mgFont(.detail).foregroundStyle(colors.ink2.color).padding(.top, 4)
            }
        }
    }
}

struct EveningCard: View {
    let summary: UsageSummary

    var body: some View {
        Themed { EveningBody(summary: summary) }
    }
}

private struct EveningBody: View {
    let summary: UsageSummary
    @Environment(\.mgColors) private var colors

    var body: some View {
        MGCard {
            VStack(alignment: .leading, spacing: 6) {
                Text("This evening, 9 PM to midnight").mgFont(.headline).foregroundStyle(colors.ink.color)
                Text(durationText(summary.totalSeconds)).mgFont(.title).foregroundStyle(colors.ink.color)
                Text("Source: iOS Screen Time, drawn by iOS.").mgFont(.detail).foregroundStyle(colors.ink2.color)
            }
        }
    }
}
