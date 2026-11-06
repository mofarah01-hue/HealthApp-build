import Foundation

/// T9878 (b-9): the plain-English "what is this / how is it worked out / when is it blank" notes that open on a metric's
/// screen for the sleep-timing family: chronotype, sleep need, sleep debt and the recommended bedtime. Removed this round
/// (D-SLEEP-WALK-1, no value): sleep cycles, grogginess, restless / rough night; none is explained here.
/// Every sentence restates what the algorithm file says (ALG-116 / ALG-115 v2); the numbers are the algorithms' own.
enum MetricExplainers {
    static let free = "A free night is a night with no \"must be up by\" set for the next morning, so nothing cut it "
        + "short (an alarm night is not free)."

    static let notes: [String: (title: String, lines: [String])] = [
        "chronotype_msf_sc": ("What chronotype (MSFsc) is", [
            "The middle of your sleep on free nights, as a clock time, corrected for sleep debt: a later time means a "
                + "later body clock. It is the Munich Chronotype Questionnaire's MSFsc (Roenneberg 2004), worked out from "
                + "your strap-measured nights instead of from answers to a questionnaire.",
            "Mid-sleep is the onset plus half the night's length. MSF is its average over free nights. If you sleep "
                + "longer on free nights than on average, MSFsc moves earlier by half the extra sleep: that is the debt "
                + "correction. \(MetricExplainers.free)",
            "Blank, with how far along it is, until there are 14 nights recorded and at least 2 of them free.",
        ]),
        "sleep_need": ("What sleep need is", [
            "How long you sleep when nothing limits you: the average sleep time on your free nights over the last 28 "
                + "nights (the Munich questionnaire's free-day sleep, Roenneberg 2003; Kitamura 2016). \(MetricExplainers.free)",
            "It needs 7 free nights before it shows a number; before that the row says how many it has. There is no "
                + "population default such as 8 hours. Tonight's figure also takes off the credit for a nap.",
        ]),
        "sleep_debt": ("What sleep debt is", [
            "How far short of your sleep need you have fallen over the last 14 nights, added up (Van Dongen 2003: "
                + "cumulative restriction). A night above your need pays some back; the total never goes below zero.",
            "It needs 7 of the last 14 nights to show a number, and it needs your sleep need, which needs 7 free "
                + "nights (see sleep need). Until then the row says which one is missing.",
        ]),
        "bedtime_recommended": ("What the recommended bedtime is", [
            "The time to get into bed so that your sleep need fits before the wake time you aim for (your \"must be up "
                + "by\" for tomorrow, else your typical wake). Time in bed = your sleep need divided by your usual sleep "
                + "efficiency (the share of bed time you actually sleep, from your last nights); bedtime = the wake time "
                + "minus that.",
            "It needs 3 nights with a sleep efficiency. It is a plan from your own nights, not a medical recommendation.",
        ]),
    ]
}
