import SwiftUI
import MGContext
import MGDesign
import MGDomain

// Building blocks of the Live tab (UX-SPEC §6): header, heart-rate hero, vitals, stream list, action grid,
// toggle row, research links, blank state. Pure rendering of `LiveState`; every tap is a `UIIntent` through `send`.
// Owner: WP-13. Colour is never the only code: every dot has words beside it (UX §1.2).

// MARK: - Header (row 1: LiveHeader + StreamChip)

struct LiveHeader: View {
    let state: LiveState
    @Environment(\.mgColors) private var colors
    @Environment(\.calendar) private var calendar

    var body: some View {
        VStack(alignment: .leading, spacing: MGSpace.xs) {
            kicker
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 8) {
                    title
                    Spacer(minLength: 8)
                    chips
                }
                VStack(alignment: .leading, spacing: 6) {
                    title
                    chips
                    if let note = state.hrSourceNote {
                        Text(note).mgFont(.kicker).foregroundStyle(colors.mute.color)   // 0.6.0.12: "Heart rate from WHOOP 5.0 broadcast"
                    }
                }
            }
        }
    }

    private var title: some View {
        Text(state.deviceName == "MG" ? "Live" : "Live · \(state.deviceName)")
            .mgFont(.title)
            .foregroundStyle(colors.ink.color)
            .accessibilityAddTraits(.isHeader)
    }

    private var chips: some View {
        HStack(spacing: 6) {
            if let workout = state.workout {
                LiveElapsedChip(elapsed: workout.elapsed)
            }
            LiveStreamChip(chip: state.streamChip)
        }
    }

    @ViewBuilder private var kicker: some View {
        if let workout = state.workout {
            kickerText("Workout · \(workout.title)")
        } else if state.blankReason != nil {
            kickerText("Strap · nothing live")
        } else {
            TimelineView(.everyMinute) { context in
                kickerText(dateLine(context.date))
            }
        }
    }

    private func kickerText(_ text: String) -> some View {
        Text(text)
            .mgFont(.kicker)
            .foregroundStyle(colors.topText.color)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// "SUN 11 OCT · 9:40 AM" (UX §1.3: 12-hour time).
    private func dateLine(_ date: Date) -> String {
        "\(MGFormat.kickerDate(date, calendar: calendar)) · \(MGFormat.time(date, calendar: calendar))"
    }
}

/// "R26 · 25 Hz · quality good" with a status dot (UX §6 row 1). Header text uses `topText` (brightest part of the glow).
struct LiveStreamChip: View {
    let chip: StreamChipState
    @Environment(\.mgColors) private var colors

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(colors.status(chip.tone).color).frame(width: 8, height: 8)
            Text(chip.text)
        }
        .mgFont(MGTextStyle(family: .mono, size: 12, lineHeight: 15, weight: .medium, relativeTo: .caption,
                            maxScale: 1.6))
        .foregroundStyle(colors.topText.color)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .padding(.horizontal, 10)
        .frame(minHeight: 32)
        .background(Capsule().fill(colors.chip.color))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Stream: \(chip.text)")
    }
}

/// Red dot + elapsed time while a workout runs (prototype `.stat` with `.dot.red`).
struct LiveElapsedChip: View {
    let elapsed: String
    @Environment(\.mgColors) private var colors

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(colors.body.color).frame(width: 7, height: 7)
            Text(elapsed)
        }
        .mgFont(MGTextStyle(family: .mono, size: 10.5, lineHeight: 13, weight: .medium, relativeTo: .caption2,
                            tabular: true, maxScale: 1.6))
        .foregroundStyle(colors.topText.color)
        .padding(.horizontal, 10)
        .frame(minHeight: 32)
        .background(Capsule().fill(colors.chip.color))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Workout running, \(elapsed)")
    }
}

// MARK: - Heart-rate hero (row 2: HRHero)

