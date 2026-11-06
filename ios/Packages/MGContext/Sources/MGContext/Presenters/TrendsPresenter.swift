import Foundation
import MGDomain

/// Explore › Trends (r9s, D-TRENDS-1, D-POP-PRIOR): six relative trends, each a card that says what it tracks, how it is backed
/// (paper, theory or both, with the source), what the base and enhanced tiers read (D-ALG-TIERS), the population start and
/// 'yours (N days)' (the sentence the metric carries), and where it stands now. Never a diagnosis; 'collecting' until the
/// baseline has enough nights. The numbers come computed from ALG-170 (`trend`, `trend_level` metrics of the wake day);
/// this file only chooses and words.
public struct TrendCard: Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    /// "What it tracks", one plain sentence.
    public var tracks: String
    /// "paper", "theory" or "both" — and the source.
    public var backingKind: String
    public var backing: String
    /// What the base tier and the enhanced tier read.
    public var tiers: String
    /// The population value the baseline starts from (D-POP-PRIOR), or why there is none.
    public var population: String
    /// "Collecting: 5 of 7 nights so far" · "Within your usual range" · "Worth noting" · "Stronger".
    public var status: String
    /// Level 0-2; nil while collecting.
    public var level: Int?
    /// "z +0.4" (AF burden: "5.0 % of still time"); nil while collecting.
    public var value: String?
    /// The calm sentence ALG-170 wrote (baseline line, 'population' vs 'yours (N nights)'); nil while collecting.
    public var sentence: String?
    /// "base" or "enhanced" — the tier the number was computed on; nil while collecting.
    public var tierUsed: String?

    public init(id: String, title: String, tracks: String, backingKind: String, backing: String, tiers: String,
                population: String, status: String, level: Int?, value: String?, sentence: String?, tierUsed: String?) {
        self.id = id
        self.title = title
        self.tracks = tracks
        self.backingKind = backingKind
        self.backing = backing
        self.tiers = tiers
        self.population = population
        self.status = status
        self.level = level
        self.value = value
        self.sentence = sentence
        self.tierUsed = tierUsed
    }
}

enum TrendCatalogue {
    struct Info {
        var variant: String
        var title: String
        var tracks: String
        var kind: String
        var backing: String
        var tiers: String
        var population: String
    }

