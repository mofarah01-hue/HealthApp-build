import SwiftUI
import MGContext
import MGDesign
import MGDomain

/// The effort card of the workout detail (r9p, D-LOAD-WALK-2): Mo's CR-10 rating of the session (0 rest, 10 maximal; Foster
/// 2001), his weight before and after (for the sweat-loss estimate, 1 kg ~ 1 L), and the readouts built on them. Each save is a
/// new revision of the workout through `.editWorkout` (`.setRPE`, `.setWeights`). The app shows no "dehydrated" word and no
/// injury claim: these are Mo's own inputs next to the load.
struct WorkoutEffortCard: View {
    let workoutId: UUID
    let effort: WorkoutEffortState
    let editable: Bool
    let send: (UIIntent) -> Void
    @Environment(\.mgColors) private var colors
    @State private var rpe: Int?
    @State private var pre = ""
    @State private var post = ""

    init(workoutId: UUID, effort: WorkoutEffortState, editable: Bool, send: @escaping (UIIntent) -> Void) {
        self.workoutId = workoutId
        self.effort = effort
        self.editable = editable
        self.send = send
    }

    private var rpeOptions: [(id: Int, label: String)] {
        (0...10).map { (id: $0, label: "\($0)") }
    }

    private var savedRPE: Int? { effort.rpe.map { Int($0.rounded()) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("How hard was it overall? 0 rest, 5 hard, 10 maximal.")
                .mgFont(.detail)
                .foregroundStyle(colors.ink2.color)
            LogChoiceChips(options: rpeOptions, selection: rpeBinding, clearable: false)
            HStack(spacing: 8) {
                LogTextField("Weight before", text: $pre, decimal: true)
                LogUnitLabel("kg")
                LogTextField("Weight after", text: $post, decimal: true)
                LogUnitLabel("kg")
            }
            if weightsDirty {
                MGButton("Save weights", style: .filled) {
                    send(.editWorkout(id: workoutId, edit: .setWeights(pre: LogText.parse(pre), post: LogText.parse(post))))
                }
            }
            ForEach(effort.lines, id: \.self) { line in
                Text(line)
                    .mgFont(.detail)
                    .foregroundStyle(colors.ink2.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .disabled(!editable)
        .opacity(editable ? 1 : 0.5)
        .onAppear {
            if pre.isEmpty, let w = effort.weightPreKg { pre = LogText.number(w) }
            if post.isEmpty, let w = effort.weightPostKg { post = LogText.number(w) }
        }
    }

    /// Tapping a chip saves the rating at once (a new revision); the chip shows the saved value.
    private var rpeBinding: Binding<Int?> {
        Binding(get: { rpe ?? savedRPE },
                set: { value in
                    rpe = value
                    if let value { send(.editWorkout(id: workoutId, edit: .setRPE(Double(value)))) }
                })
    }

    private var weightsDirty: Bool {
        LogText.parse(pre) != effort.weightPreKg || LogText.parse(post) != effort.weightPostKg
    }
}