/// HR in `heroNumber`, beat dot and receipt, followed by the two large live metric tiles and today's body-arousal line.
struct LiveHeartBlock: View {
    let state: LiveState
    @Environment(\.mgColors) private var colors
    @Environment(\.mgTheme) private var theme
    /// 0.6.0.12: the explainer card of the tapped tile (RMSSD or autonomic load).
    @State private var card: HRVExplainerState?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            LiveHRNumber(value: state.heartRate, beatInterval: state.beatInterval)
            LiveReceiptAge(value: state.heartRate, sample: state.sample)
                .padding(.top, MGSpace.xs)
            // r9v (UI-SCRUB L12): unit and METRICS grade (docs/METRICS.md M01) in words under the receipt.
            if !state.heartRate.isBlank {
                Text("beats per minute (bpm) · \(MetricGrade.Live.heartRate.grade.line(MetricGrade.Live.heartRate.row))")
                    .mgFont(.receipt)
                    .foregroundStyle(colors.mute.color)
            }
            HStack(alignment: .top, spacing: MGSpace.s) {
                // The R-R behind it is wrist pulse, not ECG (METRICS M04), so the tile says so.
                // 0.6.0.12: solid / grey-with-reason / blank (LiveTileState), not a blank for every case that misses the rules.
                LiveStateTile(label: "RMSSD (5 min)", tile: state.rmssdTile, caption: MetricGrade.Live.rmssdCaption,
                              onTap: { card = state.rmssdCard })
                LiveStateTile(label: "Autonomic load", tile: state.loadTile, onTap: { card = state.loadCard },
                              reserveMeter: state.loadTile.kind == .solid)
                    .overlay(alignment: .bottomLeading) {
                        if let level = state.autonomicLevel, state.loadTile.kind == .solid {
                            LiveLevelMeter(level: level)
                                .padding(MGSpace.tileInset)
                        }
                    }
            }
            .padding(.top, MGSpace.l)
            LiveTodayLine(label: "Average heart rate today", value: state.averageToday)
            LiveTodayLine(label: "Worn today", value: state.wornToday)
            HStack(alignment: .top, spacing: MGSpace.m) {
                Text("Body arousal today")
                    .mgFont(.rowTitle)
                    .foregroundStyle(colors.ink.color)
                Spacer(minLength: MGSpace.s)
                VStack(alignment: .trailing, spacing: 2) {
                    ValueView(state.stressToday, size: .small, showsReceipt: true)
                    if !state.stressToday.isBlank {
                        Text(MetricGrade.Live.stress.grade.line(MetricGrade.Live.stress.row))
                            .mgFont(.receipt)
                            .foregroundStyle(colors.mute.color)
                    }
                }
                .frame(maxWidth: 210, alignment: .trailing)
            }
            .padding(.vertical, MGSpace.m)
            .overlay(alignment: .bottom) { Rectangle().fill(colors.rule.color).frame(height: 1) }
        }
        .sheet(item: $card) { c in
            HRVExplainerSheet(state: c)
                .mgTheme(theme)
        }
    }
}

/// One 'label ... value' line under the live tiles (average heart rate today, time worn today); the value says why when blank.
struct LiveTodayLine: View {
    let label: String
    let value: DisplayValue
    @Environment(\.mgColors) private var colors

    var body: some View {
        HStack(alignment: .top, spacing: MGSpace.m) {
            Text(label)
                .mgFont(.rowTitle)
                .foregroundStyle(colors.ink.color)
            Spacer(minLength: MGSpace.s)
            ValueView(value, size: .small, showsReceipt: true)
                .frame(maxWidth: 210, alignment: .trailing)
        }
        .padding(.top, MGSpace.m)
    }
}

/// The big number with the beat dot. A blank value shows "—" and its reason (ValueView), never a number.
struct LiveHRNumber: View {
    let value: DisplayValue
    let beatInterval: Double?

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            ValueView(value, size: .hero)
            if !value.isBlank {
                LiveBeatDot(interval: beatInterval)
                    .padding(.bottom, 16)
            }
        }
    }
}

