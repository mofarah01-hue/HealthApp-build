import SwiftUI
import MGContext
import MGDesign
import MGDomain

// Workout mode (UX-SPEC §6, "replaces rows 2–4 while a workout runs"): HR + zone · zone bar · HR map with zone
// shading · time windows with "double-tap the strap = set done" (APP-007) · breathing only where two estimators
// agree (APP-031) · strain so far with its collapsed methods group (APP-284) · Next window / End workout.
// ALG-041, 047, 106, 036, 020. Pure rendering of `WorkoutModeState`. Owner: WP-13.

struct LiveWorkoutView: View {
    let live: LiveState
    let workout: WorkoutModeState
    let send: (UIIntent) -> Void
    @Environment(\.mgColors) private var colors

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The strap went off or dropped mid-workout: the session keeps running, so the controls stay.
            if let reason = live.blankReason {
                Text(reason)
                    .mgFont(.detail)
                    .foregroundStyle(colors.ink2.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, MGSpace.s)
            }
            hero
            LiveZoneBar(minutes: workout.zoneMinutes, basis: workout.zoneBasis)
                .padding(.top, MGSpace.l)

            if let summary = workout.summary {
                WorkoutSummaryCard(state: summary, send: send)      // T116
                    .padding(.top, MGSpace.l)
            }

            SectionHeader("Heart rate map", note: "\(MGFormat.time(workout.start, calendar: calendar)) → now")
            LiveHRMap(trace: workout.hrTrace, start: workout.start, zoneEdges: workout.zoneEdgesBpm)

            LiveWorkoutWindows(windows: workout.windows, hint: workout.doubleTapHint)

            LiveWorkoutBreathingRow(value: workout.breathing)
                .padding(.top, MGSpace.l)

            if let group = workout.strainGroup {
                MethodsStrip(state: group, send: send)
                    .padding(.top, MGSpace.s)
            }

            LiveWorkoutActions(actions: workout.actions, send: send)
                .padding(.top, MGSpace.l)
        }
    }

    @Environment(\.calendar) private var calendar

    private var hero: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .bottom, spacing: MGSpace.m) {
                heartRate
                Spacer(minLength: MGSpace.s)
                strain
            }
            VStack(alignment: .leading, spacing: MGSpace.m) {
                heartRate
                strain
            }
        }
    }

    private var heartRate: some View {
        VStack(alignment: .leading, spacing: MGSpace.xs) {
            HStack(alignment: .bottom, spacing: MGSpace.m) {
                LiveHRNumber(value: workout.heartRate, beatInterval: live.beatInterval)
                if let zone = workout.zone, !workout.heartRate.isBlank {
                    Text("zone \(zone)")
                        .mgFont(.rowTitle)
                        .foregroundStyle(colors.ink.color)
                        .padding(.bottom, MGSpace.s)
                }
            }
            LiveReceiptAge(value: workout.heartRate, sample: workout.sample)
        }
    }

    private var strain: some View {
        VStack(alignment: .trailing, spacing: MGSpace.xs) {
            ValueView(workout.strain, size: .number, showsReceipt: true)
            Text("strain so far")
                .mgFont(.receipt)
                .foregroundStyle(colors.mute.color)
        }
        .frame(maxWidth: 150, alignment: .trailing)
    }
}

// MARK: - Zone bar

/// Time in each of the five zones: a bar proportional to minutes plus a legend of the minutes in words, so the
/// bar is never the only carrier (zone order is fixed Z1 → Z5, left to right).
struct LiveZoneBar: View {
    let minutes: [Double]
    /// Where the zone edges come from ("measured max 190", "Tanaka estimate 186"); nil = no max known.
    let basis: String?
    @Environment(\.mgColors) private var colors

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if total > 0 {
                GeometryReader { geo in
                    HStack(spacing: 2) {
                        ForEach(segments, id: \.zone) { segment in
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(LiveZoneStyle.color(zone: segment.zone, colors: colors).color)
                                .frame(width: max(4, (geo.size.width - 8) * segment.share))
                        }
                    }
                }
                .frame(height: 14)
                .accessibilityHidden(true)
            } else {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(colors.rule.color)
                    .frame(height: 14)
                    .accessibilityHidden(true)
            }
            Text(legend)
                .mgFont(.receipt)
                .foregroundStyle(colors.mute.color)
                .fixedSize(horizontal: false, vertical: true)
            Text(basisText)
                .mgFont(.receipt)
                .foregroundStyle(colors.mute.color)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken + " " + basisText)
    }

    private var five: [Double] {
        (0..<5).map { i in
            i < minutes.count && minutes[i].isFinite ? max(0, minutes[i]) : 0
        }
    }

    private var total: Double { five.reduce(0, +) }

    private struct Segment {
        let zone: Int
        let share: CGFloat
    }

    /// Zones with time, in order; a zone with 0 min has no segment (it is still in the legend).
    private var segments: [Segment] {
        guard total > 0 else { return [] }
        return five.enumerated().compactMap { i, m in
            m > 0 ? Segment(zone: i + 1, share: CGFloat(m / total)) : nil
        }
    }

    /// "Z1 2 min · Z2 4 · Z3 6 · Z4 1 · Z5 0"
    private var legend: String {
        if total == 0 { return "No time in a zone yet." }
        let parts = five.enumerated().map { i, m -> String in
            let n = Int(m.rounded())
            return i == 0 ? "Z1 \(n) min" : "Z\(i + 1) \(n)"
        }
        return parts.joined(separator: " · ")
    }

    /// Small print under the legend: where the zone edges come from, or that none is known.
    private var basisText: String {
        if let basis, !basis.isEmpty { return "zones from your \(basis)" }
        return "zones: no max heart rate known yet"
    }

    private var spoken: String {
        if total == 0 { return "Time in zones: none yet." }
        let parts = five.enumerated().map { i, m in "zone \(i + 1), \(Int(m.rounded())) minutes" }
        return "Time in zones: " + parts.joined(separator: "; ") + "."
    }
}

