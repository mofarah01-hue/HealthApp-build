import SwiftUI
import MGContext
import MGDesign
import MGDomain

// Settings › Working on (T149, 2026-10-12). Every running or waiting job: what it is, where it is going, how far along,
// and why it waits. Mo keeps the moving bars off the top of the screens (the switch above); this is where they live.
// Pure rendering of `WorkingDetailState`; the only intent is opening Strap & sync.

struct SettingsWorkingSection: View {
    let detail: WorkingDetailState
    let barsHidden: Bool
    let send: (UIIntent) -> Void

    init(detail: WorkingDetailState, barsHidden: Bool, send: @escaping (UIIntent) -> Void) {
        self.detail = detail
        self.barsHidden = barsHidden
        self.send = send
    }

    var body: some View {
        SettingsSection("Working on", note: barsHidden ? "bars hidden at the top" : "also shown at the top") {
            if detail.isEmpty {
                SettingsRow(detail.idleLine) { EmptyView() }
            } else {
                ForEach(detail.jobs) { job in
                    SettingsWorkingRow(job: job, send: send)
                }
            }
        }
    }
}

struct SettingsWorkingRow: View {
    let job: WorkingJob
    let send: (UIIntent) -> Void
    @Environment(\.mgColors) private var colors

    init(job: WorkingJob, send: @escaping (UIIntent) -> Void) {
        self.job = job
        self.send = send
    }

    /// "This phone → PC · 120 of 366 · since 9:24 AM".
    private var progressText: String {
        var line = job.destination + " · " + job.progress
        if let since = job.since { line += " · " + since }
        return line
    }

    private var row: some View {
        HStack(alignment: .center, spacing: MGSpace.s) {
            VStack(alignment: .leading, spacing: 6) {
                Text(job.title)
                    .mgFont(.wordValue)
                    .foregroundStyle(colors.ink.color)
                Text(progressText)
                    .mgFont(.wordValue)
                    .foregroundStyle(colors.ink2.color)
                    .fixedSize(horizontal: false, vertical: true)
                progressBar
                if let why = job.waitingBecause {
                    Text("Waiting: " + why)
                        .mgFont(.wordValue)
                        .foregroundStyle(colors.ink2.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if job.opensStrapSync {
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(colors.ink2.color)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 10)
        .frame(minHeight: 52)
        .contentShape(Rectangle())
        .overlay(alignment: .bottom) { Rectangle().fill(colors.rule.color).frame(height: 1) }
    }

    private var progressBar: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(colors.trackPale.color)
                if let fraction = job.fraction {
                    Capsule()
                        .fill(colors.focus.color)
                        .frame(width: geometry.size.width * min(max(fraction, 0), 1))
                }
            }
        }
        .frame(height: 3)
        .accessibilityElement()
        .accessibilityLabel(job.fraction.map { "\(Int(($0 * 100).rounded())) percent" } ?? "Progress unavailable")
    }

    var body: some View {
        if job.opensStrapSync {
            Button(action: { send(.openStrapSync) }) { row }
                .buttonStyle(.plain)
        } else {
            row
        }
    }
}
