import Foundation
import MGDomain

/// Everything the context engine reads (ARCHITECTURE §4.7, frozen field names). The caller fills it from the store,
/// the strap link, the sync engine and settings; the engine never reads a clock itself.
public struct ContextInputs: Sendable {
    public var now: Date
    /// Its time zone decides wall-clock placement (bedtime 22:30, kicker date).
    public var calendar: Calendar
    /// Most recent main-sleep wake from ALG-030 (may be yesterday's; the engine decides if it is stale).
    public var detectedWake: Date?
    /// Any instant whose time of day is the 14-day median wake.
    public var medianWake14: Date?
    /// "Must be up by" (hour, minute) for the coming morning; nil until Mo fills it (BRIEF default 3).
    public var latestWakeSetting: DateComponents?
    /// ALG-115 bedtime for tonight.
    public var recommendedBedtime: Date?
    /// Any instant whose time of day is the 14-day median sleep onset.
    public var medianOnset14: Date?
    public var strap: StrapStatus
    public var workout: WorkoutSession?
    public var nap: NapSession?
    public var history: HistoryProgress?
    public var sync: SyncStatus
    public var alerts: [AlertInfo]
    /// Every question waiting (see `PendingQuestion` factories). The morning check-in is added by the engine.
    public var pending: [PendingQuestion]
    /// Peeks already shown this wake day (cap 4, UX §5).
    public var peeksShownToday: Int
    public var morningCheckinAnswered: Bool
    /// Consecutive swipe-aways per kind (reset by an answer).
    public var swipeAwayStreak: [PeekKindKey: Int]
    public var themePreference: ThemePreference

    public init(now: Date, calendar: Calendar, detectedWake: Date? = nil, medianWake14: Date? = nil,
                latestWakeSetting: DateComponents? = nil, recommendedBedtime: Date? = nil, medianOnset14: Date? = nil,
                strap: StrapStatus, workout: WorkoutSession? = nil, nap: NapSession? = nil,
                history: HistoryProgress? = nil, sync: SyncStatus, alerts: [AlertInfo] = [],
                pending: [PendingQuestion] = [], peeksShownToday: Int = 0, morningCheckinAnswered: Bool = false,
                swipeAwayStreak: [PeekKindKey: Int] = [:], themePreference: ThemePreference = .followDay) {
        self.now = now
        self.calendar = calendar
        self.detectedWake = detectedWake
        self.medianWake14 = medianWake14
        self.latestWakeSetting = latestWakeSetting
        self.recommendedBedtime = recommendedBedtime
        self.medianOnset14 = medianOnset14
        self.strap = strap
        self.workout = workout
        self.nap = nap
        self.history = history
        self.sync = sync
        self.alerts = alerts
        self.pending = pending
        self.peeksShownToday = peeksShownToday
        self.morningCheckinAnswered = morningCheckinAnswered
        self.swipeAwayStreak = swipeAwayStreak
        self.themePreference = themePreference
    }
}

/// What the screens are built from (ARCHITECTURE §4.7, frozen field names + `deferredQuestions`, approved by main).
public struct DayContext: Equatable, Sendable {
    public var anchors: PhaseAnchors
    public var phase: DayPhase
    public var theme: ThemeName
    public var justWoke: Bool
    /// Sorted by UX §4.2 priority: alert > workoutLive > napTimer > strapOff > historyDownloading > workoutJustEnded >
    /// dataWaiting. The card shows the first; the rest are "+n more".
    public var moments: [Moment]
    /// The one question to peek now (UX §5 priority), or nil.
    public var peek: PeekKind?
    /// True during a live workout, Night, Late night, or once 4 peeks were shown today.
    public var peeksHeld: Bool
    /// Next phase boundary or expiry after `now`, for scheduling a refresh. Always later than `now`.
    public var nextChange: Date
    /// Swiped-away questions still open: the header's "1 question" chip, highest priority first.
    public var deferredQuestions: [PeekKind]

