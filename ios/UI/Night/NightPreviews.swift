#if DEBUG
import SwiftUI
import MGContext
import MGDesign
import MGDomain

// Xcode previews of Night from `NightState.preview` (SAMPLE): as given, with the G-STAGE method switch and the extra
// lanes (strap sleep flag, movement), on Satin Emerald, and the blank "no night recorded" case (UX §13).
// Every value is SAMPLE; the banner shows. Taps print their intent.

private enum NightPreviewData {
    static let receipt = SampleDay.receipt(.phone, .high, 6, 58)

    /// G-STAGE as UX §11's values line ("Ours A 7 h 08 · Deep model 7 h 14 · … · Strap flag 7 h 21"); Script can't run.
    static let stageGroup = MethodsStripState(
        sample: true, groupId: "G-STAGE", title: "Stages · 4 methods",
        members: [
            MethodMember(variant: "ours_a", label: "Ours A", codename: "ALG-031 A",
                         value: SampleDay.value("7 h 08", nil, receipt), bandIndex: nil, isRead: true,
                         isResearch: false, rank: 2),
            MethodMember(variant: "deep", label: "Deep model", codename: "ALG-031 B",
                         value: SampleDay.value("7 h 14", nil, SampleDay.receipt(.pc, .research, 7, 30), .research),
                         bandIndex: nil, isRead: false, isResearch: true, rank: 1),
            MethodMember(variant: "strap_flag", label: "Strap flag", codename: "strap firmware · sleep / wake only",
                         value: SampleDay.value("7 h 21", nil, SampleDay.receipt(.strap, .strap, 6, 52)),
                         bandIndex: nil, isRead: false, isResearch: false, rank: 4),
            MethodMember(variant: "script", label: "Script", codename: "MS-21",
                         value: .blank(reason: "waiting for the PC run", receipt: nil), bandIndex: nil, isRead: false,
                         isResearch: true, rank: 5),
        ],
        caption: "", agreement: nil, droppedCount: 0, valuesLineOnly: true)

    static var withMethodsAndLanes: NightState {
        var s = NightState.preview
        s.stageMethods = stageGroup
        // One stretch without R-R: asleep, stage unknown (drawn hatched on the light row, never as light).
        if s.stages.count > 9 { s.stages[9].stage = .unstaged }
        s.lanes.append(NightLane(id: "movement", title: "Movement", marks: [
            LaneMark(at: SampleDay.at(0, 49)), LaneMark(at: SampleDay.at(3, 37)), LaneMark(at: SampleDay.at(4, 6)),
            LaneMark(at: SampleDay.at(5, 30)), LaneMark(at: SampleDay.at(6, 30)),
        ], blankReason: nil))
        s.lanes.append(NightLane(id: "strapFlag", title: "Strap flag", marks: [
            LaneMark(at: SampleDay.at(23, 5, dayOffset: -1), end: SampleDay.at(3, 35), label: "asleep"),
            LaneMark(at: SampleDay.at(3, 45), end: SampleDay.at(6, 50), label: "asleep"),
        ], blankReason: nil))
        return s
    }

    /// UX §13 "Strap off last night".
    static var blank: NightState {
        let reason = "No night recorded — strap was off 10:10 PM–6:50 AM."
        var s = NightState.preview
        s.blankReason = reason
        s.stages = []
        s.slept = .blank(reason: reason, receipt: nil)
        s.needed = .blank(reason: "no night to compare", receipt: nil)
        s.shortBy = nil
        s.lanes = s.lanes.map { NightLane(id: $0.id, title: $0.title, marks: [], blankReason: reason) }
        s.details = s.details.map { LabeledValue(id: $0.id, label: $0.label, value: .blank(reason: reason, receipt: nil)) }
        s.regularity = .blank(reason: reason, receipt: nil)
        return s
    }
}

private struct NightPreviewHost: View {
    let state: NightState
    let theme: ThemeName

    var body: some View {
        NavigationStack {
            NightView(state: state, theme: theme) { intent in print("Night intent:", intent) }
                .environment(\.mgNow, SampleDay.at(9, 40))
        }
    }
}

#Preview("Night · as given · cream") { NightPreviewHost(state: .preview, theme: .cream) }
#Preview("Night · method switch + strap flag + movement") {
    NightPreviewHost(state: NightPreviewData.withMethodsAndLanes, theme: .cream)
}
#Preview("Night · Satin Emerald") { NightPreviewHost(state: NightPreviewData.withMethodsAndLanes, theme: .emerald) }
#Preview("Night · strap off all night (blank)") { NightPreviewHost(state: NightPreviewData.blank, theme: .cream) }
#Preview("Night · largest text") {
    NightPreviewHost(state: .preview, theme: .cream)
        .environment(\.dynamicTypeSize, .accessibility3)
}
#endif
