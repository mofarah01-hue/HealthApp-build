import Foundation
import MGDomain

// WP-23b. Comparison groups as they appear on screen (UX §11, Vernier): labels, codenames, ranks and own bands per
// member. Sources: ARCHITECTURE §8.3 (names, variants), ALGORITHM-COMPARISON.md (ranks), ALGORITHM-REQUIREMENTS §13
// (members), UX §11 (Loop bands 67 / 34, read defaults). Addition only: every member present in the metrics is shown,
// catalogued or not; Mo's drop hides a member, never deletes it.

/// A member's own three bands on its own scale: value < `low` → bottom (0), < `high` → middle (1), else top (2).
struct MemberBands: Equatable {
    var min: Double
    var low: Double
    var high: Double
    var max: Double

    func index(_ v: Double) -> Int { v < low ? 0 : (v < high ? 1 : 2) }

    /// Position 0…1 on the strip: each band fills one third (UX §11 "placed on its own bands' thirds").
    func position(_ v: Double) -> Double {
        func frac(_ x: Double, _ a: Double, _ b: Double) -> Double { b > a ? Swift.min(1, Swift.max(0, (x - a) / (b - a))) : 0.5 }
        switch index(v) {
        case 0: return frac(v, min, low) / 3
        case 1: return (1 + frac(v, low, high)) / 3
        default: return (2 + frac(v, high, max)) / 3
        }
    }
}

struct GroupMemberInfo {
    /// Contract `variant`.
    var variant: String
    /// The registry metric name this member reads.
    var name: String
    var label: String
    var codename: String?
    /// ALGORITHM-COMPARISON rank (1 best); nil = unranked.
    var rank: Int?
    var bands: MemberBands?
    var scaleNote: String?
}

struct GroupInfo {
    var id: String
    /// "Recovery" (strip title "Recovery · 5 methods").
    var title: String
    var members: [GroupMemberInfo]
    /// No shared band scale: one values line instead of the strip (UX §11: stage totals, HRV indices).
    var valuesLineOnly: Bool
    /// The default read method when the UX names one; nil = highest rank (UX §11).
    var explicitDefault: String?

    /// UX §11: default read = highest rank unless the UX names one (UX §12: recovery reads ALG-036 components).
    var defaultRead: String? {
        if let e = explicitDefault { return e }
        return members.filter { $0.rank != nil }.min { ($0.rank ?? 99) < ($1.rank ?? 99) }?.variant
            ?? members.first?.variant
    }
}

enum GroupCatalogue {
    static func m(_ variant: String, _ name: String, _ label: String, _ codename: String?, _ rank: Int?,
                  bands: MemberBands? = nil, note: String? = nil) -> GroupMemberInfo {
        GroupMemberInfo(variant: variant, name: name, label: label, codename: codename, rank: rank, bands: bands,
                        scaleNote: note)
    }

