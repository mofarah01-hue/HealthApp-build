#if DEBUG
import SwiftUI
import MGContext
import MGDesign
import MGDomain

// Xcode previews of Today for every UX phase scenario (MGContext `PreviewScenario`: the prototype's ten), plus the
// cases the acceptance names: the 0.6 evening screen in Day and Night (moment card, a 7-item Today so far, Now rows
// with a Start pill and an opened row, the quick log), the same at accessibility XL text, Bluetooth off with
// "Open Settings" (T141), blank-with-reason, the wear-location question, the deferred-question chip and the
// PC-waiting moment. All values are invented SAMPLE values (`sample: true`), so the SAMPLE banner shows on every
// preview. Taps print their intent to the console.

struct TodayPreviewHost: View {
    let state: TodayState

    init(_ scenario: PreviewScenario) {
        self.state = TodayState.preview(for: scenario)
    }

    init(state: TodayState) {
        self.state = state
    }

    var body: some View {
        TodayView(state: state) { intent in print("Today intent:", intent) }
    }
}

/// The 0.6 evening screen (P05): what Mo sees at 7:41 PM with the strap history still coming in.
enum TodayEveningPreview {
    static func r(_ on: ComputedOn, _ tier: Tier, _ h: Int, _ m: Int, _ method: String? = nil) -> Receipt {
        SampleDay.receipt(on, tier, h, m, method: method)
    }

    static func v(_ text: String, _ unit: String? = nil, _ style: DisplayValue.Style = .plain,
                  _ receipt: Receipt = TodayEveningPreview.r(.phone, .high, 19, 41)) -> DisplayValue {
        SampleDay.value(text, unit, receipt, style)
    }

    static let todaySoFar = StripState(kind: .todaySoFar, title: "Today so far", summary: "since 12:00 AM", items: [
        LabeledValue(id: "strain", label: "Strain", value: v("9.4", "/21", .estimate(nil)), caption: "day so far",
                     intent: .openMetric(key: "strain", variant: nil)),
        LabeledValue(id: "stress", label: "Body arousal",
                     value: .blank(reason: "Not scored yet — it needs 14 days of resting heart rate and HRV to compare with.",
                                   receipt: nil),
                     caption: "day so far", intent: .openMetric(key: "stress", variant: nil)),
        LabeledValue(id: "hrNow", label: "Heart rate", value: .blank(reason: "Strap off since 3:29 AM.", receipt: nil),
                     caption: "now", intent: .openLive),
        LabeledValue(id: "hrAvg", label: "Average HR", value: v("76", "bpm"), caption: "worn minutes",
                     intent: .openMetric(key: "hr_avg", variant: nil)),
        LabeledValue(id: "ticks", label: "Step ticks", value: v("105", nil, .strapRaw, r(.strap, .strap, 19, 41)),
                     caption: "uncalibrated, not steps", intent: .openMetric(key: "steps", variant: nil)),
        LabeledValue(id: "caff", label: "Caffeine", value: v("0", "mg"), caption: "log", intent: .openLogItem(.caffeine)),
        LabeledValue(id: "vape", label: "Vape", value: v("3"), caption: "log + tap", intent: .openLogItem(.vape)),
    ])

    static let lastNight = StripState(kind: .lastNight, title: "Last night", summary: "7 h 08 · readiness 82", items: [
        LabeledValue(id: "slept", label: "Slept", value: v("7 h 08")),
        LabeledValue(id: "rhr", label: "Resting HR", value: v("52", "bpm")),
        LabeledValue(id: "hrv", label: "HRV", value: v("58", "ms")),
        LabeledValue(id: "resp", label: "Breathing", value: v("14.2", "/min", .estimate(nil))),
        LabeledValue(id: "spo2", label: "SpO₂ byte", value: v("97", "≈ 97 % estimate", .strapRaw, r(.strap, .strap, 6, 58)),
                     caption: "estimate — not checked against WHOOP · 2 of 5 nights"),
        LabeledValue(id: "temp", label: "Skin temp", value: v("above your range")),
    ], recoveryLine: "Recovery this morning: mostly · 82 of 100 · HRV in your range", isCollapsed: true)

