import SwiftUI
import MGContext
import MGDesign
import MGDomain

// Settings › Tests (T162, 2026-10-12). One-tap checks that leave a saved record, so Mo can see that the parts work:
// the SpO₂ spot reading (the existing 60 s raw-optical estimate; `measureSpO2Now` saves the metric), and the alarm test
// (strap buzz + phone alert; added with the alarm test intent). Pure rendering; the only output is intents.

struct SettingsTestsSection: View {
    let state: TestRunsState
    let send: (UIIntent) -> Void

    init(state: TestRunsState, send: @escaping (UIIntent) -> Void) {
        self.state = state
        self.send = send
    }
    /// R8p (S10): when Measure was tapped. The test takes about a minute; R9f added Cancel (`.cancelSpO2Now`). This shows that
    /// it is running and stops a second tap from starting another. It clears itself after the minute, on Cancel, or when a
    /// new test row arrives (a refusal is a row at once: raw optical off, sample data, already running).
    @State private var measuringSince: Date?
    private static let measureSeconds: TimeInterval = 62

    var body: some View {
        SettingsSection("Tests", note: "each run is saved") {
            SettingsRow("Alarm test", detail: "Buzzes the strap once with 4 pulses and sends an immediate iPhone alert.") {
                MGButton("Run", style: .ghost) { send(.alarms(.testAlarm)) }
            }
            SettingsRow("SpO₂ test", detail: "Hold still for about a minute. Uses the raw optical stream (strap battery). "
                        + "The result is an estimate — not checked against WHOOP — and is saved with your metrics.") {
                if let since = measuringSince {
                    HStack(spacing: MGSpace.s) {
                        TimelineView(.periodic(from: since, by: 1)) { context in
                            let elapsed = max(0, Int(context.date.timeIntervalSince(since)))
                            SettingsValueText("Measuring… \(elapsed / 60):\(String(format: "%02d", elapsed % 60))")
                        }
                        MGButton("Cancel", style: .ghost) {       // R9f: stops the hold on raw optical; a "cancelled" row follows
                            send(.cancelSpO2Now)
                            measuringSince = nil
                        }
                    }
                } else {
                    MGButton("Measure", style: .ghost) {
                        measuringSince = Date()
                        send(.measureSpO2Now)
                    }
                }
            }
            .task(id: measuringSince) {
                guard measuringSince != nil else { return }
                try? await Task.sleep(for: .seconds(Self.measureSeconds))
                if !Task.isCancelled { measuringSince = nil }
            }
            .onChange(of: state.rows.first?.id) { _, _ in
                measuringSince = nil
            }
            if state.rows.isEmpty {
                LogHint("No test runs yet.").padding(.vertical, 6)
            }
            ForEach(state.rows) { row in
                SettingsRow(row.text) { SettingsTag(row.ok ? "ok" : "problem") }
            }
        }
    }
}
