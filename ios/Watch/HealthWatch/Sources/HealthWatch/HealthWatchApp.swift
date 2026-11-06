import SwiftUI
import WatchKit

@main
struct HealthWatchApp: App {
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            RecordView()
                .onAppear {
                    PhoneLink.shared.activate()
                    BackgroundAccel.shared.arm()
                    Self.scheduleRefresh()
                }
        }
        .onChange(of: phase) { _, p in
            if p == .active { Task { _ = await BackgroundAccel.shared.fetch() } }
        }
        // Background refresh: fetch CMSensorRecorder data and re-arm it, then ask for the next refresh.
        // watchOS budgets these (roughly a few per hour at best), so the fetch also runs on every open.
        .backgroundTask(.appRefresh("mg.bgaccel")) {
            _ = await BackgroundAccel.shared.fetch()
            await MainActor.run { Self.scheduleRefresh() }
        }
    }

    @MainActor static func scheduleRefresh() {
        WKApplication.shared().scheduleBackgroundRefresh(withPreferredDate: Date().addingTimeInterval(30 * 60),
                                                         userInfo: "mg.bgaccel" as NSString) { _ in }
    }
}

struct RecordView: View {
    @ObservedObject private var rec = Recorder.shared
    @ObservedObject private var bg = BackgroundAccel.shared
    @ObservedObject private var link = PhoneLink.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                Button(rec.running ? "Stop" : "Record") {
                    Task { rec.running ? await rec.stop() : await rec.start() }
                }
                .tint(rec.running ? .red : .green)
                Text(rec.status).font(.footnote)
                if rec.running, let t = rec.startedAt {
                    Text(t, style: .timer).font(.title3.monospacedDigit())
                }
                Text("HR \(rec.bpm.map { String(format: "%.0f", $0) } ?? "–") bpm")
                Text("Accel \(rec.accelCount) @ \(rec.accelHz.map(String.init) ?? "?") Hz").font(.footnote)
                Text("Motion \(rec.motionCount) @ \(rec.motionHz.map(String.init) ?? "?") Hz").font(.footnote)
                Divider()
                Toggle("Background accel", isOn: $bg.enabled)
                Text(bg.status).font(.footnote)
                Button("Fetch now") { Task { _ = await bg.fetch() } }
                Divider()
                Text(link.state).font(.footnote)
                Text("To phone: \(link.pending) pending · \(link.sent) sent").font(.footnote)
                if let e = link.lastError { Text(e).font(.footnote).foregroundStyle(.orange) }
                Button("Send now") { link.sendOutbox() }
                Text(Device.machine + " · " + WKInterfaceDevice.current().systemVersion).font(.footnote).foregroundStyle(.secondary)
            }
        }
    }
}