    public init(anchors: PhaseAnchors, phase: DayPhase, theme: ThemeName, justWoke: Bool, moments: [Moment],
                peek: PeekKind?, peeksHeld: Bool, nextChange: Date, deferredQuestions: [PeekKind] = []) {
        self.anchors = anchors
        self.phase = phase
        self.theme = theme
        self.justWoke = justWoke
        self.moments = moments
        self.peek = peek
        self.peeksHeld = peeksHeld
        self.nextChange = nextChange
        self.deferredQuestions = deferredQuestions
    }

    /// The phase start instants of this wake day.
    public var boundaries: PhaseBoundaries { PhaseClock.boundaries(anchors) }
}

/// UX §2 phases + §4.2 moments + §5 peeks, as one pure function.
public enum ContextEngine {
    /// UX §5: at most 4 peeks a day.
    public static let peekDailyCap = 4
    /// UX §4.2: the workout summary card stays 2 h unless confirmed.
    public static let workoutJustEndedFor: TimeInterval = 2 * 3600
    /// UX §4.2 / PLAN §2: the "data waiting" card appears when offline and unsynced for more than 6 h.
    public static let dataWaitingAfter: TimeInterval = 6 * 3600
    /// UX §5: two swipe-aways in a row → that kind asks half as often and only when its model is unsure.
    public static let swipeAwayLimit = 2

    public static func evaluate(_ inputs: ContextInputs) -> DayContext {
        let now = inputs.now
        let cal = inputs.calendar
        let anchors = PhaseClock.anchors(now: now, calendar: cal, detectedWake: inputs.detectedWake,
                                         medianWake14: inputs.medianWake14,
                                         latestWakeSetting: inputs.latestWakeSetting,
                                         recommendedBedtime: inputs.recommendedBedtime,
                                         medianOnset14: inputs.medianOnset14)
        let bounds = PhaseClock.boundaries(anchors)
        let phase = bounds.phase(at: now)
        let theme = PhaseClock.theme(at: now, phase: phase, boundaries: bounds, preference: inputs.themePreference)
        let justWoke = PhaseClock.isJustWoke(now: now, phase: phase, wake: anchors.wake,
                                             checkinAnswered: inputs.morningCheckinAnswered)

        let live = Self.moments(inputs)
        let workoutLive = live.contains { $0.kind == .workoutLive }
        let held = workoutLive || phase == .night || phase == .lateNight || inputs.peeksShownToday >= peekDailyCap

        let all = Self.questions(inputs, anchors: anchors, phase: phase, justWoke: justWoke)
        let active = all.filter { $0.isActive(at: now) }
        let deferred = active.filter { $0.deferredAt != nil }.sorted(by: peekOrder).map(\.kind)
        let eligible = active.filter { q in
            guard q.deferredAt == nil else { return false }
            // Sundown: "none new (pending ones may stay)" (UX §4.1).
            if phase == .sundown, q.availableFrom >= bounds.sundown { return false }
            return passesSwipeRule(q, streak: inputs.swipeAwayStreak[q.kind.key] ?? 0)
        }
        let peek = held ? nil : eligible.sorted(by: peekOrder).first?.kind

        let next = Self.nextChange(inputs, anchors: anchors, bounds: bounds, justWoke: justWoke, questions: all)
        return DayContext(anchors: anchors, phase: phase, theme: theme, justWoke: justWoke, moments: live,
                          peek: peek, peeksHeld: held, nextChange: next, deferredQuestions: deferred)
    }

    // MARK: Moments