/// Scale 1 → 1.18 → 1 on each beat (UX §1.4, prototype `@keyframes pop`). Still under Reduce Motion or with no beat.
struct LiveBeatDot: View {
    let interval: Double?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.mgColors) private var colors

    var body: some View {
        Group {
            if let interval, interval > 0.2, interval < 3, !reduceMotion {
                TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                    dot(scale: LiveBeatDot.scale(at: context.date.timeIntervalSinceReferenceDate, interval: interval))
                }
            } else {
                dot(scale: 1)
            }
        }
        .accessibilityHidden(true)
    }

    private func dot(scale: CGFloat) -> some View {
        Circle()
            .fill(colors.body.color)
            .frame(width: 12, height: 12)
            .scaleEffect(scale)
    }

    /// Up to the peak in the first 12 % of the beat, back to 1 by 30 %.
    static func scale(at time: TimeInterval, interval: Double) -> CGFloat {
        let phase = (time / interval).truncatingRemainder(dividingBy: 1)
        let peak = MGMotion.pulseScale - 1
        if phase < 0.12 { return 1 + peak * CGFloat(phase / 0.12) }
        if phase < 0.30 { return 1 + peak * CGFloat(1 - (phase - 0.12) / 0.18) }
        return 1
    }
}

/// A 0…1 level as a bar with quarter ticks (position and length carry the value, not colour).
struct LiveLevelMeter: View {
    let level: Double
    @Environment(\.mgColors) private var colors

    var body: some View {
        let clamped = min(max(level.isFinite ? level : 0, 0), 1)
        ZStack(alignment: .leading) {
            Capsule().fill(colors.rule.color)
            GeometryReader { geo in
                Capsule()
                    .fill(colors.ink.color)
                    .frame(width: max(4, geo.size.width * clamped))
            }
            // Three quarter ticks, so the level can be read against a scale.
            HStack(spacing: 0) {
                ForEach(0..<3, id: \.self) { _ in
                    Spacer(minLength: 0)
                    Rectangle().fill(colors.background.lastColor.color).frame(width: 1.5)
                }
                Spacer(minLength: 0)
            }
        }
        .frame(width: 72, height: 6)
        .clipShape(Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Level \(Int((clamped * 100).rounded())) percent of the scale")
    }
}

/// "strap · live · 1 s ago". Ages from the receipt time against the real clock once a second, so a stalled
/// stream reads "47 s ago" and then "last beat 2 min ago" instead of looking live.
struct LiveReceiptAge: View {
    let value: DisplayValue
    let sample: Bool
    @Environment(\.mgColors) private var colors
    @Environment(\.calendar) private var calendar

    var body: some View {
        if case let .value(_, _, receipt, _, _) = value {
            TimelineView(.periodic(from: Date(), by: 1)) { context in
                Text(LiveAge.line(who: receipt.whereText, at: receipt.at, now: context.date, calendar: calendar,
                                  sample: sample))
                    .mgFont(.receipt)
                    .foregroundStyle(colors.mute.color)
            }
        }
    }
}

/// Wording of the age line. Pure, so it can be tested without a view.
enum LiveAge {
    static func line(who: String, at: Date, now: Date, calendar: Calendar, sample: Bool) -> String {
        if sample { return "\(who) · live · sample" }
        let age = max(0, now.timeIntervalSince(at))
        if age < 60 { return "\(who) · live · \(max(1, Int(age))) s ago" }
        if age < 3600 { return "\(who) · last beat \(Int(age / 60)) min ago" }
        return "\(who) · last beat \(MGFormat.shortDate(at, calendar: calendar)) \(MGFormat.time(at, calendar: calendar))"
    }
}

// MARK: - Stream list (row 5: StreamList)

/// "R26 pulse, 25 Hz, flowing" · "50 Hz mode flag off" · "R20 raw optical off".
/// Good = filled dot, neutral = ring, so the dot shape differs as well as its colour; the sentence says the rest.
struct LiveStreamsCard: View {
    let master: StreamsMasterState?
    let lines: [StreamLine]
    let send: (UIIntent) -> Void
    @Environment(\.mgColors) private var colors

