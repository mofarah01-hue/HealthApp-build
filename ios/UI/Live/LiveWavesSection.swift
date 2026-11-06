import SwiftUI
import MGContext
import MGDesign

// Round 8 (r8j): the Live tab's wave rows in ONE "Waves" disclosure, collapsed by default (UI-SCRUB-B L13), so a collapsed chart
// is not drawn at all (less heat) and "Start something" is not six screens down. Inside: the one Raw PPG card (L1; the cleaned
// trace is a line in it, and the pulse-rate lines that used to sit under a second "Pulse wave" copy of the same signal), then the
// motion and ECG rows as before. The picker choice and the open/closed state live HERE, in `@State` of a view that is always at
// the same place in `LiveView`'s body, so they survive the Live tab switching between its blank and normal blocks (L11).
// Equatable on its sub-states only (audit 7.3): a heart-rate change does not re-run this body. NOT COMPILED here (no Xcode).

struct LiveWavesSection: View, Equatable {
    let part: LiveWavesSubState
    /// Only its note lines are used (shown in the PPG card while the standalone Pulse wave box is hidden).
    let pulse: LivePulseSubState
    let send: (UIIntent) -> Void
    @Environment(\.mgColors) private var colors
    @State private var open = false
    @State private var selection = LivePPGSelection(mode: .greenOnly)      // T127; T10005: green only first - ten plots at once ran the phone hot

    static func == (a: LiveWavesSection, b: LiveWavesSection) -> Bool { a.part == b.part && a.pulse == b.pulse }

    private var onCount: Int { part.rows.filter { $0.toggle.isOn }.count }

    var body: some View {
        if !part.rows.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Button { open.toggle() } label: {
                    HStack(spacing: MGSpace.s) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Waves")
                                .mgFont(.rowTitle)
                                .foregroundStyle(colors.ink.color)
                            Text("Raw PPG, 100 Hz motion, ECG · \(onCount) of \(part.rows.count) on")
                                .mgFont(.detail)
                                .foregroundStyle(colors.ink2.color)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: MGSpace.s)
                        Image(systemName: open ? "chevron.up" : "chevron.down")
                            .foregroundStyle(colors.ink2.color)
                            .accessibilityHidden(true)
                    }
                    .frame(minHeight: MGSpace.tapTarget)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Waves")
                .accessibilityValue(open ? "expanded" : "collapsed")
                .accessibilityHint("Shows or hides the raw PPG, motion and ECG graphs")
                .padding(.top, MGSpace.section)

                if open {
                    ForEach(part.rows) { row in
                        if row.id == "ppg" {
                            LivePPGCard(row: row, pulse: pulse, selection: $selection, send: send)
                        } else {
                            LiveWaveRowView(row: row, send: send)
                        }
                    }
                }
            }
        }
    }
}

/// The one raw PPG card: switch, notes, picker, the smooth plots (with the cleaned line), and the pulse-rate lines.
struct LivePPGCard: View {
    let row: LiveWaveRow
    let pulse: LivePulseSubState
    @Binding var selection: LivePPGSelection
    let send: (UIIntent) -> Void
    @Environment(\.mgColors) private var colors

    private let plotHeight: Double = 160

    var body: some View {
        MGCard {
            VStack(alignment: .leading, spacing: 0) {
                Toggle(isOn: Binding(get: { row.toggle.isOn }, set: { _ in send(row.toggle.intent) })) {
                    Text(row.title)
                        .mgFont(.rowTitle)
                        .foregroundStyle(colors.ink.color)
                }
                .tint(colors.focus.color)
                .disabled(!row.toggle.enabled)
                .frame(minHeight: MGSpace.tapTarget)
                LiveStrapSyncLink(what: "Raw optical", send: send)

                Text(row.note)
                    .mgFont(.detail)
                    .foregroundStyle(colors.ink2.color)
                    .fixedSize(horizontal: false, vertical: true)
                FlowLayout(spacing: MGSpace.s, lineSpacing: MGSpace.xs) {
                    if row.note.localizedCaseInsensitiveContains("raw counts") {
                        TagPill(text: "raw counts, no unit")
                    }
                    if row.note.localizedCaseInsensitiveContains("decoded, untested") {
                        TagPill(text: "decoded, untested")
                    }
                }
                .padding(.top, MGSpace.s)

                if !row.waves.isEmpty, row.reason == nil, !row.waves.contains(where: { $0.id == LiveWaves.whoop4OpticalID }) {
                    Picker("Raw PPG traces", selection: $selection.mode) {
                        ForEach(LivePPGSelection.Mode.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .tint(colors.focus.color)
                    .frame(minHeight: MGSpace.tapTarget)
                    .padding(.top, MGSpace.s)
                    Text(LivePPGSelection.mapNote)
                        .mgFont(.detail)
                        .foregroundStyle(colors.ink2.color)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let reason = row.reason {
                    Text(reason)
                        .mgFont(.body)
                        .foregroundStyle(colors.ink2.color)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, MGSpace.m)
                } else {
                    // The graphs come from the live buffer at a steady capped rate; the row's own waves are only ids and
                    // labels (plus fallback samples until the buffer holds the wave).
                    LiveSmoothPPGPlots(graphs: selection.graphs(row.waves), height: plotHeight)
                    if pulse.hidden { LivePulseNoteLines(pulse: pulse) }
                }
            }
        }
        .padding(.top, MGSpace.section)
    }
}

/// The pulse-rate line and the cleaned-trace quality lines (research, decoded, untested) that belonged under the Pulse wave box.
struct LivePulseNoteLines: View {
    let pulse: LivePulseSubState
    @Environment(\.mgColors) private var colors

    var body: some View {
        VStack(alignment: .leading, spacing: MGSpace.xs) {
            if let note = pulse.note { line(note) }
            if let chip = pulse.cleanChip { line("Cleaned (ALG-144, decoded, untested): " + chip.text) }
            if let note = pulse.cleanNote { line(note) }
        }
        .padding(.top, MGSpace.s)
    }

    private func line(_ text: String) -> some View {
        Text(text)
            .mgFont(.body)
            .foregroundStyle(colors.ink2.color)
            .fixedSize(horizontal: false, vertical: true)
    }
}
