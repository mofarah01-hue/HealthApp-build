import SwiftUI
import MGContext
import MGDesign
import MGDomain

// Settings › Profile, tracker #42 (2026-10-11): body composition (InBody / DEXA / tape, typed numbers) and injuries
// (body part, dates, status), newest first. Both are Log records — added in Log › More, listed here; nothing is copied.

struct SettingsProfileRecordsSection: View {
    let bodyComposition: [LabeledValue]
    let injuries: [LabeledValue]

    init(bodyComposition: [LabeledValue], injuries: [LabeledValue]) {
        self.bodyComposition = bodyComposition
        self.injuries = injuries
    }

    var body: some View {
        SettingsSection("Body composition", note: "InBody · DEXA · tape") {
            if bodyComposition.isEmpty {
                SettingsRow("None yet", detail: "Add one in Log › More › Scan: InBody, DEXA, or Other for a tape / scale "
                                                + "reading (weight, body fat, lean mass, waist …).") { EmptyView() }
            }
            ForEach(bodyComposition) { row in
                SettingsRow(row.label, detail: row.caption) {
                    ValueView(row.value, size: .small)
                }
            }
        }
        SettingsSection("Injuries", note: "body part · dates · status") {
            if injuries.isEmpty {
                SettingsRow("None logged", detail: "Add one in Log › More › Health record, kind injury.") { EmptyView() }
            }
            ForEach(injuries) { row in
                SettingsRow(row.label, detail: row.caption) {
                    ValueView(row.value, size: .small)
                }
            }
        }
    }
}