    var body: some View {
        MGCard {
            VStack(alignment: .leading, spacing: 0) {
                if let master {
                    LiveStreamsMasterButton(master: master, send: send)
                    if !lines.isEmpty {
                        Rectangle().fill(colors.rule.color).frame(height: 1).padding(.vertical, MGSpace.s)
                    }
                }
                ForEach(Array(lines.enumerated()), id: \.element.id) { index, line in
                    LiveStreamRow(line: line)
                    if index < lines.count - 1 {
                        Rectangle().fill(colors.rule.color).frame(height: 1).padding(.vertical, MGSpace.s)
                    }
                }
            }
        }
        .padding(.top, MGSpace.section)
    }
}

struct LiveStreamRow: View {
    let line: StreamLine
    @Environment(\.mgColors) private var colors

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            LiveStatusDot(tone: line.tone)
            VStack(alignment: .leading, spacing: 4) {
                Text(line.text)
                    .mgFont(.body)
                    .foregroundStyle(colors.ink.color)
                    .fixedSize(horizontal: false, vertical: true)
                let badges = LiveStreamRow.badges(for: line)
                if !badges.isEmpty {
                    FlowLayout(spacing: 6, lineSpacing: 4) {
                        ForEach(badges, id: \.self) { badge in
                            if badge == "unlock needed" {
                                TagPill(text: badge)
                            } else {
                                Text(badge)
                                    .mgFont(.tag)
                                    .foregroundStyle(colors.ink2.color)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 3)
                                    .background {
                                        RoundedRectangle(cornerRadius: MGRadius.tag, style: .continuous)
                                            .fill(colors.chip.color)
                                    }
                            }
                        }
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(LiveStreamRow.spoken(line))
    }

    /// Badges after the sentence: the line's own note, plus "unlock needed" on a locked R20 line.
    static func badges(for line: StreamLine) -> [String] {
        var out: [String] = []
        let note = line.note ?? ""
        if line.id == "r20", line.tone != .good, !note.localizedCaseInsensitiveContains("unlock") {
            out.append("unlock needed")
        }
        if !note.isEmpty { out.append(note) }
        return out
    }

    static func spoken(_ line: StreamLine) -> String {
        let prefix: String
        switch line.tone {
        case .good: prefix = "Flowing."
        case .warn: prefix = "Warning."
        case .bad: prefix = "Problem."
        case .neutral: prefix = "Not active."
        }
        let notes = badges(for: line).joined(separator: ", ")
        return [prefix, line.text, notes].filter { !$0.isEmpty }.joined(separator: " ")
    }
}

/// Filled dot (good, warn, bad) or ring (neutral).
struct LiveStatusDot: View {
    let tone: StatusTone
    @Environment(\.mgColors) private var colors

    var body: some View {
        Group {
            if tone == .neutral {
                Circle().strokeBorder(colors.status(tone).color, lineWidth: 1.6)
            } else {
                Circle().fill(colors.status(tone).color)
            }
        }
        .frame(width: 10, height: 10)
        .accessibilityHidden(true)
    }
}

// MARK: - Action grid (row 6: ActionGrid)

/// Breathe · HRV check · ECG 30 s · Workout · SpO₂ now. A tile that cannot run says why on the tile itself
/// (UX §6, §13), not only by looking dim.
struct LiveActionGrid: View {
    let actions: [ActionState]
    let send: (UIIntent) -> Void

    private let columns: [GridItem] = [
        GridItem(.flexible(), spacing: 10, alignment: .top),
        GridItem(.flexible(), spacing: 10, alignment: .top),
    ]

    var body: some View {
        if !actions.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                SectionHeader("Start something")
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(actions) { action in
                        LiveActionTile(action: action, send: send)
                    }
                }
            }
        }
    }
}

