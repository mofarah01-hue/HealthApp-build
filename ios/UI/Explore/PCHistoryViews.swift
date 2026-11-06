import SwiftUI
import MGContext
import MGDesign
import MGDomain

// Older periods from the PC (tracker #7, 2026-10-11): the sentence under the period picker and the group's older-years
// rows. Views only draw what the presenters worded (MGContext PCHistoryText).

/// "Before 12 Oct 2025: 1,204 days from the PC (WHOOP export 900, …)" or "… isn't reachable … from the phone only."
struct PCHistoryNoteView: View {
    @Environment(\.mgColors) private var colors
    private let text: String
    /// false = the PC part is missing: drawn as a warning so it never reads as "no data".
    private let shown: Bool

    init(_ text: String, shown: Bool) {
        self.text = text
        self.shown = shown
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: shown ? "desktopcomputer" : "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(shown ? colors.ink2.color : colors.caffeineText.color)
                .accessibilityHidden(true)
            Text(text)
                .mgFont(.detail)
                .foregroundStyle(colors.ink2.color)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }
}

/// Group: one row per (metric, variant) of the older years, labelled with algorithm and source, "from the PC".
struct GroupPCHistoryBlock: View {
    @Environment(\.mgColors) private var colors
    private let note: String?
    private let rows: [LabeledValue]
    private let period: ExplorePeriod
    private let send: (UIIntent) -> Void

    init(note: String?, rows: [LabeledValue], period: ExplorePeriod, send: @escaping (UIIntent) -> Void) {
        self.note = note
        self.rows = rows
        self.period = period
        self.send = send
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader("Older years", note: "from the PC, not kept on the phone")
            ExplorePeriodPicker(selected: period, send: send)
                .padding(.top, 6)
            if let note {
                PCHistoryNoteView(note, shown: !rows.isEmpty)
            } else {
                Text("Pick 2 y, 5 y or All to see the years the PC holds.")
                    .mgFont(.detail)
                    .foregroundStyle(colors.ink2.color)
                    .padding(.vertical, 8)
            }
            ForEach(rows) { row in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.label)
                            .mgFont(.rowTitle)
                            .fontWeight(.medium)
                            .foregroundStyle(colors.ink.color)
                            .fixedSize(horizontal: false, vertical: true)
                        if let caption = row.caption {
                            Text(caption)
                                .mgFont(.detail)
                                .foregroundStyle(colors.mute.color)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 8)
                    ValueView(row.value, size: .small)
                }
                .padding(.vertical, 8)
                .frame(minHeight: 52)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(colors.rule.color).frame(height: 1).accessibilityHidden(true)
                }
            }
        }
    }
}
