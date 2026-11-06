import Foundation
import MGDomain

/// Today, top to bottom (UX §3.2). Built by WP-23's presenter from `DayContext` + data; rendered by WP-07.
public struct TodayState: Equatable, Sendable {
    /// SAMPLE mode: the screen shows `SampleBanner`.
    public var sample: Bool
    public var theme: ThemeName
    public var header: HeaderState
    /// Only when a state is live (UX §4.2).
    public var moment: MomentViewState?
    public var verdict: VerdictState
    /// Only when the verdict's metric has a comparison group (UX §11).
    public var methods: MethodsStripState?
    public var dial: DialState
    /// At most 3, phase-ranked (UX §4.1).
    public var nowRows: [NowRowState]
    /// "Last night" until late afternoon, then "Today so far".
    public var primaryStrip: StripState
    /// The other strip, collapsed below.
    public var secondaryStrip: StripState?
    public var quickLog: QuickLogState
    /// One question at a time (UX §5).
    public var peek: PeekState?
    public var footer: FooterState
    /// "2 models not running · 54 not built or blocked ›" under the verdict → Model status (Mo 2026-10-11); nil when
    /// every model runs.
    public var modelStatus: ActionState?
    /// What Today draws between the header (with the moment card) and the footer, in Mo's order (Settings › Front
    /// page, tracker #34). nil at init = the order before customisation: verdict, dial, Now rows, the two strips,
    /// quick log.
    public var cards: [TodayCard]

    public init(sample: Bool, theme: ThemeName, header: HeaderState, moment: MomentViewState?, verdict: VerdictState,
                methods: MethodsStripState?, dial: DialState, nowRows: [NowRowState], primaryStrip: StripState,
                secondaryStrip: StripState?, quickLog: QuickLogState, peek: PeekState?, footer: FooterState,
                modelStatus: ActionState? = nil, cards: [TodayCard]? = nil) {
        self.sample = sample
        self.theme = theme
        self.header = header
        self.moment = moment
        self.verdict = verdict
        self.methods = methods
        self.dial = dial
        self.nowRows = nowRows
        self.primaryStrip = primaryStrip
        self.secondaryStrip = secondaryStrip
        self.quickLog = quickLog
        self.peek = peek
        self.footer = footer
        self.modelStatus = modelStatus
        self.cards = cards ?? [.verdict, .dial, .now(nowRows), .strip(primaryStrip)]
            + (secondaryStrip.map { [TodayCard.strip($0)] } ?? []) + [.quickLog]
    }
}

/// Kicker, weekday title, status chip, optional "1 question" chip (UX §3.2 row 1).
public struct HeaderState: Equatable, Sendable {
    /// "SUN 11 OCT · MORNING · WOKE 06:52" (`MGFormat.kicker`).
    public var kicker: String
    /// "Sunday".
    public var title: String
    public var status: StatusChipState
    /// "1 question" when a peek was swiped away and is still open; tap → `.openDeferredQuestion`.
    public var questionChip: String?
    /// The next alarm within 24 h ("Fajr 05:32"); tap → `.alarms(.open)` (added 2026-10-11).
    public var alarmChip: String?

    public init(kicker: String, title: String, status: StatusChipState, questionChip: String?, alarmChip: String? = nil) {
        self.kicker = kicker
        self.title = title
        self.status = status
        self.questionChip = questionChip
        self.alarmChip = alarmChip
    }
}

/// Strap dot + battery + sync state (UX §3.2): green "synced 09:40" / amber "7 h unsynced" / grey "PC not set up".
public struct StatusChipState: Equatable, Sendable {
    public var strapTone: StatusTone
    /// "MG 79 %" · "MG off wrist" · "No strap".
    public var strapText: String
    public var syncTone: StatusTone
    public var syncText: String
    public var intent: UIIntent
    /// T141: Bluetooth off / not allowed — show the "Open Settings" button beside the chip (the pairing sheet's
    /// camera-denied pattern); false for every other cause (no strap, searching, off wrist, …).
    public var showOpenSettings: Bool

    public init(strapTone: StatusTone, strapText: String, syncTone: StatusTone, syncText: String,
                intent: UIIntent = .openStrapSync, showOpenSettings: Bool = false) {
        self.strapTone = strapTone
        self.strapText = strapText
        self.syncTone = syncTone
        self.syncText = syncText
        self.intent = intent
        self.showOpenSettings = showOpenSettings
    }