    static let all: [GroupInfo] = [
        // UX §12: "Recovery (from the read method; default Orchard = ALG-160 readiness)". r9h (D-RECOV-WALK-2): the ALG-036
        // "n of 5 in your range" member is gone; Orchard MS-19 is rebuilt as a Garmin-style 1-100 readiness whose core is
        // Plews' HRV status. Garmin's bands: Poor 1-24, Low 25-49, Moderate 50-74, High 75-94, Prime 95-100; the three-way
        // bands here fold them as low < 50, high >= 75.
        GroupInfo(id: "G-READY", title: "Recovery", members: [
            m("MS-19", "readiness", "Orchard · readiness", "ALG-160 training-readiness-style", 1,
              bands: MemberBands(min: 1, low: 50, high: 75, max: 100), note: "1–100 · Garmin-style bands · weights are our estimate"),
            m("ALG-101", "readiness", "Plews lnRMSSD", "ALG-101", 2, note: "z vs your 28 nights"),
            m("MS-18", "readiness", "Loop", "MS-18 recovery_loop", 3,
              bands: MemberBands(min: 0, low: 34, high: 67, max: 100), note: "green ≥ 67"),
            m("MS-20", "readiness", "Aurora", "MS-20 readiness_aura", 3, note: "/100 · our estimate of Oura's inputs"),
        ], valuesLineOnly: false, explicitDefault: "MS-19"),
        // r9h (ALG-161): worth-noting signs against your own normal; one row per code, level 0-2, never a diagnosis.
        GroupInfo(id: "G-WARN", title: "Warning signs", members: [
            m("rhr", "warning_sign", "Resting heart rate", "ALG-161", nil, note: "0 nothing · 1 worth noting · 2 stronger"),
            m("temp", "warning_sign", "Skin temperature", "ALG-161", nil, note: "raw-count change from your normal, either way"),
            m("resp", "warning_sign", "Breathing rate", "ALG-161", nil, note: "our estimate; weak on its own"),
            m("alcohol", "warning_sign", "First hours of sleep", "ALG-161", nil, note: "a pattern, not a measurement"),
            m("rhythm", "warning_sign", "Pulse rhythm", "ALG-161", nil, note: "a screen; a 60 s ECG can confirm"),
            m("cvhr", "warning_sign", "Breathing pattern", "ALG-161", nil, note: "a screen, misses many nights"),
        ], valuesLineOnly: true, explicitDefault: nil),
        // r9s (ALG-170): relative trends against your own baseline (population value first); `trend` = z (AF burden: %).
        GroupInfo(id: "G-TREND", title: "Trends vs your baseline", members: [
            m("breathing", "trend", "Breathing rate", "ALG-170", nil, note: "z vs your baseline · estimate"),
            m("apnea", "trend", "Breathing pattern (apnea screen)", "ALG-170", nil, note: "z · a screen, not an index"),
            m("afburden", "trend", "Irregular rhythm (AF burden)", "ALG-170", nil, note: "% of still time · 7 nights"),
            m("orthostatic", "trend", "Standing heart-rate rise", "ALG-170", nil, note: "z · from wrist movement"),
            m("perfusion", "trend", "Pulse strength (perfusion)", "ALG-170", nil, note: "z · raw pulse, uncalibrated"),
            m("illness", "trend", "Early-warning (combined signs)", "ALG-170", nil, note: "index · two nights in a row"),
        ], valuesLineOnly: true, explicitDefault: nil),
        GroupInfo(id: "G-LOAD", title: "Strain", members: [
            m("MS-01", "strain", "Banister TRIMP", "MS-01", 1),
            m("ALG-036", "strain", "Ours, 0–21 net-load map", "ALG-036", 2),
            m("ALG-036:fit", "strain", "WHOOP-style strain (estimate)", "ALG-036", 2, note: "estimate - not WHOOP's number"),
            m("ALG-036:trimp", "strain", "Banister TRIMP, whole day", "ALG-036", 2, note: "TRIMP units, not 0–21 · the headline"),
            m("MS-02", "strain", "Edwards zones", "MS-02", 2),
            // r9p (D-LOAD-WALK-2): this week vs your 4-week average, as two numbers; no ratio, no zone, no injury claim
            m("ALG-036:week", "load_week", "This week (TRIMP)", "ALG-036", nil, note: "au, the last 7 days, plain sum"),
            m("ALG-036:week4", "load_week", "Your 4-week average week", "ALG-036", nil, note: "au, mean week of the last 28 days"),
            m("ALG-036:srpe_week", "load_week", "This week by your ratings", "ALG-036", nil, note: "au, rating x minutes (Foster 2001)"),
            m("ALG-036:score", "load_session", "Load vs your own sessions", "ALG-036", nil, note: "percentile among your sessions of that type"),
            m("ALG-036:srpe", "load_session", "Session rating load", "ALG-036", nil, note: "au, CR-10 rating x minutes"),
            m("MS-03", "acwr", "Acute:chronic", "MS-03", 3, note: "7:28 · descriptive only"),
        ], valuesLineOnly: false, explicitDefault: nil),
        // Bug 1 (round 2, 2026-10-14, M-048/M-049): the registry names of G-HRV, one row each. LF/HF, DFA α1, PRSA and Kubios PNS/SNS
        // left it on 2026-10-17 (D-HRV-WALK-1; LF/HF stay in Every measure as lab / research). Before, the group listed
        // 4 and `groupRows` kept one row per variant, so SDNN, pNN50, SD1, SD2, ln RMSSD (ALG-010), DFA α1, LF, HF
        // (ALG-011) and SNS (ALG-107) were computed but never shown. Ranks stay on the first row of each method.
        GroupInfo(id: "G-HRV", title: "HRV", members: [
            m("ALG-010", "hrv_rmssd", "RMSSD", "ALG-010", 1, note: "ms · beat-to-beat change, the vagal (rest) signal"),
            m("ALG-010", "hrv_ln_rmssd", "ln RMSSD", "ALG-010", nil, note: "log of RMSSD · steadier day to day"),
            m("ALG-010", "hrv_sdnn", "SDNN", "ALG-010", nil, note: "ms · overall spread of beat gaps"),
            m("ALG-010", "hrv_pnn50", "pNN50", "ALG-010", nil, note: "% of beat gaps changing by > 50 ms"),
            m("ALG-010", "hrv_sd1", "Poincaré SD1", "ALG-010", nil, note: "ms · short-term spread (≈ RMSSD ÷ √2)"),
            m("ALG-010", "hrv_sd2", "Poincaré SD2", "ALG-010", nil, note: "ms · long-term spread"),
            m("ALG-013", "hrv_sampen", "Sample entropy", "ALG-013", 2, note: "irregularity of the beat series"),
            // r9l (2026-10-17, D-HRV-WALK-1): the 60 s morning check. ECG first; the pulse (PPG) reading only when there
            // was no ECG that morning. Never mixed; feeds the readiness HRV part (ALG-160 enhanced tier).
            m("ALG-010:spot60", "hrv_rmssd", "RMSSD, 60 s morning ECG", "ALG-010", nil, note: "ms · morning check, ECG"),
            m("ALG-010:spot60", "hrv_ln_rmssd", "ln RMSSD, 60 s morning ECG", "ALG-010", nil, note: "morning check, ECG"),
            m("ALG-010:spot60ppg", "hrv_rmssd", "RMSSD, 60 s morning pulse", "ALG-010", nil, note: "ms · morning check, pulse (PPG)"),
            m("ALG-010:spot60ppg", "hrv_ln_rmssd", "ln RMSSD, 60 s morning pulse", "ALG-010", nil, note: "morning check, pulse (PPG)"),
        ], valuesLineOnly: true, explicitDefault: nil),
        GroupInfo(id: "G-RESP", title: "Breathing rate", members: [
            m("ALG-020", "resp_rate", "Multi-modulation fusion", "ALG-020", 1),
            m("ALG-121", "resp_rate", "RSA + RIIV", "ALG-121", 2),
            m("MS-07", "resp_rate", "RSA FFT", "MS-07 Kratky", 3),
            // wave 4: from the pulse itself (v26 PPG bursts): baseline (RIIV) and amplitude (RIAV) modulation
            m("ALG-121:riiv", "resp_rate", "Pulse baseline (RIIV)", "ALG-121", nil, note: "research, v26 PPG"),
            m("ALG-121:riav", "resp_rate", "Pulse amplitude (RIAV)", "ALG-121", nil, note: "research, v26 PPG"),
            // T47: the same two modulations on the live raw optical stream (R20), one spot, estimate
            m("ALG-121:r20pulse", "resp_rate", "Pulse, raw optical (spot)", "ALG-121", nil, note: "estimate, R20 live"),
        ], valuesLineOnly: true, explicitDefault: nil),
        GroupInfo(id: "G-SPO2", title: "SpO₂ byte", members: [
            m("ALG-021", "spo2_strap_mean", "Strap SpO₂ byte", "ALG-021", 1, note: "raw byte, unchecked"),
            // wave 4 (#25): noop's gate aggregate; the only member that may read as % (after the PC's check passes)
            m("ALG-021:windows", "spo2_strap_mean", "Strap byte, in its windows", "ALG-021", nil,
              note: "raw byte until checked against WHOOP"),
            // R9m (D-ALG-TIERS): the enhanced tier, only when raw optical ran in the night
            m("ALG-022:night", "spo2_pct", "Red / IR estimate (raw optical, research)", "ALG-022", nil,
              note: LEDIdentity.researchLabel),
            m("ALG-022:spot", "spo2_pct", "Red / IR spot reading (60 s, live)", "ALG-022", nil,
              note: "research estimate — not checked against WHOOP"),
        ], valuesLineOnly: true, explicitDefault: nil),
        GroupInfo(id: "G-TEMP", title: "Skin temperature", members: [
            m("ALG-110:100", "skin_temp_dev", "°C (raw ÷ 100)", "ALG-110", nil, note: "decoded, untested · AS6221 R18 byte 73"),
            m("ALG-110:128", "skin_temp_dev", "Alternative raw ÷ 128", "ALG-110", nil, note: "estimate only · not °C"),
        ], valuesLineOnly: true, explicitDefault: nil),
        GroupInfo(id: "G-STAGE", title: "Sleep stages", members: [
            // WP-22 emits ALG-031:A blank until it is trained (main, 2026-10-11); rank 2 per ALGORITHM-COMPARISON.
            m("ALG-031:A", "sleep_deep", "Ours A", "ALG-031 A", 2),
            m("ALG-151", "sleep_deep", "Ours (phone), fused stager", "ALG-151", 1, note: "base tier · estimate"),
            m("ALG-120", "sleep_deep", "Ours, motion + heart-rate rules (no Markov step)", "ALG-120", 3),
            m("MS-21", "sleep_deep", "Rule-based", "MS-21", 5),
            m("strap", "sleep_deep", "Strap flag", "strap", nil),
            // PC Lab ML estimates (off by default; blank with a reason when they did not run).
            m("pc.fused-stager", "sleep_deep", "PC: fused stager (heart rate + motion + strap flag; primary)", "pc.fused-stager", nil),
            m("pc.sleep-ecg", "sleep_deep", "PC: SleepECG (strap-flag night, R-R + age/sex/clock; no deep split; comparison)", "pc.sleep-ecg", nil),
            m("pc.wav2sleep", "sleep_deep", "PC: wav2sleep (raw PPG; comparison)", "pc.wav2sleep", nil),
            // Default read ALG-120 (main, 2026-10-11): ALG-031:A is blank until trained; Mo can pick it once it runs.
        ], valuesLineOnly: true, explicitDefault: "ALG-151"),
        GroupInfo(id: "G-CAFF", title: "Caffeine cut-off", members: [
            m("ALG-061", "caffeine_cutoff", "Probabilistic", "ALG-061", 1),
            m("ALG-126:33mg", "caffeine_cutoff", "≤ 33 mg at bed", "ALG-126", 2),
            m("ALG-126:drake6h", "caffeine_cutoff", "Drake ≥ 6 h", "ALG-126 Drake", 3),
        ], valuesLineOnly: true, explicitDefault: nil),
        GroupInfo(id: "G-CAL", title: "Calories", members: [
            m("ALG-048:keytel", "calories_active", "Keytel · heart rate (high end)", "ALG-048", 1),
            m("ALG-048:keytel_vo2", "calories_active", "Keytel + VO₂max", "ALG-048", 1),
            m("ALG-048:keytel_motion", "calories_active", "Heart rate + motion (low end)", "ALG-048", 1,
              note: "only minutes where heart rate and the strap's motion agree; estimate"),
            m("apple", "calories_active", "Apple active energy", nil, nil),
            m("ALG-048:mifflin", "calories_basal", "Resting · Mifflin-St Jeor", "ALG-048", 2),
            m("ALG-048:cunningham", "calories_basal", "Resting · Cunningham, from scan", "ALG-048", 2,
              note: "500 + 22 x fat-free mass from your body-composition scan, adjusted to your current weight; estimate"),
        ], valuesLineOnly: true, explicitDefault: nil),
        GroupInfo(id: "G-STEPS", title: "Steps", members: [
            // r9o: the merged day total (phone where carried, strap fills the hours the phone missed) reads first.
            m("merged", "steps", "Phone + strap", "ALG-040", 1, note: "iPhone per hour; strap fills hours the phone missed"),
            m("strap", "steps", "Strap", nil, 2),
            m("apple", "steps", "iPhone", nil, 3),
            // T97: the other two models that write `steps` (registry), so neither shows under its raw variant name.
            m("apple_watch", "steps", "Apple Watch", nil, nil),
            m("ALG-040:ticks", "steps", "Strap counter ticks", "ALG-040", nil, note: "ticks, not steps"),
        ], valuesLineOnly: true, explicitDefault: nil),
        // R9m (D-HRV-WALK-1): "stress" is shown as BODY AROUSAL - physiological arousal from daytime HR / HRV against
        // your own baseline, still windows only. The key and group id stay `stress` / G-STRESS (stored rows).
        GroupInfo(id: "G-STRESS", title: "Body arousal", members: [
            m("ALG-123:daytime", "stress", "Daytime 0–3", "ALG-123", 1, note: "physiological arousal, not mood; estimate"),
            m("ALG-054", "stress", "Autonomic load (z)", "ALG-054", 2),
            m("MS-15", "stress", "HRV load (script)", "MS-15", 4),
            // T9737: ALG-105 wrote `stress_onsets` with no catalogue row, so it showed under its raw id "ALG-105" as a bare
            // number beside the 0–3 and 0–100 scores. It is a count of HRV rises today, not a score.
            m("ALG-105", "stress_onsets", "Arousal rises (count)", "ALG-105", nil,
              note: "rises today, not a 0–3 score; estimate"),
        ], valuesLineOnly: true, explicitDefault: nil),
        GroupInfo(id: "G-VO2", title: "VO₂max", members: [
            m("ALG-036", "vo2max", "Nes non-exercise (estimate)", "ALG-036", 1),
            m("ALG-036:uth", "vo2max", "HR-ratio, Uth (estimate)", "ALG-036", nil,
              note: "15.3 x max HR / resting HR, an estimate (T9722)"),
            m("apple", "vo2max", "Apple Watch (comparison)", nil, 2),
            m("MS-05", "vo2max", "Orchard", "MS-05", 3),
            m("MS-06", "vo2max", "Fenix", "MS-06", 3),
        ], valuesLineOnly: true, explicitDefault: nil),
        GroupInfo(id: "G-HRMAX", title: "Max heart rate", members: [
            m("ALG-106:measured", "hrmax", "Measured", "ALG-106", 1),
            m("ALG-106:tanaka", "hrmax", "Tanaka", "ALG-106", 2),
            m("MS-05:formula", "hrmax", "Script formula", "MS-05", 3),
            // Bug 12 (round 2, 2026-10-14, M-099): the references Mo compares against. Daily maxima from the imports, so a
            // spike is possible; they sit last (unranked) and are never read as a person's true maximum.
            m("whoop_export", "hrmax", "WHOOP export (daily max)", nil, nil,
              note: "highest heart rate WHOOP logged that day · one sample, a spike is possible"),
            m("apple_health", "hrmax", "Apple Health (daily max)", nil, nil,
              note: "highest heart rate Apple Health logged that day"),
        ], valuesLineOnly: true, explicitDefault: nil),
        GroupInfo(id: "G-AF", title: "Rhythm screen", members: [
            m("ALG-013", "af_screen", "R-R screen", "ALG-013", 3),
            m("ALG-129:pnn70", "af_screen", "pNN70", "ALG-129", 3),
            m("ALG-129:cosen", "af_screen", "COSEn", "ALG-129", 3),
        ], valuesLineOnly: true, explicitDefault: nil),
        // Wave 1 (2026-10-11), ALGORITHM-REQUIREMENTS §13 members; ranks not set (no ALGORITHM-COMPARISON row yet).
        GroupInfo(id: "G-APNEA", title: "Breathing disturbance", members: [
            m("ALG-023:cvhr", "breathing_disturbance", "CVHR per hour", "ALG-023", nil, note: "dips in heart rate per hour of sleep"),
            m("ALG-023:cvhr30", "breathing_disturbance", "Your last 30 nights", "ALG-023 RESP-01", nil),
            m("ALG-023:odi", "breathing_disturbance", "Desaturation index", "ALG-023", nil, note: "needs SpO₂ in %"),
            m("ALG-023:cvhr:pc", "breathing_disturbance", "CVHR, PC re-score", "ALG-023", nil),
            m("MS-10", "ms_ahi", "Script AHI", "MS-10 Lumen", nil),
        ], valuesLineOnly: true, explicitDefault: "ALG-023:cvhr"),
        GroupInfo(id: "G-AGE", title: "Biological age", members: [
            m("ALG-134:cosinor", "body_age", "CosinorAge", "ALG-134", nil, note: "needs raw motion"),
            m("ALG-070", "phenoage", "PhenoAge (labs)", "ALG-070", nil),
            // Bug 10 (round 2, 2026-10-14, M-147): KDM and HD were registered to G-AGE but not members; Fitness Age
            // (ALG-133, registry group G-VO2) is listed here too so every age estimate sits side by side. Its rows
            // still carry group G-VO2, so `groupRows` looks a catalogued member up by name + variant in every metric.
            m("ALG-077", "kdm_bioage", "KDM biological age (labs)", "ALG-077 KDM", nil, note: "years · from a lab draw"),
            m("ALG-077", "hd_distance", "Homeostatic dysregulation (labs)", "ALG-077 HD", nil,
              note: "distance, not years · lower is better"),
            m("ALG-133", "fitness_age", "Fitness Age (VO₂max)", "ALG-133", nil, note: "years · from VO₂max, estimate"),
        ], valuesLineOnly: true, explicitDefault: "ALG-133"),
        GroupInfo(id: "G-HYDRATION", title: "Hydration", members: [
            m("ALG-135", "hydration_goal", "EFSA reference (total water)", "ALG-135", nil, note: "ml, population value"),
            m("ALG-135:intake", "hydration_goal", "Drinks you logged today", "ALG-135", nil, note: "ml"),
            m("ALG-135:sweat", "hydration_goal", "Sweat loss of a workout", "ALG-135", nil, note: "ml, weight before/after, estimate"),
            m("ALG-135:sweat_rate", "hydration_goal", "Your sweat rate", "ALG-135", nil, note: "ml per hour, population until yours"),
        ], valuesLineOnly: true, explicitDefault: "ALG-135"),
        // T97 (2026-10-13): the registry's other G-groups (ARCHITECTURE §8.3, MSCatalogue), so each shows under Methods with
        // a title instead of its raw id. Script members (MS-xx) are PC-run; ranks unset (no ALGORITHM-COMPARISON row).
        GroupInfo(id: "G-VASC", title: "Pulse shape", members: [
            m("ALG-015", "pulse_rise_time", "Pulse rise time (green)", "ALG-015", nil, note: "research"),
            m("ALG-015:notch", "pulse_notch_time", "Dicrotic notch time (green)", "ALG-015", nil, note: "estimate; blank unless the notch is found in enough beats"),
            m("MS-12", "ms_cfpwv", "Pulse arrival time change (stiffness proxy)", "MS-12", nil),
            m("MS-13", "ms_stiffness_index", "Pulse-shape stiffness index change (stiffness proxy)", "MS-13", nil),
            m("MS-14", "ms_ppg_aix", "Reflection index change (pulse-shape proxy)", "MS-14", nil),
        ], valuesLineOnly: true, explicitDefault: nil),
        GroupInfo(id: "G-BP", title: "Blood pressure", members: [
            m("MS-09", "ms_bp_sbp", "Script, anchored to a cuff", "MS-09", nil),
        ], valuesLineOnly: true, explicitDefault: nil),
        GroupInfo(id: "G-SV", title: "Stroke-volume proxy", members: [
            m("MS-11", "ms_stroke_volume", "Heart-rate drift at steady effort", "MS-11", nil),
        ], valuesLineOnly: true, explicitDefault: nil),
        GroupInfo(id: "G-LVEDP", title: "Filling-pressure lines", members: [
            m("MS-16", "ms_lvedp_anchor", "NT-proBNP vs the 125 ng/L rule-out level", "MS-16", nil),
            m("MS-17", "ms_lvedp_index", "Night resting HR vs baseline", "MS-17", nil),
        ], valuesLineOnly: true, explicitDefault: nil),
        GroupInfo(id: "G-GAIT", title: "Gait", members: [
            m("ALG-114", "imu_asym", "Wrist asymmetry (raw motion)", "ALG-114", nil, note: "research"),
        ], valuesLineOnly: true, explicitDefault: nil),
        GroupInfo(id: "G-HORMONE", title: "Hormones", members: [
            m("ALG-071", "lab_testosterone_total", "Testosterone, measured", "ALG-071", nil, note: "from a lab draw"),
            m("MS-25", "ms_testosterone_proxy", "Testosterone proxy (script)", "MS-25", nil),
            m("ALG-072", "lab_cortisol", "Cortisol, measured", "ALG-072", nil, note: "from a lab draw"),
            m("MS-26", "ms_cortisol_car_proxy", "Morning HRV change (stress-axis proxy)", "MS-26", nil),
        ], valuesLineOnly: true, explicitDefault: nil),
        GroupInfo(id: "G-LABS", title: "Blood-lab priors", members: [
            m("MS-23", "ms_lab_hba1c", "Blood-lab prior (script)", "MS-23", nil),
            m("MS-24", "ms_genetic_bp_prior", "Lp(a) elevated flag (static context)", "MS-24", nil),
        ], valuesLineOnly: true, explicitDefault: nil),
        GroupInfo(id: "G-GLUCOSE", title: "Post-meal response", members: [
            m("MS-27", "ms_glucose_risk_proxy", "Post-meal heart-rate response (glucose proxy)", "MS-27", nil),
        ], valuesLineOnly: true, explicitDefault: nil),
        GroupInfo(id: "G-MUSCLE", title: "Recovery cost", members: [
            m("MS-29", "ms_muscle_injury_proxy", "Recovery cost: lines beyond usual (soreness proxy)", "MS-29", nil),
        ], valuesLineOnly: true, explicitDefault: nil),
        GroupInfo(id: "G-SQI", title: "Signal quality", members: [
            m("MS-30", "ms_sqi", "Signal quality weight (script)", "MS-30", nil),
            m("MS-31", "ms_fuse", "Fused estimate (script)", "MS-31", nil),
        ], valuesLineOnly: true, explicitDefault: nil),
        GroupInfo(id: "G-CAUSE", title: "Cause finder", members: [
            m("ALG-124:py", "cause_odds_ratio", "Odds ratio (Python)", "ALG-124", nil),
            m("ALG-124:r", "cause_odds_ratio", "Odds ratio (R)", "ALG-124", nil),
            m("ALG-064", "cause_lag_effect", "Lag effect, 0–7 days", "ALG-064", nil),
        ], valuesLineOnly: true, explicitDefault: nil),
    ]

