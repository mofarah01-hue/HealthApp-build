#if DEBUG
import SwiftUI
import MGContext
import MGDesign
import MGDomain

// Xcode previews of the dial's detail sheets in Day (cream) and Night (emerald). Every value is invented and round;
// nothing here comes from a store, a capture or a screenshot. Intents print.

private enum DetailSamples {
    static let cal = SampleDay.calendar
    static let r = SampleDay.receipt(.phone, .estimate, 18, 0)
    static func est(_ text: String, _ unit: String? = nil) -> DisplayValue { SampleDay.value(text, unit, r, .estimate(nil)) }
    static func plain(_ text: String, _ unit: String? = nil) -> DisplayValue { SampleDay.value(text, unit, r) }
    static func time(_ h: Int, _ m: Int) -> String { MGFormat.time(SampleDay.at(h, m), calendar: cal) }
    static func range(_ h0: Int, _ m0: Int, _ h1: Int, _ m1: Int) -> String {
        MGFormat.timeRange(SampleDay.at(h0, m0), SampleDay.at(h1, m1), calendar: cal)
    }

    static func week(_ values: [Double?]) -> [DayPoint] {
        values.enumerated().map { DayPoint(day: SampleDay.day.adding(days: $0.offset - 6), value: $0.element) }
    }

    static let strain = DialDetail(
        id: .ring(.strain), tone: .body, kicker: "Strain · today so far", title: "9 of 21", value: est("9.0", "/21"),
        sentence: "Just under today's target of 10 to 14.",
        visuals: [.ring(fraction: 0.43, target: 0.48...0.67), .week(week([8, 12, 10, nil, 14, 6, 9]), max: 21, unit: "/21")],
        visualSummary: "Strain ring 43 percent full, target 10 to 14. Last 7 days: 8, 12, 10, none, 14, 6, today 9.",
        rows: [LabeledValue(id: "target", label: "Target", value: est("10–14"), caption: "a moderate day"),
               LabeledValue(id: "left", label: "Left today", value: est("1–5"))],
        itemsTitle: "Workouts today",
        items: [DialDetailItem(id: "w1", title: "Run", detail: range(7, 0, 7, 40), trailing: "strain 6",
                               intent: .openWorkout(id: nil)),
                DialDetailItem(id: "w2", title: "Walk", detail: range(12, 30, 13, 0), trailing: "strain 2",
                               intent: .openWorkout(id: nil)),
                DialDetailItem(id: "w3", title: "Weights", detail: range(17, 30, 18, 10), trailing: "strain 5",
                               intent: .openWorkout(id: nil))],
        actions: [ActionState(id: "explore", title: "Strain in Explore ›", intent: .openMetric(key: "strain", variant: nil))])

    static let recovery = DialDetail(
        id: .ring(.recovery), tone: .focus, kicker: "Recovery · this morning", title: "82 /100",
        value: plain("82"), visuals: [.ring(fraction: 0.82, target: nil)],
        visualSummary: "Recovery ring 80 percent full.",
        rows: [LabeledValue(id: "hrv", label: "HRV", value: plain("50", "ms"), caption: "in your range"),
               LabeledValue(id: "rhr", label: "Resting HR", value: plain("60", "bpm"), caption: "in your range")])

    static let sleep: DialDetail = {
        let stages: [(Double, Double, StageSegment.Stage)] = [
            (-1.0, -0.5, .light), (-0.5, 0.5, .deep), (0.5, 1.0, .rem), (1.0, 1.25, .awake), (1.25, 2.5, .light),
            (2.5, 3.0, .unstaged), (3.0, 4.0, .rem), (4.0, 5.0, .light), (5.0, 5.5, .deep), (5.5, 6.0, .rem),
        ]
        let segments = stages.map {
            StageSegment(stage: $0.2, start: SampleDay.at(0, 0).addingTimeInterval($0.0 * 3600),
                         end: SampleDay.at(0, 0).addingTimeInterval($0.1 * 3600))
        }
        return DialDetail(
            id: .ring(.sleep), tone: .sleep, kicker: "Sleep · last night", title: "7 h of 8 h", value: DetailSamples.plain("7 h 00"),
            sentence: "One hour short of your need.", visuals: [.ring(fraction: 0.88, target: nil), .stages(segments)],
            visualSummary: "Sleep ring 88 percent full. Hypnogram from 11 PM to 6 AM, half an hour of it with no stage.",
            rows: [LabeledValue(id: "need", label: "Need", value: DetailSamples.est("8 h 00")),
                   LabeledValue(id: "debt", label: "Sleep debt", value: DetailSamples.est("1 h 00"))],
            actions: [ActionState(id: "night", title: "Last night ›", intent: .openNight(nil)),
                      ActionState(id: "tonight", title: "Tonight ›", intent: .openTonight)])
    }()

    static let stress = DialDetail(
        id: .ring(.stress), kicker: "Body arousal · today", title: "No score yet",
        value: .blank(reason: "No body-arousal score yet today.", receipt: nil),
        visuals: [.ring(fraction: nil, target: nil)], visualSummary: "Body arousal ring, no score yet.",
        blankReason: "Body arousal needs two hours of daytime heart rate first.",
        actions: [ActionState(id: "explore", title: "Body arousal in Explore ›", intent: .openMetric(key: "stress", variant: nil))])