    public var accessibilityLabel: String { "\(strapText), \(syncText)" }
}

/// The Moment card (UX §4.2, §5): one live state, one line, one action; never a question.
public struct MomentViewState: Equatable, Sendable {
    public var kind: MomentKind
    /// "Strap off · since 15:12".
    public var title: String
    /// Right side of the title row: "28 min", "62 %".
    public var trailing: String?
    /// "Nothing records while it's off."
    public var line: String
    public var detail: String?
    public var actionTitle: String?
    public var action: UIIntent?
    public var secondaryActionTitle: String?
    public var secondaryAction: UIIntent?
    /// 0…1 (history download).
    public var progress: Double?
    /// Workout live: HR with its receipt.
    public var liveValue: DisplayValue?
    /// Workout live: last 30 s of pulse trace, newest last.
    public var trace: [Double]
    public var receipt: Receipt?
    public var tone: InkTone
    /// Other live states folded into "+n more".
    public var extraCount: Int

    public init(kind: MomentKind, title: String, trailing: String?, line: String, detail: String?,
                actionTitle: String?, action: UIIntent?, secondaryActionTitle: String? = nil,
                secondaryAction: UIIntent? = nil, progress: Double? = nil, liveValue: DisplayValue? = nil,
                trace: [Double] = [], receipt: Receipt? = nil, tone: InkTone, extraCount: Int) {
        self.kind = kind
        self.title = title
        self.trailing = trailing
        self.line = line
        self.detail = detail
        self.actionTitle = actionTitle
        self.action = action
        self.secondaryActionTitle = secondaryActionTitle
        self.secondaryAction = secondaryAction
        self.progress = progress
        self.liveValue = liveValue
        self.trace = trace
        self.receipt = receipt
        self.tone = tone
        self.extraCount = extraCount
    }
}

/// Headline + one sentence (≤ 20 words) + receipt (UX §12).
public struct VerdictState: Equatable, Sendable {
    public var headline: String
    public var sentence: String?
    public var receipt: Receipt?
    /// Free-text receipt detail when the rule coach needs more than `where · tier · when`
    /// ("4 of 5 inputs in your range (ALG-036)").
    public var receiptNote: String?
    /// One button under the verdict, when the verdict asks Mo to do something ("Pair strap"). Added 2026-10-11:
    /// the not-paired verdict said "Pair your MG to start" with nothing to tap.
    public var action: ActionState?

    public init(headline: String, sentence: String?, receipt: Receipt?, receiptNote: String? = nil,
                action: ActionState? = nil) {
        self.headline = headline
        self.sentence = sentence
        self.receipt = receipt
        self.receiptNote = receiptNote
        self.action = action
    }
}

/// A Now row: round badge, title, one-line detail, receipt, chevron; opens in place (UX §3.2 row 6).
public struct NowRowState: Equatable, Sendable, Identifiable {
    public var id: String
    /// One or two characters in the round badge ("F", "Rx", "2×").
    public var badge: String
    public var tone: InkTone
    public var title: String
    public var detail: String?
    public var receipt: Receipt?
    public var receiptNote: String?
    /// Right-side one-tap button ("Took it", "Start").
    public var button: ActionState?
    public var isOpen: Bool
    /// What opens in place; nil = no chevron.
    public var expansion: NowRowExpansion?

    public init(id: String, badge: String, tone: InkTone, title: String, detail: String?, receipt: Receipt?,
                receiptNote: String? = nil, button: ActionState? = nil, isOpen: Bool = false,
                expansion: NowRowExpansion? = nil) {
        self.id = id
        self.badge = badge
        self.tone = tone
        self.title = title
        self.detail = detail
        self.receipt = receipt
        self.receiptNote = receiptNote
        self.button = button
        self.isOpen = isOpen
        self.expansion = expansion
    }
}

/// The opened part of a Now row: a few lines, a small chart, actions ("Open in Explore"), optionally a methods strip.
public struct NowRowExpansion: Equatable, Sendable {
    public var lines: [String]
    /// Small chart values, oldest first; nil = gap.
    public var chart: [Double?]
    public var chartCaption: String?
    public var toggles: [ToggleState]
    public var actions: [ActionState]
    public var methods: MethodsStripState?
    /// T101: the caffeine row's decay-model dropdown.
    public var algorithmPanel: AlgorithmPanelState?