    static let all: [Info] = [
        Info(variant: "breathing", title: "Breathing-rate trend",
             tracks: "Your breathing rate while asleep (an estimate read from the beat-to-beat rhythm) against your own normal.",
             kind: "both",
             backing: "Theory: breathing speeds and slows the heart a little (respiratory sinus arrhythmia), so the rate can be read "
                 + "from R-R intervals. Paper: heart-rhythm-derived breathing rate within about 0.5 breaths/min of a sleep-lab "
                 + "recording (Natarajan et al., npj Digit Med; abstract-level). A rise with illness is weak on its own (Miller 2020, "
                 + "WHOOP-sponsored: 36 % sensitivity), so it is only a trend.",
             tiers: "Base: R-R intervals through the night, nothing extra switched on. Enhanced: the same from the pulse waveform "
                 + "in raw-pulse bursts, used once it has 7 nights of its own.",
             population: "Starts at 15 breaths/min with a spread of 1.0 (ours, the middle of the usual 12-20 resting range)."),
        Info(variant: "apnea", title: "Breathing-pattern (apnea screen) trend",
             tracks: "How often your heart rate rises and falls in repeated 25-100 s cycles per hour of sleep, against your own "
                 + "normal. A screen trend, not the apnea-hypopnea index.",
             kind: "paper",
             backing: "Hayano et al., PLoS ONE 2020: cycles per hour averaged 19.6 with an apnea-hypopnea index of 15 or more and "
                 + "6.4 below it. Night to night it misses many nights (Ann Noninvasive Electrocardiol 2022), so only nights of 4 h "
                 + "or more count and it is a trend.",
             tiers: "Base: R-R intervals (ALG-023). Enhanced: none yet; blood-oxygen dips wait for a calibration.",
             population: "Starts at 6.4 per hour with a spread of 4.0 (Hayano 2020 for the centre; the spread is ours)."),
        Info(variant: "afburden", title: "Irregular-rhythm (AF burden) trend",
             tracks: "The share of still time your pulse looked irregular over the last 7 nights; a 60-second ECG check confirms "
                 + "or clears it.",
             kind: "both",
             backing: "Paper: burden as the share of monitored time in AF is the American Heart Association's most intuitive "
                 + "definition (Chen et al., Circulation 2018;137:e623). A watch's irregular-pulse alert matched an ECG patch "
                 + "84 % of the time (Apple Heart Study, Perez et al., NEJM 2019;381:1909; their algorithm, not ours). Theory: "
                 + "irregular spacing of beats; our R-R screen (ALG-013) is not checked against an ECG. The published route is "
                 + "pulse screen, then ECG, then a clinician; a doctor is suggested here only when an ECG check also looked irregular.",
             tiers: "Base: R-R screen over still 5-minute windows. Enhanced: the 60-second ECG check; its verdict is not stored "
                 + "as a rhythm result yet, so today only the R-R screen is used.",
             population: "About 0 % is expected without AF; there is no personal baseline to learn."),
        Info(variant: "orthostatic", title: "Standing heart-rate response trend",
             tracks: "How much your heart rate rises in the half minute after you get up and walk, after at least 5 minutes still "
                 + "(a day's median of 2 or more such moments).",
             kind: "both",
             backing: "Theory: standing pools blood in the legs and the baroreflex speeds the heart. Paper: a sustained rise of 30 "
                 + "bpm or more within 10 minutes of standing is the clinical postural-tachycardia criterion (Freeman et al., "
                 + "Clin Auton Res 2011;21:69). Our moments are found from wrist movement and read the first half-minute, so it "
                 + "is not that test; only your own trend is shown.",
             tiers: "Base: strap activity class and 1 Hz heart rate. Enhanced: 100 Hz motion would sharpen the moment; not wired "
                 + "into the night run yet.",
             population: "None: our moments are not the clinical test, so the baseline is yours alone (14 days needed)."),
        Info(variant: "perfusion", title: "Pulse-strength (perfusion) trend",
             tracks: "How strong the pulse is next to the steady light level (AC/DC) in still, clean raw-pulse bursts through the night.",
             kind: "theory",
             backing: "Theory only: perfusion index is the standard pulse-oximetry AC/DC ratio, and finger studies link lower pulse "
                 + "amplitude to sympathetic vasoconstriction (Betta et al., Sleep Med 2020; search-snippet level). No wrist "
                 + "validation was found; strap pressure and posture move it, so it is compared only with your own nights.",
             tiers: "Base: none, it needs the raw pulse. Enhanced: raw-pulse bursts switched on in Settings.",
             population: "None: raw counts are uncalibrated, so the baseline is yours alone (14 nights needed)."),
        Info(variant: "illness", title: "Early-warning (combined signs) trend",
             tracks: "Resting heart rate up, HRV down, breathing up and skin temperature up together, on two nights in a row, each "
                 + "against your own normal. Skin temperature counts as a change from your baseline (raw strap counts, not degrees).",
             kind: "both",
             backing: "Paper: resting-heart-rate and temperature changes show illness before symptoms (Mishra et al., Nat Biomed Eng "
                 + "2020;4:1208; Smarr et al., Sci Rep 2020; Radin et al., Lancet Digit Health 2020). Theory: combining the signs "
                 + "is common consumer practice, not a validated score; thresholds are ours.",
             tiers: "Base: all four from the night's strap data. Enhanced: none; every input is base-tier.",
             population: "Only the usual night-to-night spread starts from population values (resting HR 2 bpm, lnRMSSD 0.15, "
                 + "breathing 1.0); the levels are yours."),
    ]
}

public enum TrendsPresenter {
    static let levelWords = ["Within your usual range", "Worth noting", "Stronger than usual"]

    public static func cards(_ s: PresenterSnapshot) -> [TrendCard] {
        TrendCatalogue.all.map { info in
            let m = s.metric(MetricKey.trend.rawValue, variant: info.variant, window: "night")
            let own = m.flatMap { ImportedHistory.isImported($0) ? nil : $0 }
            var status = "Collecting: no data yet"
            var level: Int?
            var value: String?
            var sentence: String?
            var tierUsed: String?
            if let m = own, let v = m.value, v.isFinite {
                let l = s.metric(MetricKey.trendLevel.rawValue, variant: info.variant, window: "night")?.value
                level = l.map { max(0, min(2, Int($0.rounded()))) }
                status = level.map { levelWords[$0] } ?? "Shown, level not computed"
                value = info.variant == "afburden" ? String(format: "%.1f %% of still time", v) : String(format: "z %+.1f", v)
                sentence = m.note
                tierUsed = (m.method ?? "").hasSuffix("enhanced") ? "enhanced" : "base"
            } else if let why = own?.note, !why.isEmpty {
                status = why.hasPrefix("collecting") ? "Collecting" + why.dropFirst("collecting".count) : why
                if status.first?.isLowercase == true { status = status.prefix(1).uppercased() + status.dropFirst() }
            }
            return TrendCard(id: info.variant, title: info.title, tracks: info.tracks, backingKind: info.kind,
                             backing: info.backing, tiers: info.tiers, population: info.population, status: status,
                             level: level, value: value, sentence: sentence, tierUsed: tierUsed)
        }
    }
}
