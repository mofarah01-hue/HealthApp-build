import SwiftUI
import MGContext
import MGDesign
import MGDomain

// Strap write log (UX-SPEC §14, PLAN rule 5 / ARCHITECTURE §4.4.5): every write the app sent to the strap, newest
// first, with the prior value, the payload and the read-back, so a change can be checked and undone by hand.
// Entries are `StrapWriteEntry` (MGDomain), read from the store by the app and passed in. Owner: WP-13.
//
// Content only (no scroll view): it sits inside the Strap & sync sheet's MGScreen as its second page.

struct StrapWriteLogView: View {
    let entries: [StrapWriteEntry]
    let back: () -> Void
    @Environment(\.mgColors) private var colors

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if entries.isEmpty {
                MGCard {
                    Text("Nothing has been written to the strap yet. The clock set on connect (once you allow it) "
                         + "and every unlock flag will appear here, with the value before and the read-back after.")
                        .mgFont(.body)
                        .foregroundStyle(colors.ink2.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 14)
            } else {
                MGCard(padding: 0) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(newestFirst.enumerated()), id: \.offset) { index, entry in
                            StrapWriteLogRow(entry: entry)
                            if index < newestFirst.count - 1 { StrapRule() }
                        }
                    }
                }
                .padding(.top, 14)
            }
        }
    }

    private var newestFirst: [StrapWriteEntry] {
        entries.sorted { $0.confirmedAt > $1.confirmedAt }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center) {
                Button(action: back) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left").font(.system(size: 13, weight: .semibold))
                        Text("Strap & sync")
                    }
                    .mgFont(.button)
                    .foregroundStyle(colors.ink.color)
                    .frame(minHeight: MGSpace.tapTarget)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Back to Strap and sync")
                Spacer(minLength: 0)
            }
            Text("Strap write log")
                .mgFont(.title)
                .foregroundStyle(colors.ink.color)
                .accessibilityAddTraits(.isHeader)
            Text("\(entries.count) \(entries.count == 1 ? "write" : "writes") · all sent with response, newest first")
                .mgFont(.receipt)
                .foregroundStyle(colors.mute.color)
        }
    }
}

/// One write: what it was, when, the value before, the read-back after, the result, the payload bytes.
struct StrapWriteLogRow: View {
    let entry: StrapWriteEntry
    @Environment(\.mgColors) private var colors
    @Environment(\.calendar) private var calendar

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title)
                    .mgFont(.rowTitle)
                    .foregroundStyle(colors.ink.color)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Text(whenText)
                    .mgFont(.receipt)
                    .foregroundStyle(colors.mute.color)
            }
            Text("before \(entry.priorValue ?? "not read") → read-back \(entry.readback ?? "not read")")
                .mgFont(.detail)
                .foregroundStyle(colors.ink2.color)
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if !resultIsOK {
                    // Words and a glyph, not colour alone.
                    Image(systemName: "exclamationmark.triangle")
                        .imageScale(.small)
                        .foregroundStyle(colors.text(.body).color)
                        .accessibilityHidden(true)
                }
                Text("result: \(entry.result)")
                    .mgFont(.detail)
                    .foregroundStyle(resultIsOK ? colors.ink2.color : colors.text(.body).color)
                    .fixedSize(horizontal: false, vertical: true)
                if entry.standingConsent {
                    Text("standing consent")
                        .mgFont(.receipt)
                        .foregroundStyle(colors.ink2.color)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .overlay(Capsule().strokeBorder(colors.rule.color, lineWidth: 1))
                }
            }
            Text(entry.payloadHex.isEmpty ? "payload: (empty)" : "payload \(entry.payloadHex)")
                .mgFont(.receipt)
                .foregroundStyle(colors.mute.color)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    /// "SET_FF_VALUE · command 120", or "command 146" when the entry has no name.
    private var title: String {
        entry.name.isEmpty ? "command \(entry.command)" : "\(entry.name) · command \(entry.command)"
    }

    private var resultIsOK: Bool {
        entry.result.trimmingCharacters(in: .whitespaces).lowercased() == "ok"
    }

    /// "Sun 11 Oct 09:40" in the phone's calendar, 24 h.
    private var whenText: String {
        "\(MGFormat.shortDate(entry.confirmedAt, calendar: calendar)) \(MGFormat.time(entry.confirmedAt, calendar: calendar))"
    }
}