    public init(lines: [String] = [], chart: [Double?] = [], chartCaption: String? = nil, toggles: [ToggleState] = [],
                actions: [ActionState] = [], methods: MethodsStripState? = nil,
                algorithmPanel: AlgorithmPanelState? = nil) {
        self.lines = lines
        self.chart = chart
        self.chartCaption = chartCaption
        self.toggles = toggles
        self.actions = actions
        self.methods = methods
        self.algorithmPanel = algorithmPanel
    }
}

/// "Last night" vitals or "Today so far" (UX §3.2 row 7).
public struct StripState: Equatable, Sendable {
    public enum Kind: String, Sendable { case lastNight, todaySoFar }

    public var kind: Kind
    public var title: String
    /// "4 of 5 in your range".
    public var summary: String?
    public var items: [LabeledValue]
    /// After Morning the recovery line moves here ("Recovery this morning: mostly").
    public var recoveryLine: String?
    public var isCollapsed: Bool
    /// Sleep expanded (Mo, Nov 5 2026): the Last-night strip leads with the sleep card; a tap opens the full breakdown.
    public var sleepCard: SleepCardState?

    public init(kind: Kind, title: String, summary: String?, items: [LabeledValue], recoveryLine: String? = nil,
                isCollapsed: Bool = false, sleepCard: SleepCardState? = nil) {
        self.kind = kind
        self.title = title
        self.summary = summary
        self.items = items
        self.recoveryLine = recoveryLine
        self.isCollapsed = isCollapsed
        self.sleepCard = sleepCard
    }
}

/// Four pills + "More" + the "1 to confirm" chip (UX §3.2 row 8; the same four all day, BRIEF default 9).
public struct QuickLogState: Equatable, Sendable {
    public var pills: [QuickLogPill]
    /// Detected vape hits waiting for a yes/no (ALG-046); 0 hides the chip.
    public var confirmCount: Int
    public var moreIntent: UIIntent

    public init(pills: [QuickLogPill], confirmCount: Int, moreIntent: UIIntent = .selectTab(.log)) {
        self.pills = pills
        self.confirmCount = confirmCount
        self.moreIntent = moreIntent
    }
}

public struct QuickLogPill: Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    /// SF Symbol name.
    public var systemImage: String?
    public var intent: UIIntent

    public init(id: String, title: String, systemImage: String?, intent: UIIntent) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.intent = intent
    }
}

/// The one-question card (UX §5): headline question + one row of answers; swipe down = later.
public struct PeekState: Equatable, Sendable {
    public var kind: PeekKindKey
    public var question: String
    public var answers: [PeekAnswer]
    /// 1-based step of a two-step question (nap: label, then groggy ↔ refreshed).
    public var step: Int
    public var stepCount: Int
    /// "Edit times".
    public var secondaryTitle: String?
    public var secondaryIntent: UIIntent?

    public init(kind: PeekKindKey, question: String, answers: [PeekAnswer], step: Int = 1, stepCount: Int = 1,
                secondaryTitle: String? = nil, secondaryIntent: UIIntent? = nil) {
        self.kind = kind
        self.question = question
        self.answers = answers
        self.step = step
        self.stepCount = stepCount
        self.secondaryTitle = secondaryTitle
        self.secondaryIntent = secondaryIntent
    }
}

public struct PeekAnswer: Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    /// The meaning under a KSS number ("extremely alert").
    public var detail: String?
    /// The big default button ("Left wrist — same as before").
    public var isDefault: Bool
    public var intent: UIIntent

    public init(id: String, title: String, detail: String? = nil, isDefault: Bool = false, intent: UIIntent) {
        self.id = id
        self.title = title
        self.detail = detail
        self.isDefault = isDefault
        self.intent = intent
    }
}

/// "Everything else is in Explore ›".
public struct FooterState: Equatable, Sendable {
    public var text: String
    public var intent: UIIntent

    public init(text: String = "Everything else is in Explore ›", intent: UIIntent = .selectTab(.explore)) {
        self.text = text
        self.intent = intent
    }
}