    /// All live states, sorted by UX §4.2 priority (alerts newest first within their kind).
    public static func moments(_ i: ContextInputs) -> [Moment] {
        let now = i.now
        var out: [Moment] = []
        for a in i.alerts.filter({ !$0.seen }).sorted(by: { $0.raisedAt > $1.raisedAt }) {
            out.append(.alert(a))
        }
        if let w = i.workout, w.end == nil, w.start <= now {
            out.append(.workoutLive(w))
        }
        if let n = i.nap, n.trigger == .manual, n.end == nil, n.start <= now {
            out.append(.napTimer(n))
        }
        if i.strap.link != .notPaired, let off = i.strap.offWristSince, off <= now {
            out.append(.strapOff(since: off))
        }
        if let h = i.history {
            out.append(.historyDownloading(h))
        }
        if let w = i.workout, let end = w.end, now >= end, now < end.addingTimeInterval(workoutJustEndedFor) {
            // A detected workout's card goes once it is answered; a manual one has nothing to confirm (UX §4.2).
            let answered = w.trigger == .detected && w.confirmed != nil
            if !answered { out.append(.workoutJustEnded(w)) }
        }
        if let since = dataWaitingSince(i.sync), now.timeIntervalSince(since) > dataWaitingAfter {
            out.append(.dataWaiting(since: since))
        }
        // Stable sort: equal kinds keep their order above.
        return out.enumerated().sorted { l, r in
            l.element.kind == r.element.kind ? l.offset < r.offset : l.element.kind < r.element.kind
        }.map(\.element)
    }

    /// Last successful sync while offline; nil when online, not set up, or never synced (then only the status chip).
    static func dataWaitingSince(_ s: SyncStatus) -> Date? {
        guard s.state == .offline else { return nil }
        return s.lastSynced
    }

    // MARK: Peeks

    /// The caller's questions plus the morning check-in the engine owns (UX §5.1).
    static func questions(_ i: ContextInputs, anchors: PhaseAnchors, phase: DayPhase, justWoke: Bool) -> [PendingQuestion] {
        var qs = i.pending.filter { $0.kind.key != .morningCheckin }
        if justWoke, !i.morningCheckinAnswered {
            let day = i.calendar.ordinality(of: .day, in: .era, for: anchors.wake) ?? 0
            var checkin = PendingQuestion.morningCheckin(wake: anchors.wake, occurrence: day)
            // A caller-held copy only carries the swipe-away.
            if let held = i.pending.first(where: { $0.kind.key == .morningCheckin }) {
                checkin.deferredAt = held.deferredAt
            }
            qs.append(checkin)
        }
        return qs
    }

    /// UX §5: after `swipeAwayLimit` swipe-aways in a row a kind asks half as often (even occurrences) and only when its
    /// model is unsure (kinds without a model count as unsure).
    static func passesSwipeRule(_ q: PendingQuestion, streak: Int) -> Bool {
        guard streak >= swipeAwayLimit else { return true }
        return (q.modelUnsure ?? true) && q.occurrence % 2 == 0
    }

    static func peekOrder(_ a: PendingQuestion, _ b: PendingQuestion) -> Bool {
        if a.kind.key != b.kind.key { return a.kind.key < b.kind.key }
        if a.availableFrom != b.availableFrom { return a.availableFrom < b.availableFrom }
        return a.id < b.id
    }

    // MARK: Next change

    static func nextChange(_ i: ContextInputs, anchors: PhaseAnchors, bounds: PhaseBoundaries, justWoke: Bool,
                           questions: [PendingQuestion]) -> Date {
        let now = i.now
        var c: [Date] = bounds.changeInstants
        c.append(PhaseClock.nextAnchorChange(now: now, calendar: i.calendar, anchors: anchors,
                                             detectedWake: i.detectedWake, medianWake14: i.medianWake14,
                                             latestWakeSetting: i.latestWakeSetting))
        if justWoke {
            c.append(PhaseClock.justWokeEnds(wake: anchors.wake, checkinAnswered: i.morningCheckinAnswered))
        }
        for q in questions {
            c.append(q.availableFrom)
            c.append(q.expiresAt)
        }
        if let end = i.workout?.end { c.append(end.addingTimeInterval(workoutJustEndedFor)) }
        if let n = i.nap, n.end == nil, let m = n.plannedMinutes {
            c.append(n.start.addingTimeInterval(TimeInterval(m) * 60))
        }
        if let since = dataWaitingSince(i.sync) { c.append(since.addingTimeInterval(dataWaitingAfter)) }
        let future = c.filter { $0 > now }
        return future.min() ?? now.addingTimeInterval(60)
    }
}