    static let rows: [NowRowState] = [
        NowRowState(id: "recovery", badge: "R", tone: .focus, title: "Recovery this morning: learning your normal",
                    detail: "5 methods", receipt: r(.phone, .estimate, 6, 58), isOpen: true,
                    expansion: NowRowExpansion(lines: ["readiness 82 of 100, HRV in your range.",
                                                       "HRV 58 ms and resting HR 52 bpm sit inside your 28-day band."],
                                               chart: [52, 55, nil, 49, 57, 60, 58, 54, 58],
                                               chartCaption: "HRV, last 9 nights",
                                               actions: [ActionState(id: "open", title: "Open in Explore ›",
                                                                     intent: .openMetric(key: "recovery", variant: nil))],
                                               methods: .preview)),
        NowRowState(id: "breathe", badge: "~", tone: .focus, title: "Wind down: breathe 5 min",
                    detail: "pacer at 6 /min · coherence shown after", receipt: nil, receiptNote: "ALG-104",
                    button: ActionState(id: "start", title: "Start", intent: .startBreathe)),
    ]

    static let alarm = NowRowState(id: "alarm", badge: "A", tone: .sleep, title: "No alarm in the next 24 h",
                                   detail: "Fajr, wake and your own alarms are on the Alarms page", receipt: nil,
                                   button: ActionState(id: "alarms", title: "Alarms ›", intent: .alarms(.open)))

    static let battery = NowRowState(id: "battery", badge: "B", tone: .ink2, title: "Strap battery 74 %",
                                     detail: "≈ 5.3 days left (empty ~Sun), calibrating.",
                                     receipt: r(.phone, .estimate, 19, 41, "BatteryEstimator, 72 h"),
                                     button: ActionState(id: "strap", title: "Strap ›", intent: .openStrapSync))

    static func state(_ theme: ThemeName) -> TodayState {
        var s = TodayState.preview(for: .sundown)
        s.theme = theme
        s.peek = nil
        s.header = HeaderState(kicker: "SUN 11 OCT · EVENING · WOKE 6:52 AM", title: "Sunday",
                               status: StatusChipState(strapTone: .good, strapText: "MG 74 % · 5 d left",
                                                       syncTone: .good, syncText: "synced 7:41 PM"),
                               questionChip: nil, alarmChip: "6:30 AM")
        s.moment = MomentViewState(kind: .historyDownloading, title: "Fetching strap history", trailing: "3 %",
                                   line: "8 min of 4 h 12", detail: nil, actionTitle: nil, action: nil,
                                   progress: 0.03, tone: .sleep, extraCount: 0)
        s.verdict = VerdictState(headline: "Past your bedtime.", sentence: "No wake time set for tomorrow.",
                                 receipt: r(.phone, .estimate, 19, 41, "ALG-160 readiness"),
                                 receiptNote: "readiness 82 of 100, HRV in your range")
        s.methods = nil
        s.modelStatus = ActionState(id: "models", title: "81 models not running ›", intent: .openModelStatus)
        s.quickLog.confirmCount = 1
        s.cards = [.verdict, .strip(todaySoFar), .dial, .now(rows), .row(alarm), .row(battery), .strip(lastNight),
                   .quickLog]
        return s
    }
}

#Preview("0.6 Evening · Night") { TodayPreviewHost(state: TodayEveningPreview.state(.emerald)) }
#Preview("0.6 Evening · Day") { TodayPreviewHost(state: TodayEveningPreview.state(.cream)) }

#Preview("0.6 Evening · Night · accessibility XL") {
    TodayPreviewHost(state: TodayEveningPreview.state(.emerald))
        .environment(\.dynamicTypeSize, .accessibility3)
}

#Preview("0.6 Evening · Day · accessibility XL") {
    TodayPreviewHost(state: TodayEveningPreview.state(.cream))
        .environment(\.dynamicTypeSize, .accessibility3)
}

/// T141: Bluetooth off — the chip says so and "Open Settings" sits beside it.
#Preview("Bluetooth off · Open Settings (T141)") {
    var s = TodayEveningPreview.state(.emerald)
    s.moment = nil
    s.header.status = StatusChipState(strapTone: .bad, strapText: "Bluetooth off", syncTone: .neutral,
                                      syncText: "synced 7:41 PM", showOpenSettings: true)
    return TodayPreviewHost(state: s)
}