    static func group(_ id: String) -> GroupInfo? { all.first { $0.id == id } }

    static func member(_ gid: String, _ variant: String?) -> GroupMemberInfo? {
        guard let variant else { return nil }
        return group(gid)?.members.first { $0.variant == variant }
    }

    /// Rank for sorting; unranked and unknown last.
    static func rank(_ gid: String, _ variant: String?) -> Int { member(gid, variant)?.rank ?? 99 }
}

// MARK: - Strip and group state

/// One member as the strip and the group screen show it.
struct GroupMemberRow {
    var info: GroupMemberInfo
    var metric: Metric?
}

extension PresenterSnapshot {
    /// Every member of a group: catalogued ones in catalogue order (blank when nothing is stored), then any other stored
    /// member of the group (labelled by its variant) — nothing a pipeline produced is ever left out.
    func groupRows(_ gid: String, window: String? = nil, source: [Metric]? = nil) -> [GroupMemberRow] {
        let all = source ?? metrics
        let pool = all.filter { $0.group == gid }
        let info = GroupCatalogue.group(gid)
        var rows: [GroupMemberRow] = []
        // Bug 1 (round 2, 2026-10-14): a catalogued row is one name + variant, so the HRV group's 15 names each get a
        // row (before, 4 catalogued names and a one-row-per-variant check hid SDNN, pNN50, SD1, SD2, ln RMSSD, DFA α1,
        // LF, HF and SNS although each was computed). Uncatalogued stored rows still add one row per new variant, so
        // a group's side names (sleep_light under Sleep stages, ctl under Strain) do not crowd the strip.
        var used = Set<String>()
        for mi in info?.members ?? [] {
            // Bug 10: a member filed under another registry group (Fitness Age, G-VO2, listed under G-AGE) is found
            // by name + variant in every metric.
            let m = metric(mi.name, variant: mi.variant, window: window, in: pool)
                ?? metric(mi.name, variant: mi.variant, window: window, in: all)
            rows.append(GroupMemberRow(info: mi, metric: m))
            used.insert(mi.variant)
        }
        for m in pool {
            guard let v = m.variant, !used.contains(v) else { continue }
            if let window, let w = m.window, w != window { continue }
            used.insert(v)
            // Imported history is named for where it came from (UX §11: "WHOOP export (only if imported; past days)").
            let imported = ImportedHistory.memberLabel(v)
            rows.append(GroupMemberRow(info: GroupMemberInfo(variant: v, name: m.name, label: imported ?? v,
                                                             codename: imported == nil ? m.method : nil, rank: nil,
                                                             bands: nil, scaleNote: importedScale(gid, v)),
                                metric: m))
        }
        return rows
    }