struct LiveActionTile: View {
    let action: ActionState
    let send: (UIIntent) -> Void
    @Environment(\.mgColors) private var colors
    /// R8e (L2): "End workout" saves the workout for good, so it asks first.
    @State private var confirmingEnd = false

    /// An enabled action with no intent is a wiring bug; show it as unavailable with that reason instead of a dead tap.
    private var runnable: Bool { action.enabled && action.intent != nil }

    var body: some View {
        if runnable, let intent = action.intent {
            Button {
                if intent == .endWorkout { confirmingEnd = true } else { send(intent) }
            } label: { tile }
                .buttonStyle(MGPressButtonStyle())
                .accessibilityLabel(action.title)
                .accessibilityHint(LiveActionTile.hint(for: action) ?? "")
                .confirmationDialog("End this workout?", isPresented: $confirmingEnd, titleVisibility: .visible) {
                    Button("End and save workout", role: .destructive) { send(.endWorkout) }
                    Button("Keep going", role: .cancel) {}
                } message: {
                    Text("It is saved to your log as it is now. Ending can't be undone from here.")
                }
        } else {
            tile
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(action.title), unavailable. \(reason)")
        }
    }

    private var reason: String {
        if let r = action.disabledReason, !r.isEmpty { return r }
        return action.enabled ? "Nothing is wired to this yet." : "Unavailable (no reason given)."
    }