#Preview("1 · Just woke 07:05 · cream · check-in peek") { TodayPreviewHost(.woke) }
#Preview("2 · Mid-morning 09:40 · cream · 1 to confirm") { TodayPreviewHost(.morning) }
#Preview("3 · After lunch 13:50 · dip · KSS peek") { TodayPreviewHost(.lunch) }
#Preview("4 · Nap detected 14:40 · nap peek") { TodayPreviewHost(.nap) }
#Preview("5 · Strap off 15:40 · moment card") { TodayPreviewHost(.off) }
#Preview("6 · Workout live 17:45 · golden · peeks held") { TodayPreviewHost(.wlive) }
#Preview("7 · Workout just ended 18:25 · confirm peek") { TodayPreviewHost(.wend) }
#Preview("8 · Sundown 20:05 · Satin Emerald") { TodayPreviewHost(.sundown) }
#Preview("9 · Bedtime 22:10 · Tonight open") { TodayPreviewHost(.night) }
#Preview("10 · Late night 00:40 · Emerald low") { TodayPreviewHost(.late) }

/// UX §13 "Too few clean beats": the verdict says why, HRV and breathing are "—" + reason, the recovery group can't run.
#Preview("Blank with reasons · noisy night") {
    var s = TodayState.preview(for: .woke)
    let r = Receipt(computedOn: .phone, tier: .relative, at: SampleDay.at(6, 58), method: "ALG-160 readiness")
    s.verdict = VerdictState(headline: "Too little to say.",
                             sentence: "HRV and breathing are missing — 38 % of beats were noisy 2:10–4:00 AM. Resting HR and sleep look normal.",
                             receipt: r, receiptNote: "ALG-160 needs HRV")
    s.methods = nil
    s.primaryStrip.items = s.primaryStrip.items.map { item in
        guard item.id == "hrv" || item.id == "resp" else { return item }
        var copy = item
        copy.value = .blank(reason: item.id == "hrv" ? "38 % of beats noisy" : "too little clean signal",
                            receipt: Receipt(computedOn: .phone, tier: .high, at: SampleDay.at(6, 58)))
        return copy
    }
    s.primaryStrip.summary = "2 missing"
    s.cards = TodayState(sample: s.sample, theme: s.theme, header: s.header, moment: s.moment, verdict: s.verdict,
                         methods: s.methods, dial: s.dial, nowRows: s.nowRows, primaryStrip: s.primaryStrip,
                         secondaryStrip: s.secondaryStrip, quickLog: s.quickLog, peek: s.peek, footer: s.footer).cards
    return TodayPreviewHost(state: s)
}

/// UX §4.2 "Strap back on": the wear-location question, "same as before" as the big default.
#Preview("Strap back on · wear question") {
    var s = TodayState.preview(for: .off)
    s.moment = nil
    s.peek = .previewWearLocation
    return TodayPreviewHost(state: s)
}

/// UX §5: a swiped-away question waits as the header chip; no peek.
#Preview("Deferred question chip") {
    var s = TodayState.preview(for: .woke)
    s.peek = nil
    s.header.questionChip = "1 question"
    return TodayPreviewHost(state: s)
}

/// UX §4.2 "Data waiting to sync" (7 h, PC asleep) with the amber status chip.
#Preview("PC waiting 7 h · moment") {
    var s = TodayState.preview(for: .morning)
    s.header.status = StatusChipState(strapTone: .good, strapText: "MG 79 %", syncTone: .warn, syncText: "7 h unsynced")
    s.moment = MomentViewState(kind: .dataWaiting, title: "Waiting for the PC", trailing: "7 h · 2.1 MB",
                               line: "Tailscale is off or the PC is asleep.",
                               detail: "Everything is safe on the phone; PC results show their date until it syncs.",
                               actionTitle: "Open Tailscale", action: .openTailscale,
                               secondaryActionTitle: "Later", secondaryAction: .dismissMoment(.dataWaiting),
                               tone: .caffeine, extraCount: 0)
    return TodayPreviewHost(state: s)
}

#Preview("Largest text · mid-morning") {
    TodayPreviewHost(.morning)
        .environment(\.dynamicTypeSize, .accessibility3)
}

#Preview("Largest text · sundown") {
    TodayPreviewHost(.sundown)
        .environment(\.dynamicTypeSize, .accessibility3)
}
#endif