    /// T133: an imported member names its scale too, so numbers on different scales are not read as disagreeing.
    private func importedScale(_ gid: String, _ variant: String) -> String? {
        if gid == "G-READY", variant == ImportedHistory.whoopExport { return "0–100 · WHOOP's own number" }
        if gid == "G-READY", variant == "noop-recovery:import" { return "0–100 · WHOOP-style recovery (estimate)" }
        return GroupCatalogue.member(gid, ImportedHistory.baseVariant(variant))?.scaleNote
    }

    /// One `MethodMember` (value on its own scale, band, tick position, read / keep / drop marks).
    func methodMember(_ gid: String, _ row: GroupMemberRow, read: String?) -> MethodMember {
        let choice = groupChoices[gid] ?? GroupChoice()
        let value = display(row.metric, missing: "No result stored for this method yet.")
        var band: Int?
        var pos: Double?
        if let b = row.info.bands, let v = row.metric?.value, v.isFinite {
            band = b.index(v)
            pos = b.position(v)
        }
        let research = row.metric?.tier == .research
        return MethodMember(variant: row.info.variant, label: row.info.label, codename: row.info.codename,
                            value: value, scaleNote: row.info.scaleNote, bandIndex: band, position: pos,
                            isRead: row.info.variant == read,
                            isResearch: research, rank: row.info.rank,
                            isKept: choice.kept.contains(row.info.variant),
                            isDropped: choice.dropped.contains(row.info.variant), name: row.info.name)
    }