    private var tile: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                Image(systemName: LiveActionTile.symbol(for: action.id))
                    .imageScale(.large)
                    .foregroundStyle(runnable ? colors.ink.color : colors.mute.color)
                    .opacity(runnable ? 1 : 0.6)         // R8e (L5): only the icon and title are dimmed, never the reason
                Spacer(minLength: 0)
                if !runnable {
                    Image(systemName: "minus.circle")
                        .imageScale(.small)
                        .foregroundStyle(colors.mute.color)
                }
            }
            .accessibilityHidden(true)
            Text(action.title)
                .mgFont(.rowTitle)
                .foregroundStyle(runnable ? colors.ink.color : colors.ink2.color)
                .opacity(runnable ? 1 : 0.75)
                .fixedSize(horizontal: false, vertical: true)
            if let hint = LiveActionTile.hint(for: action) {
                Text(hint).mgFont(.detail).foregroundStyle(colors.ink2.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !runnable {
                Text(reason).mgFont(.detail).foregroundStyle(colors.ink2.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(MGSpace.tileInset)
        .frame(maxWidth: .infinity, minHeight: 112, alignment: .topLeading)
        .mgSurface(.tile)
        .contentShape(Rectangle())
    }

    /// One-line hints from the prototype; ids come from the presenter (`LiveState.preview`). R8e (L3): keyed on what the
    /// tile does now (the "End workout" tile said "start one by hand"), and none that repeats the title.
    static func hint(for action: ActionState) -> String? {
        switch action.id {
        case "breathe": return "pacer + coherence"
        case "hrv": return "1–5 min, sit still"
        case "ecg": return "wrist only"
        case "workout": return action.intent == .endWorkout ? "saves it to your log" : "start one by hand"
        default: return nil
        }
    }

    static func symbol(for id: String) -> String {
        switch id {
        case "breathe": return "wind"
        case "hrv": return "timer"
        case "ecg": return "waveform.path.ecg"
        case "workout": return "figure.run"
        case "spo2": return "drop"
        default: return "circle.dashed"
        }
    }
}

// MARK: - Toggle row (row 7: BroadcastToggle; also the Strap & sync sheet)

/// A switch row whose tap sends the toggle's own intent (it already carries the new value: ToggleState.intent).
/// A disabled switch shows its reason underneath.
struct LiveToggleRow: View {
    let toggle: ToggleState
    let send: (UIIntent) -> Void
    var splitsStrapStatus = false
    @Environment(\.mgColors) private var colors

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            OptimisticToggle(isOn: toggle.isOn, onChange: { _ in send(toggle.intent) }) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(toggle.title)
                        .mgFont(.rowTitle)
                        .foregroundStyle(colors.ink.color)
                        .fixedSize(horizontal: false, vertical: true)
                    if let detail = detail {
                        Text(detail)
                            .mgFont(.detail)
                            .foregroundStyle(colors.ink2.color)
                            .lineLimit(splitsStrapStatus ? 2 : nil)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .disabled(!toggle.enabled)
            if !toggle.enabled {
                Text(toggle.disabledReason ?? "Unavailable (no reason given).")
                    .mgFont(.detail)
                    .foregroundStyle(colors.ink2.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let strapStatus {
                Text(strapStatus)
                    .mgFont(.detail)
                    .foregroundStyle(colors.ink2.color)
            }
        }
        .frame(minHeight: MGSpace.tapTarget)
    }

    private var detail: String? {
        guard splitsStrapStatus, let text = toggle.detail,
              let range = text.range(of: "Strap reports:") else { return toggle.detail }
        return String(text[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var strapStatus: String? {
        guard splitsStrapStatus, let text = toggle.detail,
              let range = text.range(of: "Strap reports:") else { return nil }
        return String(text[range.lowerBound...])
    }
}

/// T148: "Streams: 2 of 3 on" with one button that turns them all on, or all off when all are on. It sends the same
/// per-stream intents the switches below send, so every strap write stays on its already-allowed path. Each switch below
/// still works on its own.
struct LiveStreamsMasterButton: View {
    let master: StreamsMasterState
    let send: (UIIntent) -> Void
    @Environment(\.mgColors) private var colors

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: MGSpace.m) {
                Text(master.text)
                    .mgFont(.body)
                    .foregroundStyle(colors.ink.color)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Pill(master.title, weight: .filled) {
                    for intent in master.intents { send(intent) }
                }
                .disabled(!master.enabled)
                .opacity(master.enabled ? 1 : 0.4)
            }
            .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
            .accessibilityLabel("\(master.text). \(master.title).")
            if !master.enabled {
                Text(master.disabledReason ?? "Unavailable (no reason given).")
                    .mgFont(.detail)
                    .foregroundStyle(colors.ink2.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Research links (row 8: ResearchLinks, dotted research tag)

struct LiveResearchLinks: View {
    let links: [ActionState]
    let send: (UIIntent) -> Void
    @Environment(\.mgColors) private var colors

    var body: some View {
        if !links.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Text("Research")
                        .mgFont(.headline)
                        .foregroundStyle(colors.ink.color)
                        .accessibilityAddTraits(.isHeader)
                    ResearchTag()
                    Spacer(minLength: 0)
                }
                .padding(.top, MGSpace.section - 2)
                .padding(.bottom, 8)
                MGCard(padding: 0) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(links.enumerated()), id: \.element.id) { index, link in
                            LiveResearchRow(link: link, send: send)
                            if index < links.count - 1 {
                                Rectangle().fill(colors.rule.color).frame(height: 1).padding(.horizontal, 16)
                            }
                        }
                    }
                }
            }
        }
    }
}

/// r9v (UI-SCRUB T2): the raw-optical / ECG switches have one home, Strap & sync; the Live tab links there.
struct LiveStrapSyncLink: View {
    let what: String
    let send: (UIIntent) -> Void
    @Environment(\.mgColors) private var colors

    var body: some View {
        Button { send(.openStrapSync) } label: {
            Text("\(what) is switched in Strap & sync ›")
                .mgFont(.detail)
                .foregroundStyle(colors.ink2.color)
                .underline()
                .frame(maxWidth: .infinity, minHeight: MGSpace.tapTarget, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// r9v (UI-SCRUB L14): one quiet row where the research links and the history test used to be.
struct LiveResearchMovedLink: View {
    let send: (UIIntent) -> Void
    @Environment(\.mgColors) private var colors

    var body: some View {
        Button { send(.openResearch("decode")) } label: {
            Text("Research tools and the history test are in Settings › Decode lab ›")
                .mgFont(.body)
                .foregroundStyle(colors.ink2.color)
                .underline()
                .frame(maxWidth: .infinity, minHeight: MGSpace.tapTarget, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.top, MGSpace.section - 2)
        .accessibilityHint("Opens the Decode lab")
    }
}

/// 0.6.0.12: one quiet row to the Raw WHOOP 4.0 data screen, shown only while the 4.0 is the selected strap device.
struct LiveWhoop4RawLink: View {
    let action: ActionState
    let send: (UIIntent) -> Void
    @Environment(\.mgColors) private var colors

    var body: some View {
        Button { if let intent = action.intent { send(intent) } } label: {
            Text("\(action.title): the 4.0's once-a-second raw fields and charts ›")
                .mgFont(.body)
                .foregroundStyle(colors.ink2.color)
                .underline()
                .frame(maxWidth: .infinity, minHeight: MGSpace.tapTarget, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens the raw WHOOP 4.0 fields")
    }
}

/// Wave W12b: the last "read history without deleting" test, in the presenter's words (nothing when never run).
struct LiveHistoryReadTest: View {
    let lines: [String]
    @Environment(\.mgColors) private var colors

    var body: some View {
        if !lines.isEmpty {
            MGCard {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Read history without deleting — last result")
                        .mgFont(.body)
                        .foregroundStyle(colors.ink.color)
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .mgFont(.detail)
                            .foregroundStyle(colors.ink2.color)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.top, 8)
        }
    }
}

struct LiveResearchRow: View {
    let link: ActionState
    let send: (UIIntent) -> Void
    @Environment(\.mgColors) private var colors
    @Environment(\.mgQuietHaptics) private var quietHaptics
    @State private var logTaps = 0

    private var runnable: Bool { link.enabled && link.intent != nil }

    var body: some View {
        if runnable, let intent = link.intent {
            Button {
                if link.id == "capture" { logTaps += 1 }
                send(intent)
            } label: { row }
                .buttonStyle(MGPressButtonStyle())
                .mgLogHaptic(trigger: logTaps, quiet: quietHaptics)
        } else {
            row.accessibilityElement(children: .combine)
        }
    }

    private var row: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(link.title)
                    .mgFont(.body)
                    .foregroundStyle(runnable ? colors.ink.color : colors.ink2.color)
                if !runnable {
                    Text(link.disabledReason ?? "Unavailable (no reason given).")
                        .mgFont(.detail)
                        .foregroundStyle(colors.ink2.color)
                }
            }
            Spacer(minLength: 0)
            if runnable {
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(colors.mute.color)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, minHeight: MGSpace.rowMinHeight, alignment: .leading)
        .contentShape(Rectangle())
    }
}

// MARK: - Blank state (UX §13 "Strap off now")

/// "Strap's off your wrist — nothing to show live. Off since 3:12 PM." Everything numeric is left out; the reason is
/// the whole content (R6). Actions below stay visible and say why they are unavailable.
struct LiveBlankBlock: View {
    let reason: String
    /// T141: Bluetooth off / not allowed — show the pairing sheet's "Open Settings" button.
    var showOpenSettings: Bool = false
    @Environment(\.mgColors) private var colors

    var body: some View {
        MGCard {
            VStack(alignment: .leading, spacing: 6) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Nothing to show live.")
                        .mgFont(.headline)
                        .foregroundStyle(colors.ink.color)
                        .accessibilityAddTraits(.isHeader)
                    Text(reason)
                        .mgFont(.body)
                        .foregroundStyle(colors.ink2.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
                // Outside the combined element so VoiceOver keeps it a separate button (T141).
                if showOpenSettings {
                    OpenSettingsButton()
                        .padding(.top, 4)
                }
            }
        }
    }
}