    static let vape: DialDetail = {
        let at = SampleDay.at(19, 0)
        let hr = (-10...10).map { m in TimedValue(at: at.addingTimeInterval(Double(m) * 60), value: m < 0 ? 70 : 76) }
        return DialDetail(
            id: .mark(.vape, at: at), tone: .body, kicker: "Vape · \(DetailSamples.time(19, 0))", title: "Vape hit",
            sentence: "Detected, not confirmed.",
            visuals: [.hrAround(hr, at: at, before: 70, after: 76)],
            visualSummary: "Heart rate around the hit: 70 before, 76 after, estimate.",
            rows: [LabeledValue(id: "hr", label: "HR change after this hit", value: DetailSamples.est("+6", "bpm"),
                                caption: "(estimate)"),
                   LabeledValue(id: "count", label: "Hits today", value: DetailSamples.plain("3"))],
            itemsTitle: "Today's hits",
            items: [DialDetailItem(id: "v0", title: DetailSamples.time(9, 0), detail: "confirmed"),
                    DialDetailItem(id: "v1", title: DetailSamples.time(13, 30), detail: "confirmed"),
                    DialDetailItem(id: "v2", title: DetailSamples.time(19, 0), detail: "detected, not confirmed", isSelected: true)],
            actions: [ActionState(id: "yes", title: "Yes, that was a hit", intent: .confirmDetected(id: "v2", accepted: true)),
                      ActionState(id: "no", title: "No", intent: .confirmDetected(id: "v2", accepted: false)),
                      ActionState(id: "log", title: "Vape log ›", intent: .openLogItem(.vape))])
    }()

    static let medication: DialDetail = {
        let dose = SampleDay.at(7, 30)
        let midnight: Date = SampleDay.at(0, 0)
        var curve: [TimedValue] = []
        for step in 0...24 {
            let h = 7.5 + Double(step) * 0.5
            let level: Double = h < 10.5 ? (h - 7.5) / 3.0 * 10.0 : 10.0 * exp(-(h - 10.5) / 6.0)
            curve.append(TimedValue(at: midnight.addingTimeInterval(h * 3600.0), value: level))
        }
        return DialDetail(
            id: .mark(.medication, at: dose), tone: .ink, kicker: "Medication · \(DetailSamples.time(7, 30))", title: "Medication 20 mg",
            sentence: "About half of the peak level is left now.",
            visuals: [.curve(curve, window: DialSpan(start: SampleDay.at(9, 30), end: SampleDay.at(12, 30)), marks: [dose],
                             unit: "relative level")],
            visualSummary: "Level rises from the dose at 7:30 AM to a peak at 10:30 AM, then falls.",
            rows: [LabeledValue(id: "now", label: "Level now", value: DetailSamples.est("5")),
                   LabeledValue(id: "peak", label: "Peak", value: DetailSamples.plain(DetailSamples.time(10, 30))),
                   LabeledValue(id: "hr", label: "HR effect", value: DetailSamples.est("+4", "bpm"), caption: "(estimate)"),
                   LabeledValue(id: "stress", label: "Body arousal effect",
                                value: .blank(reason: "Body arousal has no times yet: it is a day score, so its change after a dose can't be shown.",
                                              receipt: nil))],
            actions: [ActionState(id: "log", title: "Medication log ›", intent: .openLogItem(.medication))])
    }()

    static let rings = [strain, recovery, sleep, stress]
}

private struct DialDetailPreviewHost: View {
    @State private var detail: DialDetail
    let siblings: [DialDetail]
    let theme: ThemeName

    init(_ detail: DialDetail, siblings: [DialDetail] = [], theme: ThemeName) {
        _detail = State(initialValue: detail)
        self.siblings = siblings
        self.theme = theme
    }

    var body: some View {
        MGBackground()
            .ignoresSafeArea()
            .sheet(isPresented: .constant(true)) {
                DialDetailSheet(detail: detail, siblings: siblings, select: { target in
                    if let d = siblings.first(where: { $0.id == target }) { detail = d }
                })
                .mgTheme(theme)
                .environment(\.mgNow, SampleDay.at(19, 30))
                .environment(\.mgSend, { intent in print("Detail intent:", intent) })
            }
            .mgTheme(theme)
    }
}

#Preview("Strain ring · target · 3 workouts · Day") {
    DialDetailPreviewHost(DetailSamples.strain, siblings: DetailSamples.rings, theme: .cream)
}
#Preview("Strain ring · Night") {
    DialDetailPreviewHost(DetailSamples.strain, siblings: DetailSamples.rings, theme: .emerald)
}
#Preview("Vape hit · HR around · Yes / No · Day") { DialDetailPreviewHost(DetailSamples.vape, theme: .cream) }
#Preview("Vape hit · Night") { DialDetailPreviewHost(DetailSamples.vape, theme: .emerald) }
#Preview("Medication · curve · blank stress · Day") { DialDetailPreviewHost(DetailSamples.medication, theme: .cream) }
#Preview("Medication · Night") { DialDetailPreviewHost(DetailSamples.medication, theme: .emerald) }
#Preview("Sleep · stages · Day") {
    DialDetailPreviewHost(DetailSamples.sleep, siblings: DetailSamples.rings, theme: .cream)
}
#Preview("Sleep · Night") {
    DialDetailPreviewHost(DetailSamples.sleep, siblings: DetailSamples.rings, theme: .emerald)
}
#Preview("Blank stress ring · Day") {
    DialDetailPreviewHost(DetailSamples.stress, siblings: DetailSamples.rings, theme: .cream)
}
#Preview("Blank stress ring · Night") {
    DialDetailPreviewHost(DetailSamples.stress, siblings: DetailSamples.rings, theme: .emerald)
}
#endif