    /// Every row as a `MethodMember`. Several rows can share the read variant (HRV: ALG-010 writes six names); only
    /// the first is marked "the one you read" (bug 1, round 2).
    func methodMembers(_ gid: String, _ rows: [GroupMemberRow], read: String?) -> [MethodMember] {
        var readSeen = false
        return rows.map { row -> MethodMember in
            var mm = methodMember(gid, row, read: read)
            if mm.isRead { if readSeen { mm.isRead = false } else { readSeen = true } }
            return mm
        }
    }

    /// The collapsed Vernier strip for a group (UX §11); nil when the group has no members at all.
    func methodsStrip(_ gid: String, window: String? = nil, source: [Metric]? = nil) -> MethodsStripState? {
        let rows = groupRows(gid, window: window, source: source)
        let present = rows.filter { $0.metric != nil }
        guard !present.isEmpty else { return nil }
        let read = readVariant(group: gid, among: present.compactMap(\.metric))
        let members = methodMembers(gid, rows, read: read)
        let shown = members.filter { !$0.isDropped }
        let dropped = members.count - shown.count
        let info = GroupCatalogue.group(gid)
        let title = "\(info?.title ?? gid) · \(shown.count) method\(shown.count == 1 ? "" : "s")"
        return MethodsStripState(sample: sample, groupId: gid, title: title, members: shown,
                                 caption: stripCaption(gid, shown), agreement: explore.agreement[gid],
                                 droppedCount: dropped, valuesLineOnly: info?.valuesLineOnly ?? true,
                                 isExpanded: ui.expandedGroups.contains(gid))
    }

    /// "4 in the top band, 1 in the middle. Reading ours until you choose." (UX §11).
    func stripCaption(_ gid: String, _ shown: [MethodMember]) -> String {
        var parts: [String] = []
        let names = ["bottom", "middle", "top"]
        for b in [2, 1, 0] {
            let n = shown.filter { $0.bandIndex == b }.count
            if n > 0 { parts.append(b == 2 ? "\(n) in the top band" : "\(n) in the \(names[b])") }
        }
        let cant = shown.filter { $0.value.isBlank }.count
        var s = parts.isEmpty ? "" : parts.joined(separator: ", ") + ". "
        if cant > 0 { s += "\(cant) couldn't run. " }
        let read = shown.first { $0.isRead }
        let readName = read.map { $0.label == "Ours, as components" || $0.label.hasPrefix("Ours") ? "ours" : $0.label }
            ?? "—"
        if let at = groupChoices[gid]?.readChosenAt {
            s += "Reading \(readName), your choice since \(MGFormat.shortDate(at, calendar: calendar))."
        } else {
            s += "Reading \(readName) until you choose."
        }
        return s
    }
}