// MARK: - Windows

/// Time windows of the session (warm-up / work / rest / cooldown), the open one ends "now", and the
/// "double-tap the strap = set done" line (APP-007).
struct LiveWorkoutWindows: View {
    let windows: [WorkoutWindowRow]
    let hint: String?
    @Environment(\.mgColors) private var colors

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader("Windows", note: hint == nil ? nil : "double-tap the strap = set done")
            MGCard(padding: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    if windows.isEmpty {
                        Text("No window yet. The first one starts with the workout.")
                            .mgFont(.detail)
                            .foregroundStyle(colors.ink2.color)
                            .padding(MGSpace.cardInset)
                    } else {
                        ForEach(Array(windows.enumerated()), id: \.element.id) { index, window in
                            LiveWorkoutWindowRow(window: window)
                            if index < windows.count - 1 || hint != nil {
                                Rectangle().fill(colors.rule.color).frame(height: 1).padding(.horizontal, MGSpace.cardInset)
                            }
                        }
                    }
                    if let hint {
                        HStack(alignment: .center, spacing: MGSpace.m) {
                            LetterBadge("2×", accent: .ink2)
                            Text(hint)
                                .mgFont(.detail)
                                .foregroundStyle(colors.ink2.color)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.horizontal, MGSpace.cardInset)
                        .padding(.vertical, MGSpace.m)
                        .frame(minHeight: MGSpace.rowMinHeight, alignment: .leading)
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
    }
}

struct LiveWorkoutWindowRow: View {
    let window: WorkoutWindowRow
    @Environment(\.mgColors) private var colors
    @Environment(\.calendar) private var calendar

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: MGSpace.m) {
            VStack(alignment: .leading, spacing: MGSpace.xs) {
                Text(window.label)
                    .mgFont(.rowTitle)
                    .foregroundStyle(colors.ink.color)
                    .fixedSize(horizontal: false, vertical: true)
                if let duration {
                    Text(duration)
                        .mgFont(.receipt)
                        .foregroundStyle(colors.mute.color)
                }
            }
            Spacer(minLength: MGSpace.s)
            VStack(alignment: .trailing, spacing: MGSpace.xs) {
                Text(range)
                    .mgFont(.detail)
                    .foregroundStyle(colors.ink.color)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("avg").mgFont(.receipt).foregroundStyle(colors.mute.color)
                    ValueView(window.avgHR, size: .inline)
                }
            }
        }
        .padding(.horizontal, MGSpace.cardInset)
        .padding(.vertical, MGSpace.m)
        .frame(minHeight: MGSpace.rowMinHeight, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    /// "5:32–5:38 PM", or "5:38 PM → now" while the window is open.
    private var range: String {
        let from = MGFormat.time(window.start, calendar: calendar)
        guard let end = window.end else { return "\(from) → now" }
        return "\(from)–\(MGFormat.time(end, calendar: calendar))"
    }

    private var duration: String? {
        guard let end = window.end else { return "open" }
        return MGFormat.duration(end.timeIntervalSince(window.start))
    }
}

// MARK: - Breathing

/// Breathing per minute, shown only where two estimators agree and the motion gate passes (APP-031); otherwise the
/// value is blank and carries its reason.
struct LiveWorkoutBreathingRow: View {
    let value: DisplayValue
    @Environment(\.mgColors) private var colors

    var body: some View {
        HStack(alignment: .top, spacing: MGSpace.m) {
            VStack(alignment: .leading, spacing: MGSpace.xs) {
                Text("Breathing")
                    .mgFont(.rowTitle)
                    .foregroundStyle(colors.ink.color)
                Text("last minute · only where two estimators agree")
                    .mgFont(.receipt)
                    .foregroundStyle(colors.mute.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: MGSpace.s)
            ValueView(value, size: .number, showsReceipt: true)
                .frame(maxWidth: 160, alignment: .trailing)
        }
        .padding(.vertical, MGSpace.m)
        .overlay(alignment: .bottom) { Rectangle().fill(colors.rule.color).frame(height: 1) }
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Actions

/// Next window · End workout. "End workout" is the filled button. A disabled one says why.
struct LiveWorkoutActions: View {
    let actions: [ActionState]
    let send: (UIIntent) -> Void
    @Environment(\.mgColors) private var colors
    /// R8e (L2): ending saves the workout for good, so it asks first.
    @State private var confirmingEnd = false

    var body: some View {
        if !actions.isEmpty {
            FlowLayout(spacing: MGSpace.m, lineSpacing: MGSpace.m) {
                ForEach(actions) { action in
                    VStack(alignment: .leading, spacing: MGSpace.xs) {
                        let runnable = action.enabled && action.intent != nil
                        MGButton(action.title, style: action.id == "end" ? .filled : .ghost) {
                            guard let intent = action.intent else { return }
                            if intent == .endWorkout { confirmingEnd = true } else { send(intent) }
                        }
                        .disabled(!runnable)
                        .opacity(runnable ? 1 : 0.5)
                        if !runnable {
                            Text(action.disabledReason ?? "Unavailable (no reason given).")
                                .mgFont(.receipt)
                                .foregroundStyle(colors.ink2.color)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .confirmationDialog("End this workout?", isPresented: $confirmingEnd, titleVisibility: .visible) {
                Button("End and save workout", role: .destructive) { send(.endWorkout) }
                Button("Keep going", role: .cancel) {}
            } message: {
                Text("It is saved to your log as it is now. Ending can't be undone from here.")
            }
        }
    }
}
