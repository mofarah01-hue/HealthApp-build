import Foundation
import MGDomain

/// The Explore catalogue (UX §9): registry metrics (ARCHITECTURE §8.3) under the UX section names, every comparison
/// group under Methods, research tools last. A section with no B1 metric (Food & symptoms, Body & labs) is left out
/// rather than shown empty.
enum ExploreCatalogue {
    struct Entry {
        var key: String
        var name: String
        var group: String?
    }

    static let sections: [(String, [Entry])] = [
        ("Heart & lungs", [
            Entry(key: "rhr", name: "Resting HR", group: nil),
            Entry(key: "hr_dip", name: "HR dip", group: nil),
            Entry(key: "hrv_rmssd", name: "HRV", group: "G-HRV"),
            Entry(key: "ppg_hr", name: "Heart rate from the pulse (PPG)", group: nil),
            Entry(key: "ppg_hrv_rmssd", name: "Spot HRV from the pulse (PPG)", group: nil),
            Entry(key: "optical_saturated_pct", name: "Optical signal: saturated seconds", group: nil),
            Entry(key: "optical_psnr", name: "Optical signal: pSNR", group: nil),
            Entry(key: "optical_logvar", name: "Optical signal: log-variance", group: nil),
            Entry(key: "pulse_rise_time", name: "Pulse rise time (green)", group: "G-VASC"),
            Entry(key: "pulse_width_half", name: "Pulse width (green)", group: "G-VASC"),
            Entry(key: "pulse_notch_time", name: "Dicrotic notch time (green)", group: "G-VASC"),
            Entry(key: "pulse_reflection_index", name: "Reflection index (green)", group: "G-VASC"),
            Entry(key: "pulse_notch_rate", name: "Notch detection rate (green)", group: "G-VASC"),
            Entry(key: "resp_rate", name: "Breathing rate", group: "G-RESP"),
            Entry(key: "spo2_strap_mean", name: "SpO₂ byte", group: "G-SPO2"),
            Entry(key: "spo2_gate_nights", name: "SpO₂ check against WHOOP", group: "G-SPO2"),
            Entry(key: "spo2_pct", name: "SpO₂ % (WHOOP / Apple / red-IR estimate)", group: "G-SPO2"),
            Entry(key: "skin_temp_c", name: "Skin temperature °C (WHOOP / Apple)", group: nil),
            Entry(key: "skin_temp_dev", name: "Skin temperature", group: "G-TEMP"),
            Entry(key: "af_screen", name: "Rhythm screen", group: "G-AF"),
            Entry(key: "vo2max", name: "VO₂max", group: "G-VO2"),
            Entry(key: "walking_hr", name: "Walking HR", group: nil),
            Entry(key: "bp_systolic", name: "Blood pressure, systolic", group: "G-BP"),
            Entry(key: "bp_diastolic", name: "Blood pressure, diastolic", group: "G-BP"),
        ]),
        ("Sleep", [
            Entry(key: "sleep_total", name: "Total sleep", group: nil),
            Entry(key: "sleep_need", name: "Sleep need", group: nil),
            Entry(key: "sleep_debt", name: "Sleep debt", group: nil),
            Entry(key: "sleep_performance", name: "Sleep performance", group: nil),
            Entry(key: "sleep_efficiency", name: "Sleep efficiency", group: nil),
            Entry(key: "sleep_consistency", name: "Sleep consistency (WHOOP)", group: nil),
            Entry(key: "sleep_deep", name: "Deep sleep", group: "G-STAGE"),
            Entry(key: "sleep_rem", name: "REM sleep", group: "G-STAGE"),
            Entry(key: "sri", name: "Regularity", group: nil),
            Entry(key: "chronotype_msf_sc", name: "Chronotype", group: nil),
            // Bug 32 / e-26 (b) (Mo 2026-10-14: fold the "Night screens" section into Sleep, "perfect"): the night-only
            // screens, filed the same way under Every measure › Sleep.
            Entry(key: "breathing_disturbance", name: "Breathing-disturbance screen (not a diagnosis)", group: "G-APNEA"),
            // Bug 22 (M-118): Apple's sleep goal is a sleep setting; it sat under Activity next to downhill snow.
            Entry(key: "sleep_goal", name: "Sleep goal (Apple)", group: nil),
        ]),
        ("Activity", [
            Entry(key: "strain", name: "Strain", group: "G-LOAD"),
            Entry(key: "steps", name: "Steps", group: "G-STEPS"),
            Entry(key: "calories_active", name: "Calories", group: "G-CAL"),
            Entry(key: "calories_total", name: "Total calories (WHOOP)", group: nil),
            Entry(key: "acwr", name: "Acute:chronic", group: "G-LOAD"),
            Entry(key: "ctl", name: "Fitness (CTL)", group: "G-LOAD"),
            Entry(key: "hrmax", name: "Max HR", group: "G-HRMAX"),
            Entry(key: "six_min_walk_distance", name: "Six-minute walk", group: nil),
            Entry(key: "walking_speed", name: "Walking speed", group: nil),
            Entry(key: "walking_step_length", name: "Step length", group: nil),
            Entry(key: "walking_double_support", name: "Double support time", group: nil),
            Entry(key: "walking_asymmetry", name: "Walking asymmetry", group: nil),
            Entry(key: "walking_steadiness", name: "Walking steadiness", group: nil),
            Entry(key: "stair_ascent_speed", name: "Stair ascent speed", group: nil),
            Entry(key: "stair_descent_speed", name: "Stair descent speed", group: nil),
            Entry(key: "physical_effort", name: "Physical effort", group: nil),
            Entry(key: "distance_walk_run", name: "Walking + running distance", group: nil),
            Entry(key: "flights_climbed", name: "Flights climbed", group: nil),
            Entry(key: "exercise_min", name: "Exercise minutes", group: nil),
            Entry(key: "stand_min", name: "Stand time", group: nil),
            Entry(key: "stand_hours", name: "Stand hours", group: nil),
            Entry(key: "headphone_audio_db", name: "Headphone audio level", group: nil),
            Entry(key: "environment_audio_db", name: "Environmental sound level", group: nil),
            Entry(key: "sound_reduction_db", name: "Headphone sound reduction", group: nil),
            Entry(key: "audio_exposure_events", name: "Loud-sound alerts", group: nil),
            Entry(key: "high_hr_events", name: "High heart rate alerts", group: nil),
            Entry(key: "low_cardio_fitness_events", name: "Low cardio fitness alerts", group: nil),
            Entry(key: "height", name: "Height", group: nil),
            // Bug 21 (round 2, 2026-10-14, M-160): body measures from Apple Health (a smart scale writes them there).
            Entry(key: "weight", name: "Weight", group: nil),
            Entry(key: "body_fat", name: "Body fat", group: nil),
            Entry(key: "lean_mass", name: "Lean body mass", group: nil),
            Entry(key: "bmi", name: "Body mass index", group: nil),
            Entry(key: "running_speed", name: "Running speed", group: nil),
            Entry(key: "snow_downhill_distance", name: "Downhill snow distance", group: nil),
            Entry(key: "ring_move_kcal", name: "Move ring (active energy)", group: nil),
            Entry(key: "ring_exercise_min", name: "Exercise ring", group: nil),
            Entry(key: "ring_stand_hours", name: "Stand ring", group: nil),
            // Wave 12 (2026-10-11, #82): pc.vitamin-d on the PC — Apple's daylight minutes and the estimate from them
            Entry(key: "daylight_min", name: "Time in daylight", group: nil),
            Entry(key: "vitamin_d_iu_est", name: "Sun vitamin D (estimate)", group: nil),
            // Wave W8 (2026-10-11): raw motion R21 — ALG-113 ENMO, ALG-114 wrist gait asymmetry (research)
            Entry(key: "enmo", name: "Movement intensity (ENMO)", group: nil),
            Entry(key: "imu_asym", name: "Gait asymmetry (wrist)", group: "G-GAIT"),
            Entry(key: "wrist_walk_steps", name: "Walking steps (wrist, estimate)", group: nil),
            Entry(key: "wrist_walk_cadence", name: "Walking cadence (wrist, estimate)", group: nil),
        ]),
        ("Body arousal & alertness", [
            Entry(key: "readiness", name: "Recovery", group: "G-READY"),
            Entry(key: "warning_sign", name: "Warning signs (worth noting)", group: "G-WARN"),
            Entry(key: "trend", name: "Trends vs your baseline", group: "G-TREND"),
            Entry(key: "stress", name: "Body arousal", group: "G-STRESS"),
            Entry(key: "alertness", name: "Predicted alertness (model estimate)", group: nil),
            Entry(key: "pvt_mean_rt", name: "Reaction time", group: nil),
            Entry(key: "pvt_lapses", name: "Reaction-test lapses", group: nil),
        ]),
        ("Substances", [
            Entry(key: "caffeine_bedtime", name: "Caffeine at bedtime", group: "G-CAFF"),
            Entry(key: "caffeine_cutoff", name: "Caffeine cut-off", group: "G-CAFF"),
            Entry(key: "vape_hits", name: "Vape hits", group: nil),
            Entry(key: "vape_first_after_wake", name: "First vape after waking", group: nil),
        ]),
        // Wave 1 (2026-10-11): screens and insights; each opens with its method, source and blank reasons. The "Night
        // screens" section was folded into Sleep (bug 32, e-26 b, 2026-10-14).
        ("Insights", [
            Entry(key: "score_drivers", name: "What moves your HRV", group: nil),
            Entry(key: "key_points", name: "Key points", group: nil),
            Entry(key: "percentile_self", name: "Percentile of you", group: nil),
            Entry(key: "body_age", name: "Body Age", group: "G-AGE"),
            Entry(key: "hydration_goal", name: "Hydration (EFSA reference)", group: "G-HYDRATION"),
            Entry(key: "activity_cost", name: "Activity cost", group: nil),
            Entry(key: "hr_recovery_60", name: "HR recovery at 60 s", group: nil),
            Entry(key: "hr_recovery_120", name: "HR recovery at 120 s", group: nil),
            Entry(key: "hr_recovery_tau", name: "HR recovery time constant (tau, estimate)", group: nil),
            Entry(key: "stress_onsets", name: "Arousal rises (count)", group: "G-STRESS"),
        ]),
        // W10 #96 (2026-10-11): measured labs, each with its draw date and source
        ("Labs", [
            Entry(key: "lab_albumin", name: "Albumin", group: nil),
            Entry(key: "lab_creatinine", name: "Creatinine", group: nil),
            Entry(key: "lab_glucose", name: "Glucose (fasting draw)", group: nil),
            Entry(key: "lab_crp", name: "hs-CRP", group: nil),
            Entry(key: "lab_lymphocyte_pct", name: "Lymphocytes %", group: nil),
            Entry(key: "lab_mcv", name: "MCV", group: nil),
            Entry(key: "lab_rdw", name: "RDW", group: nil),
            Entry(key: "lab_alp", name: "Alkaline phosphatase", group: nil),
            Entry(key: "lab_wbc", name: "White blood cells", group: nil),
            Entry(key: "lab_hba1c", name: "HbA1c", group: nil),
            Entry(key: "lab_total_cholesterol", name: "Total cholesterol", group: nil),
            Entry(key: "lab_bun", name: "Urea nitrogen (BUN)", group: nil),
            Entry(key: "lab_uric_acid", name: "Uric acid", group: nil),
            Entry(key: "lab_testosterone_total", name: "Testosterone, total", group: "G-HORMONE"),
            Entry(key: "lab_testosterone_free", name: "Testosterone, free", group: "G-HORMONE"),
            Entry(key: "lab_cortisol", name: "Cortisol (morning draw)", group: "G-HORMONE"),
            Entry(key: "lab_shbg", name: "SHBG", group: "G-HORMONE"),
            Entry(key: "lab_estradiol", name: "Estradiol", group: "G-HORMONE"),
            Entry(key: "lab_dhea_s", name: "DHEA-S", group: "G-HORMONE"),
            Entry(key: "lab_hdl_cholesterol", name: "HDL cholesterol", group: nil),
            Entry(key: "lab_ldl_cholesterol", name: "LDL cholesterol", group: nil),
            Entry(key: "lab_non_hdl_cholesterol", name: "Non-HDL cholesterol", group: nil),
            Entry(key: "lab_triglycerides", name: "Triglycerides", group: nil),
            Entry(key: "lab_chol_hdl_ratio", name: "Total cholesterol / HDL ratio", group: nil),
            Entry(key: "lab_apob", name: "ApoB", group: nil),
            Entry(key: "lab_lpa", name: "Lipoprotein(a)", group: nil),
            Entry(key: "lab_ldl_particle_number", name: "LDL particle number", group: nil),
            Entry(key: "lab_ldl_small", name: "LDL small", group: nil),
            Entry(key: "lab_ldl_medium", name: "LDL medium", group: nil),
            Entry(key: "lab_ldl_peak_size", name: "LDL peak size", group: nil),
            Entry(key: "lab_ldl_pattern", name: "LDL pattern", group: nil),
            Entry(key: "lab_hdl_large", name: "HDL large", group: nil),
            Entry(key: "lab_ferritin", name: "Ferritin", group: nil),
            Entry(key: "lab_homocysteine", name: "Homocysteine", group: nil),
            Entry(key: "lab_iron", name: "Iron", group: nil),
            Entry(key: "lab_iron_saturation", name: "Iron saturation", group: nil),
            Entry(key: "lab_iron_binding_capacity", name: "Iron binding capacity", group: nil),
            Entry(key: "lab_mma", name: "Methylmalonic acid (MMA)", group: nil),
            Entry(key: "lab_vitamin_d", name: "Vitamin D", group: nil),
            Entry(key: "lab_zinc", name: "Zinc", group: nil),
            Entry(key: "lab_magnesium_rbc", name: "Magnesium, RBC", group: nil),
            Entry(key: "lab_omega3_total", name: "Omega-3 total", group: nil),
            Entry(key: "lab_omega3_omegacheck", name: "Omega-3 total (OmegaCheck)", group: nil),
            Entry(key: "lab_omega6_total", name: "Omega-6 total", group: nil),
            Entry(key: "lab_omega6_3_ratio", name: "Omega-6 / omega-3 ratio", group: nil),
            Entry(key: "lab_omega3_dha", name: "Omega-3: DHA", group: nil),
            Entry(key: "lab_omega3_dpa", name: "Omega-3: DPA", group: nil),
            Entry(key: "lab_omega3_epa", name: "Omega-3: EPA", group: nil),
            Entry(key: "lab_omega6_arachidonic", name: "Omega-6: arachidonic acid", group: nil),
            Entry(key: "lab_omega6_linoleic", name: "Omega-6: linoleic acid", group: nil),
            Entry(key: "lab_aa_epa_ratio", name: "Arachidonic acid / EPA ratio", group: nil),
            Entry(key: "lab_hematocrit", name: "Hematocrit", group: nil),
            Entry(key: "lab_hemoglobin", name: "Hemoglobin", group: nil),
            Entry(key: "lab_rbc_count", name: "Red blood cells", group: nil),
            Entry(key: "lab_mch", name: "MCH", group: nil),
            Entry(key: "lab_mchc", name: "MCHC", group: nil),
            Entry(key: "lab_mpv", name: "Mean platelet volume", group: nil),
            Entry(key: "lab_platelets", name: "Platelets", group: nil),
            Entry(key: "lab_abo_group", name: "Blood group (ABO)", group: nil),
            Entry(key: "lab_rh_factor", name: "Rhesus (Rh) factor", group: nil),
            Entry(key: "lab_neutrophils_pct", name: "Neutrophils %", group: nil),
            Entry(key: "lab_monocytes_pct", name: "Monocytes %", group: nil),
            Entry(key: "lab_eosinophils_pct", name: "Eosinophils %", group: nil),
            Entry(key: "lab_basophils_pct", name: "Basophils %", group: nil),
            Entry(key: "lab_lymphocytes_abs", name: "Lymphocytes (count)", group: nil),
            Entry(key: "lab_neutrophils_abs", name: "Neutrophils (count)", group: nil),
            Entry(key: "lab_monocytes_abs", name: "Monocytes (count)", group: nil),
            Entry(key: "lab_eosinophils_abs", name: "Eosinophils (count)", group: nil),
            Entry(key: "lab_basophils_abs", name: "Basophils (count)", group: nil),
            Entry(key: "lab_egfr", name: "eGFR", group: nil),
            Entry(key: "lab_urine_albumin", name: "Albumin, random urine", group: nil),
            Entry(key: "lab_sodium", name: "Sodium", group: nil),
            Entry(key: "lab_potassium", name: "Potassium", group: nil),
            Entry(key: "lab_chloride", name: "Chloride", group: nil),
            Entry(key: "lab_carbon_dioxide", name: "Carbon dioxide", group: nil),
            Entry(key: "lab_calcium", name: "Calcium", group: nil),
            Entry(key: "lab_alt", name: "ALT", group: nil),
            Entry(key: "lab_ast", name: "AST", group: nil),
            Entry(key: "lab_ggt", name: "GGT", group: nil),
            Entry(key: "lab_globulin", name: "Globulin", group: nil),
            Entry(key: "lab_albumin_globulin_ratio", name: "Albumin / globulin ratio", group: nil),
            Entry(key: "lab_total_bilirubin", name: "Total bilirubin", group: nil),
            Entry(key: "lab_total_protein", name: "Total protein", group: nil),
            Entry(key: "lab_lh", name: "Luteinizing hormone (LH)", group: nil),
            Entry(key: "lab_fsh", name: "Follicle stimulating hormone (FSH)", group: nil),
            Entry(key: "lab_prolactin", name: "Prolactin", group: nil),
            Entry(key: "lab_psa_total", name: "PSA, total", group: nil),
            Entry(key: "lab_psa_free", name: "PSA, free", group: nil),
            Entry(key: "lab_psa_free_pct", name: "PSA, free %", group: nil),
            Entry(key: "lab_insulin", name: "Insulin", group: nil),
            Entry(key: "lab_leptin", name: "Leptin", group: nil),
            Entry(key: "lab_amylase", name: "Amylase", group: nil),
            Entry(key: "lab_lipase", name: "Lipase", group: nil),
            Entry(key: "lab_tsh", name: "TSH", group: nil),
            Entry(key: "lab_free_t4", name: "Free T4", group: nil),
            Entry(key: "lab_free_t3", name: "Free T3", group: nil),
            Entry(key: "lab_tpo_antibodies", name: "Thyroid peroxidase antibodies (TPO)", group: nil),
            Entry(key: "lab_tg_antibodies", name: "Thyroglobulin antibodies (TgAb)", group: nil),
            Entry(key: "lab_rheumatoid_factor", name: "Rheumatoid factor", group: nil),
            Entry(key: "lab_ana_screen", name: "ANA screen", group: nil),
            Entry(key: "lab_ana_pattern", name: "ANA pattern", group: nil),
            Entry(key: "lab_ana_titer", name: "ANA titer", group: nil),
            Entry(key: "lab_lead", name: "Lead", group: nil),
            Entry(key: "lab_mercury", name: "Mercury", group: nil),
            Entry(key: "lab_function_bio_age", name: "Biological age (Function's own score)", group: nil),
            Entry(key: "lab_urine_specific_gravity", name: "Urine specific gravity", group: nil),
            Entry(key: "lab_urine_ph", name: "Urine pH", group: nil),
            Entry(key: "lab_urine_appearance", name: "Urine appearance", group: nil),
            Entry(key: "lab_urine_color", name: "Urine color", group: nil),
            Entry(key: "lab_urine_bilirubin", name: "Urine bilirubin", group: nil),
            Entry(key: "lab_urine_glucose", name: "Urine glucose", group: nil),
            Entry(key: "lab_urine_ketones", name: "Urine ketones", group: nil),
            Entry(key: "lab_urine_protein", name: "Urine protein", group: nil),
            Entry(key: "lab_urine_nitrite", name: "Urine nitrite", group: nil),
            Entry(key: "lab_urine_leukocyte_esterase", name: "Urine leukocyte esterase", group: nil),
            Entry(key: "lab_urine_occult_blood", name: "Urine occult blood", group: nil),
            Entry(key: "lab_urine_rbc", name: "Urine red blood cells", group: nil),
            Entry(key: "lab_urine_wbc", name: "Urine white blood cells", group: nil),
            Entry(key: "lab_urine_squamous", name: "Urine squamous cells", group: nil),
            Entry(key: "lab_urine_bacteria", name: "Urine bacteria", group: nil),
            Entry(key: "lab_urine_hyaline_casts", name: "Urine hyaline casts", group: nil),
        ]),
    ]

    /// "Every measure" (wave 2, 2026-10-11; audit D3: 43 of 78 computed metrics could not be opened): EVERY registry
    /// metric (app/shared/contract/metric-registry.json = `MetricKey.allCases`), grouped, each row showing its newest
    /// value labelled with source and algorithm. app/tools/check_reachability.py reads the names in this block;
    /// OutputsTests checks it equals `MetricKey.allCases` exactly once each. Groups are the registry's.
    static let allMeasures: [(String, [Entry])] = [
        ("Heart rate & HRV", [
            Entry(key: "rhr", name: "Resting HR", group: nil),
            Entry(key: "hr_avg", name: "Average HR", group: nil),
            Entry(key: "hr_dip", name: "HR dip", group: nil),
            Entry(key: "hrmax", name: "Max HR", group: "G-HRMAX"),
            Entry(key: "walking_hr", name: "Walking HR (Apple)", group: nil),
            Entry(key: "bp_systolic", name: "Blood pressure, systolic (cuff)", group: "G-BP"),
            Entry(key: "bp_diastolic", name: "Blood pressure, diastolic (cuff)", group: "G-BP"),
            Entry(key: "hrv_rmssd", name: "HRV · RMSSD", group: "G-HRV"),
            Entry(key: "hrv_ln_rmssd", name: "HRV · ln RMSSD", group: "G-HRV"),
            Entry(key: "hrv_sdnn", name: "HRV · SDNN", group: "G-HRV"),
            Entry(key: "hrv_pnn50", name: "HRV · pNN50", group: "G-HRV"),
            Entry(key: "hrv_sd1", name: "HRV · Poincaré SD1", group: "G-HRV"),
            Entry(key: "hrv_sd2", name: "HRV · Poincaré SD2", group: "G-HRV"),
            Entry(key: "hrv_lf_hf", name: "HRV · LF/HF (lab, research)", group: nil),
            Entry(key: "hrv_lf", name: "HRV · LF power (lab, research)", group: nil),
            Entry(key: "hrv_hf", name: "HRV · HF power (lab, research)", group: nil),
            Entry(key: "hrv_sampen", name: "HRV · sample entropy", group: "G-HRV"),
            Entry(key: "rr_artefact", name: "Signal quality, base: R-R artefacts", group: nil),
            Entry(key: "ppg_sqi_good", name: "Signal quality, enhanced: good raw-pulse segments", group: nil),
            Entry(key: "af_screen", name: "Rhythm screen", group: "G-AF"),
            Entry(key: "ppg_hr", name: "Heart rate from the pulse (v26 PPG, ALG-108)", group: nil),
            Entry(key: "ppg_hrv_rmssd", name: "Spot HRV from the pulse (v26 PPG, ALG-108)", group: nil),
            Entry(key: "optical_saturated_pct", name: "Optical signal quality: saturated seconds (strap, research)",
                  group: nil),
            Entry(key: "optical_psnr", name: "Optical signal quality: pSNR (strap, research)", group: nil),
            Entry(key: "optical_logvar", name: "Optical signal quality: log-variance (strap, research)", group: nil),
            Entry(key: "pulse_rise_time", name: "Pulse shape: rise time (green block 0, ALG-015)", group: "G-VASC"),
            Entry(key: "pulse_width_half", name: "Pulse shape: width at half height (green block 0, ALG-015)",
                  group: "G-VASC"),
            Entry(key: "pulse_notch_time", name: "Pulse shape: dicrotic notch time (estimate, ALG-015:notch)", group: "G-VASC"),
            Entry(key: "pulse_reflection_index", name: "Pulse shape: reflection index (estimate, ALG-015:notch)", group: "G-VASC"),
            Entry(key: "pulse_notch_rate", name: "Pulse shape: share of beats with a notch found (ALG-015:notch)", group: "G-VASC"),
        ]),
        ("Breathing, SpO₂ & temperature", [
            Entry(key: "resp_rate", name: "Breathing rate", group: "G-RESP"),
            Entry(key: "spo2_strap_mean", name: "SpO₂ byte (mean)", group: "G-SPO2"),
            Entry(key: "spo2_strap_min", name: "SpO₂ byte (lowest)", group: "G-SPO2"),
            Entry(key: "ms_spo2_dst", name: "SpO₂ % from pulse (script)", group: "G-SPO2"),
            Entry(key: "spo2_gate_nights", name: "SpO₂ check against WHOOP (paired nights)", group: "G-SPO2"),
            Entry(key: "spo2_pct", name: "SpO₂ % (WHOOP / Apple Health / red-IR estimate)", group: "G-SPO2"),
            Entry(key: "skin_temp_c", name: "Skin temperature °C (WHOOP / Apple Health)", group: nil),
            Entry(key: "ms_odi", name: "Oxygen desaturation index (script)", group: "G-APNEA"),
            Entry(key: "ms_ahi", name: "Apnea–hypopnea index (script)", group: "G-APNEA"),
            Entry(key: "skin_temp_dev", name: "Skin temperature (raw)", group: "G-TEMP"),
        ]),
        ("Sleep", [
            Entry(key: "sleep_total", name: "Total sleep", group: nil),
            Entry(key: "sleep_need", name: "Sleep need", group: nil),
            Entry(key: "sleep_debt", name: "Sleep debt", group: nil),
            Entry(key: "sleep_performance", name: "Sleep performance", group: nil),
            Entry(key: "sleep_efficiency", name: "Sleep efficiency", group: nil),
            Entry(key: "sleep_consistency", name: "Sleep consistency (WHOOP)", group: nil),
            Entry(key: "sleep_latency", name: "Time to fall asleep", group: nil),
            Entry(key: "waso", name: "Awake after sleep onset", group: nil),
            Entry(key: "rem_latency", name: "REM latency", group: nil),
            Entry(key: "awakenings", name: "Awakenings", group: nil),
            Entry(key: "sleep_onset", name: "Sleep onset", group: nil),
            Entry(key: "wake_time", name: "Wake time", group: nil),
            Entry(key: "bedtime_recommended", name: "Recommended bedtime", group: nil),
            Entry(key: "sleep_deep", name: "Deep sleep", group: "G-STAGE"),
            Entry(key: "sleep_light", name: "Light sleep", group: "G-STAGE"),
            Entry(key: "sleep_rem", name: "REM sleep", group: "G-STAGE"),
            Entry(key: "sleep_wake", name: "Awake in bed", group: "G-STAGE"),
            // Bug 32 (round 2, 2026-10-14): the night-only breathing screens sit under Sleep in both lists (they were
            // under Breathing here and under "Night screens" above).
            Entry(key: "breathing_disturbance", name: "Breathing-disturbance screen (CVHR, not a diagnosis)", group: "G-APNEA"),
            // Bug 22 (M-118): moved from Load & activity.
            Entry(key: "sleep_goal", name: "Sleep goal (Apple)", group: nil),
        ]),
        ("Rhythm & regularity", [
            Entry(key: "sri", name: "Regularity (SRI)", group: nil),
            Entry(key: "circadian_is", name: "Interdaily stability", group: nil),
            Entry(key: "circadian_iv", name: "Intradaily variability", group: nil),
            Entry(key: "circadian_ra", name: "Relative amplitude", group: nil),
            Entry(key: "circadian_l5", name: "Least active 5 h", group: nil),
            Entry(key: "circadian_m10", name: "Most active 10 h", group: nil),
            Entry(key: "chronotype_msf_sc", name: "Chronotype (MSFsc)", group: nil),
        ]),
        ("Load & activity", [
            Entry(key: "strain", name: "Strain", group: "G-LOAD"),
            Entry(key: "acwr", name: "Acute:chronic", group: "G-LOAD"),
            Entry(key: "ctl", name: "Fitness (CTL)", group: "G-LOAD"),
            Entry(key: "atl", name: "Fatigue (ATL)", group: "G-LOAD"),
            Entry(key: "tsb", name: "Form (TSB)", group: "G-LOAD"),
            Entry(key: "load_week", name: "This week vs 4-week average", group: "G-LOAD"),
            Entry(key: "load_session", name: "Load score vs your sessions", group: "G-LOAD"),
            Entry(key: "vo2max", name: "VO₂max", group: "G-VO2"),
            Entry(key: "fitness_age", name: "Fitness age", group: "G-VO2"),
            Entry(key: "six_min_walk_distance", name: "Six-minute walk (Apple estimate)", group: nil),
            Entry(key: "walking_speed", name: "Walking speed (Apple)", group: nil),
            Entry(key: "walking_step_length", name: "Step length (Apple)", group: nil),
            Entry(key: "walking_double_support", name: "Double support time (Apple)", group: nil),
            Entry(key: "walking_asymmetry", name: "Walking asymmetry (Apple)", group: nil),
            Entry(key: "walking_steadiness", name: "Walking steadiness (Apple)", group: nil),
            Entry(key: "stair_ascent_speed", name: "Stair ascent speed (Apple)", group: nil),
            Entry(key: "stair_descent_speed", name: "Stair descent speed (Apple)", group: nil),
            Entry(key: "physical_effort", name: "Physical effort (Apple)", group: nil),
            Entry(key: "distance_walk_run", name: "Walking + running distance (Apple)", group: nil),
            Entry(key: "flights_climbed", name: "Flights climbed (Apple)", group: nil),
            Entry(key: "exercise_min", name: "Exercise minutes (Apple)", group: nil),
            Entry(key: "stand_min", name: "Stand time (Apple)", group: nil),
            Entry(key: "stand_hours", name: "Stand hours (Apple)", group: nil),
            Entry(key: "headphone_audio_db", name: "Headphone audio level (Apple)", group: nil),
            Entry(key: "environment_audio_db", name: "Environmental sound level (Apple)", group: nil),
            Entry(key: "sound_reduction_db", name: "Headphone sound reduction (Apple)", group: nil),
            Entry(key: "audio_exposure_events", name: "Loud-sound alerts (Apple)", group: nil),
            Entry(key: "high_hr_events", name: "High heart rate alerts (Apple)", group: nil),
            Entry(key: "low_cardio_fitness_events", name: "Low cardio fitness alerts (Apple)", group: nil),
            Entry(key: "height", name: "Height (Apple)", group: nil),
            // Bug 21 (round 2, 2026-10-14): Apple Health body measures (registry rows added the same day).
            Entry(key: "weight", name: "Weight (Apple)", group: nil),
            Entry(key: "body_fat", name: "Body fat (Apple)", group: nil),
            Entry(key: "lean_mass", name: "Lean body mass (Apple)", group: nil),
            Entry(key: "bmi", name: "Body mass index (Apple)", group: nil),
            Entry(key: "running_speed", name: "Running speed (Apple)", group: nil),
            Entry(key: "snow_downhill_distance", name: "Downhill snow distance (Apple)", group: nil),
            Entry(key: "ring_move_kcal", name: "Move ring (active energy) (Apple)", group: nil),
            Entry(key: "ring_exercise_min", name: "Exercise ring (Apple)", group: nil),
            Entry(key: "ring_stand_hours", name: "Stand ring (Apple)", group: nil),
            Entry(key: "daylight_min", name: "Time in daylight (Apple Watch)", group: nil),
            Entry(key: "vitamin_d_iu_est", name: "Sun vitamin D, IU-equivalent (estimate, PC)", group: nil),
            Entry(key: "steps", name: "Steps", group: "G-STEPS"),
            Entry(key: "calories_active", name: "Active calories", group: "G-CAL"),
            Entry(key: "calories_basal", name: "Basal calories", group: "G-CAL"),
            Entry(key: "calories_total", name: "Total calories (WHOOP)", group: nil),
            Entry(key: "enmo", name: "Movement intensity (ENMO, raw motion)", group: nil),
            Entry(key: "imu_asym", name: "Gait asymmetry (wrist, raw motion)", group: "G-GAIT"),
            Entry(key: "wrist_walk_steps", name: "Walking steps (wrist, estimate)", group: nil),
            Entry(key: "wrist_walk_cadence", name: "Walking cadence (wrist, estimate)", group: nil),
            Entry(key: "hr_recovery_60", name: "HR recovery at 60 s", group: nil),
            Entry(key: "hr_recovery_120", name: "HR recovery at 120 s", group: nil),
            Entry(key: "hr_recovery_tau", name: "HR recovery time constant (tau, estimate)", group: nil),
            Entry(key: "workout_hr_avg", name: "Workout average HR (WHOOP, by activity)", group: nil),
            Entry(key: "workout_hr_max", name: "Workout max HR (WHOOP, by activity)", group: nil),
            Entry(key: "workout_kcal", name: "Workout energy (WHOOP, by activity)", group: nil),
            Entry(key: "workout_duration", name: "Workout duration (WHOOP, by activity)", group: nil),
            Entry(key: "workout_hr_zone_pct", name: "Workout time in HR zone (WHOOP, by activity)", group: nil),
            Entry(key: "activity_cost", name: "Activity cost", group: nil),
            Entry(key: "hydration_goal", name: "Hydration (EFSA reference)", group: "G-HYDRATION"),
        ]),
        ("Recovery, body arousal & alertness", [
            Entry(key: "readiness", name: "Recovery", group: "G-READY"),
            Entry(key: "warning_sign", name: "Warning signs (worth noting)", group: "G-WARN"),
            Entry(key: "trend", name: "Trends vs your baseline", group: "G-TREND"),
            Entry(key: "trend_level", name: "Trend level (0 nothing, 1 worth noting, 2 stronger)", group: "G-TREND"),
            Entry(key: "stress", name: "Body arousal", group: "G-STRESS"),
            Entry(key: "anomaly", name: "Unusual-night distance", group: nil),
            Entry(key: "alertness", name: "Predicted alertness (model estimate)", group: nil),
            Entry(key: "pvt_mean_rt", name: "Reaction time", group: nil),
            Entry(key: "pvt_lapses", name: "Reaction-test lapses", group: nil),
            // Wave 3 (PC): ALG-053 check-in model, ALG-055 crash finder
            Entry(key: "energy_pred", name: "Expected energy (check-in model)", group: nil),
            Entry(key: "focus_pred", name: "Expected focus (check-in model)", group: nil),
            Entry(key: "mood_pred", name: "Expected mood (check-in model)", group: nil),
            Entry(key: "kss_pred", name: "Expected sleepiness, KSS (check-in model)", group: nil),
            Entry(key: "pvt_rt_pred", name: "Expected reaction time (check-in model)", group: nil),
            Entry(key: "crash_effect", name: "Crash finder: slowdown after an exposure", group: nil),
            Entry(key: "stress_onsets", name: "Arousal rises (count)", group: "G-STRESS"),
            Entry(key: "score_drivers", name: "What moves your HRV", group: nil),
            Entry(key: "percentile_self", name: "Percentile of you", group: nil),
            Entry(key: "key_points", name: "Key points", group: nil),
        ]),
        ("Substances", [
            Entry(key: "caffeine_now", name: "Caffeine now", group: nil),
            Entry(key: "caffeine_bedtime", name: "Caffeine at bedtime", group: "G-CAFF"),
            Entry(key: "caffeine_cutoff", name: "Caffeine cut-off", group: "G-CAFF"),
            Entry(key: "vape_hits", name: "Vape hits", group: nil),
            Entry(key: "vape_first_after_wake", name: "First vape after waking", group: nil),
            // Wave 3 (PC): ALG-062 personal caffeine model
            Entry(key: "caffeine_half_life", name: "Your caffeine half-life", group: "G-LABS"),
            Entry(key: "caffeine_sleep_sensitivity", name: "Caffeine sleep sensitivity", group: "G-LABS"),
        ]),
        ("Ages & labs", [
            Entry(key: "phenoage", name: "PhenoAge", group: "G-AGE"),
            Entry(key: "phenoage_accel", name: "PhenoAge acceleration", group: "G-AGE"),
            // Wave 3 (PC): ALG-077
            Entry(key: "kdm_bioage", name: "Biological age (KDM)", group: "G-AGE"),
            Entry(key: "kdm_bioage_accel", name: "Biological age acceleration (KDM)", group: "G-AGE"),
            Entry(key: "hd_distance", name: "Homeostatic dysregulation", group: "G-AGE"),
            // W10 #96: measured lab values per draw (pc.labs@1)
            Entry(key: "lab_albumin", name: "Albumin", group: nil),
            Entry(key: "lab_creatinine", name: "Creatinine", group: nil),
            Entry(key: "lab_glucose", name: "Glucose (fasting draw)", group: nil),
            Entry(key: "lab_crp", name: "hs-CRP", group: nil),
            Entry(key: "lab_lymphocyte_pct", name: "Lymphocytes %", group: nil),
            Entry(key: "lab_mcv", name: "MCV", group: nil),
            Entry(key: "lab_rdw", name: "RDW", group: nil),
            Entry(key: "lab_alp", name: "Alkaline phosphatase", group: nil),
            Entry(key: "lab_wbc", name: "White blood cells", group: nil),
            Entry(key: "lab_hba1c", name: "HbA1c", group: nil),
            Entry(key: "lab_total_cholesterol", name: "Total cholesterol", group: nil),
            Entry(key: "lab_bun", name: "Urea nitrogen (BUN)", group: nil),
            Entry(key: "lab_uric_acid", name: "Uric acid", group: nil),
            Entry(key: "lab_testosterone_total", name: "Testosterone, total", group: "G-HORMONE"),
            Entry(key: "lab_testosterone_free", name: "Testosterone, free", group: "G-HORMONE"),
            Entry(key: "lab_cortisol", name: "Cortisol (morning draw)", group: "G-HORMONE"),
            Entry(key: "lab_shbg", name: "SHBG", group: "G-HORMONE"),
            Entry(key: "lab_estradiol", name: "Estradiol", group: "G-HORMONE"),
            Entry(key: "lab_dhea_s", name: "DHEA-S", group: "G-HORMONE"),
            Entry(key: "lab_hdl_cholesterol", name: "HDL cholesterol", group: nil),
            Entry(key: "lab_ldl_cholesterol", name: "LDL cholesterol", group: nil),
            Entry(key: "lab_non_hdl_cholesterol", name: "Non-HDL cholesterol", group: nil),
            Entry(key: "lab_triglycerides", name: "Triglycerides", group: nil),
            Entry(key: "lab_chol_hdl_ratio", name: "Total cholesterol / HDL ratio", group: nil),
            Entry(key: "lab_apob", name: "ApoB", group: nil),
            Entry(key: "lab_lpa", name: "Lipoprotein(a)", group: nil),
            Entry(key: "lab_ldl_particle_number", name: "LDL particle number", group: nil),
            Entry(key: "lab_ldl_small", name: "LDL small", group: nil),
            Entry(key: "lab_ldl_medium", name: "LDL medium", group: nil),
            Entry(key: "lab_ldl_peak_size", name: "LDL peak size", group: nil),
            Entry(key: "lab_ldl_pattern", name: "LDL pattern", group: nil),
            Entry(key: "lab_hdl_large", name: "HDL large", group: nil),
            Entry(key: "lab_ferritin", name: "Ferritin", group: nil),
            Entry(key: "lab_homocysteine", name: "Homocysteine", group: nil),
            Entry(key: "lab_iron", name: "Iron", group: nil),
            Entry(key: "lab_iron_saturation", name: "Iron saturation", group: nil),
            Entry(key: "lab_iron_binding_capacity", name: "Iron binding capacity", group: nil),
            Entry(key: "lab_mma", name: "Methylmalonic acid (MMA)", group: nil),
            Entry(key: "lab_vitamin_d", name: "Vitamin D", group: nil),
            Entry(key: "lab_zinc", name: "Zinc", group: nil),
            Entry(key: "lab_magnesium_rbc", name: "Magnesium, RBC", group: nil),
            Entry(key: "lab_omega3_total", name: "Omega-3 total", group: nil),
            Entry(key: "lab_omega3_omegacheck", name: "Omega-3 total (OmegaCheck)", group: nil),
            Entry(key: "lab_omega6_total", name: "Omega-6 total", group: nil),
            Entry(key: "lab_omega6_3_ratio", name: "Omega-6 / omega-3 ratio", group: nil),
            Entry(key: "lab_omega3_dha", name: "Omega-3: DHA", group: nil),
            Entry(key: "lab_omega3_dpa", name: "Omega-3: DPA", group: nil),
            Entry(key: "lab_omega3_epa", name: "Omega-3: EPA", group: nil),
            Entry(key: "lab_omega6_arachidonic", name: "Omega-6: arachidonic acid", group: nil),
            Entry(key: "lab_omega6_linoleic", name: "Omega-6: linoleic acid", group: nil),
            Entry(key: "lab_aa_epa_ratio", name: "Arachidonic acid / EPA ratio", group: nil),
            Entry(key: "lab_hematocrit", name: "Hematocrit", group: nil),
            Entry(key: "lab_hemoglobin", name: "Hemoglobin", group: nil),
            Entry(key: "lab_rbc_count", name: "Red blood cells", group: nil),
            Entry(key: "lab_mch", name: "MCH", group: nil),
            Entry(key: "lab_mchc", name: "MCHC", group: nil),
            Entry(key: "lab_mpv", name: "Mean platelet volume", group: nil),
            Entry(key: "lab_platelets", name: "Platelets", group: nil),
            Entry(key: "lab_abo_group", name: "Blood group (ABO)", group: nil),
            Entry(key: "lab_rh_factor", name: "Rhesus (Rh) factor", group: nil),
            Entry(key: "lab_neutrophils_pct", name: "Neutrophils %", group: nil),
            Entry(key: "lab_monocytes_pct", name: "Monocytes %", group: nil),
            Entry(key: "lab_eosinophils_pct", name: "Eosinophils %", group: nil),
            Entry(key: "lab_basophils_pct", name: "Basophils %", group: nil),
            Entry(key: "lab_lymphocytes_abs", name: "Lymphocytes (count)", group: nil),
            Entry(key: "lab_neutrophils_abs", name: "Neutrophils (count)", group: nil),
            Entry(key: "lab_monocytes_abs", name: "Monocytes (count)", group: nil),
            Entry(key: "lab_eosinophils_abs", name: "Eosinophils (count)", group: nil),
            Entry(key: "lab_basophils_abs", name: "Basophils (count)", group: nil),
            Entry(key: "lab_egfr", name: "eGFR", group: nil),
            Entry(key: "lab_urine_albumin", name: "Albumin, random urine", group: nil),
            Entry(key: "lab_sodium", name: "Sodium", group: nil),
            Entry(key: "lab_potassium", name: "Potassium", group: nil),
            Entry(key: "lab_chloride", name: "Chloride", group: nil),
            Entry(key: "lab_carbon_dioxide", name: "Carbon dioxide", group: nil),
            Entry(key: "lab_calcium", name: "Calcium", group: nil),
            Entry(key: "lab_alt", name: "ALT", group: nil),
            Entry(key: "lab_ast", name: "AST", group: nil),
            Entry(key: "lab_ggt", name: "GGT", group: nil),
            Entry(key: "lab_globulin", name: "Globulin", group: nil),
            Entry(key: "lab_albumin_globulin_ratio", name: "Albumin / globulin ratio", group: nil),
            Entry(key: "lab_total_bilirubin", name: "Total bilirubin", group: nil),
            Entry(key: "lab_total_protein", name: "Total protein", group: nil),
            Entry(key: "lab_lh", name: "Luteinizing hormone (LH)", group: nil),
            Entry(key: "lab_fsh", name: "Follicle stimulating hormone (FSH)", group: nil),
            Entry(key: "lab_prolactin", name: "Prolactin", group: nil),
            Entry(key: "lab_psa_total", name: "PSA, total", group: nil),
            Entry(key: "lab_psa_free", name: "PSA, free", group: nil),
            Entry(key: "lab_psa_free_pct", name: "PSA, free %", group: nil),
            Entry(key: "lab_insulin", name: "Insulin", group: nil),
            Entry(key: "lab_leptin", name: "Leptin", group: nil),
            Entry(key: "lab_amylase", name: "Amylase", group: nil),
            Entry(key: "lab_lipase", name: "Lipase", group: nil),
            Entry(key: "lab_tsh", name: "TSH", group: nil),
            Entry(key: "lab_free_t4", name: "Free T4", group: nil),
            Entry(key: "lab_free_t3", name: "Free T3", group: nil),
            Entry(key: "lab_tpo_antibodies", name: "Thyroid peroxidase antibodies (TPO)", group: nil),
            Entry(key: "lab_tg_antibodies", name: "Thyroglobulin antibodies (TgAb)", group: nil),
            Entry(key: "lab_rheumatoid_factor", name: "Rheumatoid factor", group: nil),
            Entry(key: "lab_ana_screen", name: "ANA screen", group: nil),
            Entry(key: "lab_ana_pattern", name: "ANA pattern", group: nil),
            Entry(key: "lab_ana_titer", name: "ANA titer", group: nil),
            Entry(key: "lab_lead", name: "Lead", group: nil),
            Entry(key: "lab_mercury", name: "Mercury", group: nil),
            Entry(key: "lab_function_bio_age", name: "Biological age (Function's own score)", group: nil),
            Entry(key: "lab_urine_specific_gravity", name: "Urine specific gravity", group: nil),
            Entry(key: "lab_urine_ph", name: "Urine pH", group: nil),
            Entry(key: "lab_urine_appearance", name: "Urine appearance", group: nil),
            Entry(key: "lab_urine_color", name: "Urine color", group: nil),
            Entry(key: "lab_urine_bilirubin", name: "Urine bilirubin", group: nil),
            Entry(key: "lab_urine_glucose", name: "Urine glucose", group: nil),
            Entry(key: "lab_urine_ketones", name: "Urine ketones", group: nil),
            Entry(key: "lab_urine_protein", name: "Urine protein", group: nil),
            Entry(key: "lab_urine_nitrite", name: "Urine nitrite", group: nil),
            Entry(key: "lab_urine_leukocyte_esterase", name: "Urine leukocyte esterase", group: nil),
            Entry(key: "lab_urine_occult_blood", name: "Urine occult blood", group: nil),
            Entry(key: "lab_urine_rbc", name: "Urine red blood cells", group: nil),
            Entry(key: "lab_urine_wbc", name: "Urine white blood cells", group: nil),
            Entry(key: "lab_urine_squamous", name: "Urine squamous cells", group: nil),
            Entry(key: "lab_urine_bacteria", name: "Urine bacteria", group: nil),
            Entry(key: "lab_urine_hyaline_casts", name: "Urine hyaline casts", group: nil),
            Entry(key: "ms_lab_hba1c", name: "HbA1c (labs, script)", group: "G-LABS"),
            Entry(key: "ms_lab_apob", name: "ApoB (labs, script)", group: "G-LABS"),
            Entry(key: "ms_lab_ntprobnp", name: "NT-proBNP (labs, script)", group: "G-LABS"),
            Entry(key: "ms_lab_ferritin", name: "Ferritin (labs, script)", group: "G-LABS"),
            Entry(key: "ms_lab_homa_ir", name: "HOMA-IR (labs, script)", group: "G-LABS"),
            Entry(key: "ms_genetic_bp_prior", name: "Lp(a) elevated flag: static context (paper)", group: "G-LABS"),
            Entry(key: "body_age", name: "Body Age", group: "G-AGE"),
        ]),
        ("Mo's script on the PC", [
            Entry(key: "ms_bp_sbp", name: "BP systolic (script)", group: "G-BP"),
            Entry(key: "ms_bp_dbp", name: "BP diastolic (script)", group: "G-BP"),
            Entry(key: "ms_stroke_volume", name: "Heart-rate drift at steady effort: stroke-volume proxy (theory + small studies)", group: "G-SV"),
            Entry(key: "ms_cfpwv", name: "Pulse arrival time change: stiffness proxy (paper, weak)", group: "G-VASC"),
            Entry(key: "ms_stiffness_index", name: "Pulse-shape stiffness index change: stiffness proxy (paper, finger)", group: "G-VASC"),
            Entry(key: "ms_ppg_aix", name: "Reflection index change: pulse-shape proxy (paper, finger)", group: "G-VASC"),
            Entry(key: "ms_lvedp_anchor", name: "NT-proBNP vs 125 ng/L: filling-pressure lab line (paper)", group: "G-LVEDP"),
            Entry(key: "ms_lvedp_index", name: "Night resting HR vs baseline: filling-pressure line (paper, patients)", group: "G-LVEDP"),
            Entry(key: "ms_testosterone_proxy", name: "Testosterone proxy (script)", group: "G-HORMONE"),
            Entry(key: "ms_cortisol_car_proxy", name: "Morning HRV change: stress-axis proxy (theory + small studies)", group: "G-HORMONE"),
            Entry(key: "ms_glucose_risk_proxy", name: "Post-meal heart-rate response: glucose proxy (theory + small studies)", group: "G-GLUCOSE"),
            Entry(key: "ms_muscle_injury_proxy", name: "Recovery cost, lines beyond usual: soreness proxy (small studies)", group: "G-MUSCLE"),
            Entry(key: "ms_sqi", name: "Signal quality (script)", group: "G-SQI"),
            Entry(key: "ms_fuse", name: "Fused estimate (script)", group: "G-SQI"),
        ]),
        ("Comparisons & causes", [
            Entry(key: "agreement_spearman", name: "Method agreement ρ", group: nil),
            Entry(key: "agreement_bias", name: "Method agreement bias", group: nil),
            Entry(key: "cause_odds_ratio", name: "Cause finder odds ratio", group: "G-CAUSE"),
            Entry(key: "cause_lag_effect", name: "Lag effect, 0–7 days", group: "G-CAUSE"),
        ]),
    ]

    static let research: [(String, String)] = [("inspector", "Record inspector"), ("capture", "Capture session"),
                                               ("retention", "Raw retention")]

    /// Search over a group: its title, id, member labels, variants and codenames.
    static func matches(_ g: GroupInfo, _ q: String) -> Bool {
        guard !q.isEmpty else { return true }
        var hay = [g.title, g.id]
        for m in g.members { hay += [m.label, m.variant, m.codename ?? ""] }
        return hay.contains { $0.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }

    /// Bug 24 (round 2, 2026-10-14, M-033/M-036): plain-English notes for metrics whose rows had no note, so a blank
    /// or a number is explained on the metric screen: what it is, how it is worked out, when it stays blank.
    static let explainers: [String: (title: String, lines: [String])] = [
        "stress": ("What body arousal is", [
            "How far your heart rate and heart-rate variability sit from your own usual for that hour of the day, in "
                + "still 5-minute daytime windows only (windows with movement, workouts and time off the wrist are left "
                + "out). 0 = calm, 1.5 = your usual, 3 = well above it.",
            "It describes the arousal of your body, not your mind: caffeine, a tense moment, a heavy meal, heat, "
                + "excitement or an illness coming on can all raise it. It is not mood and not a stress level, and there "
                + "is no stress label to check it against. An estimate from your strap, not WHOOP's Stress Monitor.",
            "This replaces the old 'stress' number (Mo's decision, Oct 17 2026). The noop daily score, the Baevsky "
                + "index, the overnight 0-100 and the weeks-long drift were removed as duplicates.",
        ]),
        "breathing_disturbance": ("What the breathing-disturbance screen is", [
            "A screen, never a diagnosis. It counts regular, repeating dips in your heart rate during sleep (cyclic "
                + "variation of heart rate, CVHR), the pattern that breathing pauses can leave in heart rate (Hayano 2011, "
                + "checked on ECG, not on a wrist strap).",
            "It can also fire on an irregular rhythm, periodic breathing or a broken night, and beta-blockers blunt it. "
                + "It is not an apnea-hypopnea index and not a reason to start or stop treatment; if it keeps flagging, "
                + "mention it to a doctor. Pauses and the desaturation index stay blank: they need a breathing waveform "
                + "or continuous SpO2 in %.",
        ]),
        "stress_onsets": ("What an arousal rise is", [
            "A count of moments today when your heart-rate variability dropped and your heart rate rose together while "
                + "you were still, from the whoop-rs detector. A pattern hint about your body, not a stress or mood "
                + "reading; an estimate.",
        ]),
        "hr_dip": ("What the night heart-rate dip is", [
            "How far your heart rate falls in sleep compared with the day before: (day average - sleep average) / day average, "
                + "from 1-minute medians. Day = your awake heart rate from 10:00 to 20:00 the day before (all awake hours "
                + "if that window is short).",
            "Shown against your own last 14 nights. Below 10 % it is called blunted (the cut-off used in Ben-Dov 2007, "
                + "Arch Intern Med 167:2116, and the CHAMP1ON diabetes cohort). Those studies compared groups of people; "
                + "for one person this is a trend to watch, not a risk score and not a diagnosis.",
        ]),
        "rr_artefact": ("What signal quality (base) is", [
            "The share of your night's heartbeat intervals that needed correcting or removing (extra or missed beats, "
                + "ectopic-like jumps), using the Lipponen and Tarvainen 2019 method (J Med Eng Technol 43:173). Lower is "
                + "cleaner. This is the base readout, always available when there are beats.",
            "The enhanced readout is the share of good 10 s pieces of the raw pulse wave, when raw optical was recorded.",
        ]),
        "ppg_sqi_good": ("What signal quality (enhanced) is", [
            "The share of 10-second pieces of the night's raw green pulse wave that look like a clean pulse: the skewness "
                + "quality index of Elgendi 2016 (Bioengineering 3:21). Higher is cleaner.",
            "The 10 s piece and the cut-off (0.3) are our own starting values, not from a paper, and the number is "
                + "decoded, untested. Blank when raw optical (R20) was not recorded for the night.",
        ]),
        "optical_saturated_pct": ("What optical saturated seconds are", [
            "The share of asleep seconds in which the strap's light sensor was pinned at its limit, so the pulse "
                + "signal in that second is unreliable. Lower is better. It is a quality check, not a heart measurement.",
            "Where it comes from: the strap writes a small quality record with every one-second heart record (its R18 "
                + "record: a saturated flag, pSNR and log-variance, laid out as in the OpenStrap source). The app keeps "
                + "them and summarises the night. Saturated, pSNR and log-variance are three views of the same pulse "
                + "signal's quality.",
            "Two sources. Normally the strap's own per-second saturation bit (decoded, untested). If the night has "
                + "none, the app counts raw-optical seconds where a sensor slot sat at its converter limit for 3 or "
                + "more samples (the same ADC_CLIPPED test as the pulse cleaner ALG-144): an estimate, and the row's "
                + "note says which one it was. Raw optical needs the PPG research switch on during the night.",
            "Blank, with the reason shown, when the night has neither the strap's quality bits nor raw optical.",
        ]),
        "optical_psnr": ("What optical pSNR is", [
            "The strap's own per-second signal-to-noise figure for the light sensor it chose, in dB. Higher means a "
                + "cleaner pulse signal; -128 means the strap said not available, so those seconds are left out.",
            "Where it comes from: the strap's quality record in each one-second heart record (R18), one value per "
                + "light sensor, which the app averages and takes the night's median of. What the \"p\" stands for is "
                + "unchecked; the source gives no good or bad line.",
            "The scale is the band's own and decoded, untested: compare your nights with each other, there is no "
                + "good or bad line. Shown as the night's median. Blank when the strap's quality fields were not stored.",
        ]),
        "optical_logvar": ("What optical log-variance is", [
            "The strap's own per-second measure of how noisy the light signal was: nearer -5 is cleaner, nearer 0 is "
                + "noisier. Shown as the night's median.",
            "Where it comes from: the log of the variance of the signal, worked out by the strap itself and sent in the "
                + "same one-second quality record (R18) as saturated and pSNR. It is the band's own scale, not a unit.",
            "The scale is the band's own and decoded, untested: compare nights, there is no good or bad line. Blank "
                + "when the strap's quality fields were not stored for the night.",
        ]),
    ]

    static func entry(_ key: String) -> Entry? {
        for (_, list) in sections { if let e = list.first(where: { $0.key == key }) { return e } }
        for (_, list) in allMeasures { if let e = list.first(where: { $0.key == key }) { return e } }
        return nil
    }

    static func name(_ key: String) -> String { entry(key)?.name ?? key }

    /// Search: names, registry keys, group ids, method ids and codenames ("Loop", "ALG-010").
    static func matches(_ e: Entry, _ q: String) -> Bool {
        guard !q.isEmpty else { return true }
        var hay = [e.name, e.key, e.group ?? ""]
        if let g = e.group.flatMap(GroupCatalogue.group) {
            hay += g.members.flatMap { [$0.label, $0.variant, $0.codename ?? ""] }
        }
        return hay.contains { $0.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }
}

public enum ExplorePresenter {
    public static func make(_ s: PresenterSnapshot) -> ExploreState {
        let q = s.explore.query.trimmingCharacters(in: .whitespacesAndNewlines)
        var sections: [CatalogueSection] = []
        for (i, (title, list)) in ExploreCatalogue.sections.enumerated() {
            // Bug 25 (round 2, 2026-10-14, M-222): section rows carry a value too (they were plain names), so Resting HR
            // under Heart & lungs shows its number. Same pick as Every measure (newest, labelled with its source and
            // algorithm); today's own value wins when there is one, and for a grouped metric that is the member you
            // read (your primary pick).
            let entries = Outputs.measureEntries(s, list.filter { ExploreCatalogue.matches($0, q) }).map { e in
                var entry = e
                if Outputs.todayInPeriod(s), let m = s.metric(entry.key), m.value != nil {
                    entry.value = s.display(m)
                    entry.isResearch = m.tier == .research
                    entry.detail = Outputs.algorithm(m) + (entry.groupId == nil ? "" : " · the method you read") + " · today"
                }
                return entry
            }
            if entries.isEmpty { continue }
            let open = !q.isEmpty || ((i == 0) != s.ui.openRows.contains(title))
            sections.append(CatalogueSection(title: title, isOpen: open, entries: entries))
        }
        let methods = GroupCatalogue.all.filter { ExploreCatalogue.matches($0, q) }.map { g in
            CatalogueEntry(key: "group:\(g.id)", name: g.title, groupId: g.id, isResearch: false, intent: .openGroup(groupId: g.id))
        }
        if !methods.isEmpty {
            sections.append(CatalogueSection(title: "Methods", isOpen: !q.isEmpty || s.ui.openRows.contains("Methods"),
                                             entries: methods))
        }
        // Wave 2: "Every measure" — every registry metric, its newest value labelled with source and algorithm.
        for (title, list) in ExploreCatalogue.allMeasures {
            let entries = Outputs.measureEntries(s, list.filter { ExploreCatalogue.matches($0, q) })
            if entries.isEmpty { continue }
            let id = "Every measure · " + title
            sections.append(CatalogueSection(title: id, isOpen: !q.isEmpty || s.ui.openRows.contains(id),
                                             entries: entries))
        }
        if s.settings.researchRowsShown {
            let research = ExploreCatalogue.research.filter { q.isEmpty || $0.1.range(of: q, options: .caseInsensitive) != nil }
                .map { CatalogueEntry(key: $0.0, name: $0.1, groupId: nil, isResearch: true, intent: .openResearch($0.0)) }
            if !research.isEmpty {
                sections.append(CatalogueSection(title: "Research", isOpen: !q.isEmpty || s.ui.openRows.contains("Research"),
                                                 entries: research))
            }
        }
        let shelf = s.explore.shelf.map { a in
            ShelfItem(key: a.key, name: ExploreCatalogue.name(a.key), value: periodValue(s, a),
                      sparkline: a.points.map(\.value))
        }
        var state = ExploreState(sample: s.sample, query: s.explore.query, period: s.explore.period, shelf: shelf,
                                 catalogue: sections,
                                 matrixSubtitle: "pick up to \(MatrixState.maxMetrics) metrics · \(s.explore.period.title)")
        state.pcLab = Outputs.pcRows(s)
        state.extras = Outputs.extras(s)
        state.pcHistory = PCHistoryText.sentence(s.explore.measuresPC, calendar: s.calendar)
        state.pcHistoryShown = s.explore.measuresPC?.isShown ?? false
        state.workoutHistory = WorkoutSummaryPresenter.history(s)
        if q.isEmpty { state.trends = TrendsPresenter.cards(s) }
        return state
    }

    /// The period's number: the median from upstream (ALG-075), with the newest metric's receipt; blank with why.
    static func periodValue(_ s: PresenterSnapshot, _ a: MetricAnalysis) -> DisplayValue {
        let receipt = a.latest.map(MetricText.receipt)
        // Bug 9 (M-169): a lab is static: with no draw inside the period it reads the newest draw, its date in the
        // receipt and in words ("drawn Jul 14 2026"), not "No values in this period".
        if LabDraws.isStatic(a.key), a.median?.isFinite != true, let lab = LabDraws.newest(s, key: a.key),
           let v = lab.value {
            let (text, unit) = MetricText.format(v, unit: lab.unit, name: lab.name)
            let drawn = "drawn \(MGFormat.shortDate(lab.at, calendar: s.calendar)) \(s.calendar.component(.year, from: lab.at))"
            return .value(text: text, unit: (unit.map { "\($0) · " } ?? "") + drawn, receipt: MetricText.receipt(lab),
                          style: DisplayValue.style(for: lab.tier, uncertainty: nil), sample: s.sample)
        }
        guard let med = a.median, med.isFinite, let latest = a.latest else {
            return .blank(reason: a.missingReason ?? "No values in this period.", receipt: receipt)
        }
        // Bug 5 audit: the median of instants is a date in the middle of the period, not a time; an instant metric
        // (focus window, caffeine cut-off, onset) reads its newest value as a local date-time.
        if latest.unit == "unix_s" { return MetricText.display(latest, sample: s.sample) }
        // Wave 4: the gated SpO₂ member reads as a % once the PC's gate passed (SpO2Gate); otherwise a raw count.
        var probe = latest
        probe.value = med
        if SpO2Gate.names.contains(latest.name), let pct = SpO2Gate.percent(probe, status: s.spo2Gate, sample: s.sample) {
            return pct
        }
        let (text, unit) = MetricText.format(med, unit: latest.unit, name: latest.name)
        let style: DisplayValue.Style = MetricText.isRaw(latest) ? MetricText.rawStyle(latest)
            : DisplayValue.style(for: latest.tier, uncertainty: nil)
        return .value(text: text, unit: unit, receipt: MetricText.receipt(latest), style: style, sample: s.sample)
    }
}

/// Metric detail (UX §9): title + receipt, Number · Graph · Trend, methods strip, About.
public enum MetricDetailPresenter {
    public static func make(_ s: PresenterSnapshot) -> MetricDetailState? {
        guard let a = s.explore.detail else { return nil }
        let latest = a.latest
        let unitText = latest.map { MetricText.format(0, unit: $0.unit, name: $0.name).1 } ?? nil
        func fmt(_ v: Double) -> String {
            guard let latest else { return MGFormat.number(v, decimals: 1) }
            return MetricText.format(v, unit: latest.unit, name: latest.name).0
        }
        var iqr: String?
        if let q1 = a.q1, let q3 = a.q3, q1.isFinite, q3.isFinite {
            iqr = "\(fmt(q1))–\(fmt(q3))" + (unitText.map { " \($0)" } ?? "")
        }
        var versus: String?
        if let m = a.median, let p = a.previousMedian, m.isFinite, p.isFinite {
            let now = fmt(m)
            let before = fmt(p)
            let span = ExplorePeriodText.period(s.explore.period)
            if now == before {
                versus = "the same as the \(span) before (\(before))"
            } else {
                versus = (m > p ? "up" : "down") + " from \(before) in the \(span) before"
            }
        }
        // "30 of 30 days · 12 from WHOOP export": imported days say where they came from (ImportedHistory).
        let imported = a.importedDays.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .map { "\($0.value) from \($0.key)" }
        let coverage = (["\(a.daysWithValue) of \(a.daysInPeriod) days"] + imported).joined(separator: " · ")
        // Bug 28 (round 2): a catalogue group the stored rows do not carry still shows its strip.
        let gid = latest?.group ?? ExploreCatalogue.entry(a.key)?.group
        let about = MetricAbout(method: latest?.method ?? latest?.source ?? a.key,
                                algorithmId: algorithmID(latest?.method ?? latest?.variant),
                                citation: latest?.citation, tier: latest?.tier ?? .research,
                                latestNote: latest?.value == nil ? nil : latest?.note)
        var state = MetricDetailState(
            sample: s.sample, key: a.key, title: ExploreCatalogue.name(a.key), receipt: latest.map(MetricText.receipt),
            view: s.explore.viewMode,
            number: MetricNumberSummary(median: ExplorePresenter.periodValue(s, a), iqr: iqr, coverage: coverage,
                                        versusPrevious: versus),
            graph: MetricGraph(unit: unitText, points: a.points, bandLow: a.bandLow, bandHigh: a.bandHigh,
                               markers: s.explore.markers),
            trend: MetricTrend(ewma: a.ewma, changeDays: a.changeDays),
            methods: gid.flatMap { s.methodsStrip($0) }, about: about, period: s.explore.period)
        state.sources = Outputs.sources(s, key: a.key)
        MetricNumberNotes.apply(s, a, to: &state.number)      // T9896, T9913, T9894 (e-6, coverage, e-5)
        // Wave 4: the SpO₂ screen says whether the byte is checked against WHOOP and why there is no reading on demand.
        if SpO2Gate.names.contains(a.key) || a.key == MetricKey.spo2GateNights.rawValue {
            state.infoTitle = "Checked against WHOOP?"
            state.infoLines = SpO2Gate.detailLines(s.spo2Gate) + SpO2Gate.spotLines(s)
            state.infoAction = SpO2Gate.spotAction(s)
        }
        // Sleep expanded (Mo, Nov 5 2026): the sleep screens in Explore open the same full breakdown as the dashboard card
        // (same card state: the source, the headline and the "also:" line cannot differ).
        if PresenterSnapshot.sleepNames.contains(a.key), state.infoTitle == nil {
            let card = SleepBreakdownPresenter.card(s)
            state.infoTitle = "Last night's sleep, in full"
            state.infoLines = [card.pill, card.durationText.map { "\($0) asleep" }, card.alsoLine, card.story]
                .compactMap { $0 }.filter { !$0.isEmpty }
            state.infoAction = ActionState(id: "sleepBreakdown", title: "Full sleep breakdown ›", intent: .openNight(nil))
        }
        // T35: skin temperature says what the number is, where it comes from and what is not shown.
        if a.key == MetricKey.skinTempDev.rawValue, state.infoTitle == nil {
            state.infoTitle = "Last night's skin temperature"
            state.infoLines = SkinTemperature.lines(s)
        }
        // Bug 24 (round 2, 2026-10-14, M-033/M-036): rows that showed "—" with nothing to say what they are.
        if let note = ExploreCatalogue.explainers[a.key] ?? MetricExplainers.notes[a.key], state.infoTitle == nil {
            state.infoTitle = note.title
            state.infoLines = note.lines
        }
        // W10 #95: breathing rate every hour today, asleep (night series) and awake (still minutes, workouts blank).
        if a.key == MetricKey.respRate.rawValue, state.infoTitle == nil {
            let lines = BreathingHours.lines(s, analysis: a)
            if !lines.isEmpty {
                state.infoTitle = "Breathing by hour, night and trend"
                state.infoLines = lines
            }
        }
        // R9m (D-HRV-WALK-2): the alertness model is an estimate; this says how it is being checked against Mo's own
        // reaction tests and where that check stands, with a button for the test.
        if a.key == MetricKey.alertness.rawValue, state.infoTitle == nil {
            state.infoTitle = AlertnessSelfCheckPresenter.title
            state.infoLines = AlertnessSelfCheckPresenter.lines(s.alertnessSelfCheck)
            state.infoAction = ActionState(id: "pvt", title: "Take the 3-minute reaction test ›", intent: .startReactionTest)
        }
        // W10 #99: a strap / phone metric split by where the strap was worn (ALG-042).
        if let wc = s.explore.wearCompare, state.infoTitle == nil, let m = latest, m.computedOn != .pc,
           let lines = WearCompare.lines(wc, format: { v in
               let (t, u) = MetricText.format(v, unit: m.unit, name: m.name)
               return t + (u.map { " \($0)" } ?? "")
           }) {
            state.infoTitle = "By where you wore it"
            state.infoLines = lines
        }
        // r9o (D-LOAD-WALK-1 item 14): weight and body composition against the last InBody, or the placeholder if none.
        if ["weight", "body_fat", "lean_mass"].contains(a.key), state.infoTitle == nil {
            state.infoTitle = "Since your last body scan"
            state.infoLines = LabCurrentLevel.lines(s, key: a.key)
        }
        // W10 #96: a measured lab lists every draw with its date and source note.
        if a.key.hasPrefix("lab_"), state.infoTitle == nil {
            state.infoTitle = "Lab draws"
            state.infoLines = LabDraws.lines(s, key: a.key)
        }
        // W10: an age metric says it in words and opens "Your ages".
        if AgesPresenter.keys.contains(a.key), state.infoTitle == nil {
            state.infoTitle = "Your ages"
            state.infoLines = [AgesPresenter.line(s, key: a.key)].compactMap { $0 }
            state.infoAction = ActionState(id: "ages", title: "All your ages ›", intent: .openAges)
        }
        // T99: tapping Strain explains each strain method; the dropdown's pick is the G-LOAD "read this one" choice.
        if a.key == MetricKey.strain.rawValue {
            state.algorithmPanel = StrainPanelPresenter.make(s, selectedID: s.groupChoices["G-LOAD"]?.readVariant)
        }
        // T133: tapping Recovery does the same for the recovery methods, each on its own labelled scale.
        if a.key == MetricKey.readiness.rawValue {
            state.algorithmPanel = RecoveryPanelPresenter.make(s, selectedID: s.groupChoices["G-READY"]?.readVariant)
        }
        if a.key == MetricKey.workoutHrAvg.rawValue { state.workoutTrends = WorkoutTrends.series(a.workoutRows) }  // T56
        state.pcHistory = PCHistoryText.sentence(a.pcHistory, calendar: s.calendar)
        state.pcHistoryShown = a.pcHistory?.isShown ?? false
        return state
    }

    /// "ALG-010" / "MS-18" from a method string ("ALG-010@1 rmssd") or a variant.
    static func algorithmID(_ text: String?) -> String? {
        guard let text else { return nil }
        for prefix in ["ALG-", "MS-"] {
            if let r = text.range(of: prefix) {
                let tail = text[r.upperBound...].prefix { $0.isNumber }
                if !tail.isEmpty { return prefix + tail }
            }
        }
        return nil
    }
}

enum ExplorePeriodText {
    static func period(_ p: ExplorePeriod) -> String {
        switch p {
        case .today: return "day"
        case .days7: return "7 days"
        case .days30: return "30 days"
        case .days90: return "90 days"
        case .year1: return "year"
        case .years2: return "2 years"
        case .years5: return "5 years"
        case .all: return "whole history"
        case .custom(let r): return r?.label ?? "30 days (no custom range picked yet)"
        }
    }
}

/// One comparison group, open (UX §11): every member, dropped ones apart (hidden, never deleted).
public enum GroupPresenter {
    public static func make(_ s: PresenterSnapshot) -> GroupState? {
        guard let gid = s.explore.groupId else { return nil }
        let rows = s.groupRows(gid)
        let read = s.readVariant(group: gid, among: rows.compactMap(\.metric))
        let all = s.methodMembers(gid, rows, read: read)
        var state = GroupState(sample: s.sample, groupId: gid, name: GroupCatalogue.group(gid)?.title ?? gid,
                               members: all.filter { !$0.isDropped }, dropped: all.filter { $0.isDropped },
                               showDropped: s.ui.showDroppedGroups.contains(gid), agreement: s.explore.agreement[gid],
                               period: s.explore.period)
        state.measures = Outputs.groupMeasures(s, gid: gid)
        if gid == "G-HRV" { state.hrvSuite = HRVSuitePresenter.make(s) }      // T9976
        if let g = s.explore.groupPC {
            state.pcHistory = PCHistoryText.sentence(g.note, calendar: s.calendar)
            state.pcRows = g.rows.map { r in
                let (text, unit) = MetricText.format(r.median, unit: r.unit, name: r.name)
                let span = r.first.year == r.last.year ? "\(r.first.year)" : "\(r.first.year)–\(r.last.year)"
                return LabeledValue(id: "pc|\(r.name)|\(r.variant)",
                                    label: "\(ExploreCatalogue.name(r.name)) · \(r.label)",
                                    value: s.worded(text, unit: unit, receipt: Receipt(computedOn: .pc, tier: .estimate,
                                                                                       at: r.last.start(in: s.calendar.timeZone))),
                                    caption: "median of \(MGFormat.grouped(r.days)) days, \(span) · from the PC")
            }
        }
        return state
    }
}

/// "Compare with…" (APP-104): scatter pairs, ρ / n / q from upstream (WP-09), lag 0–2 days.
public enum ComparePresenter {
    public static func make(_ s: PresenterSnapshot) -> CompareState? {
        guard let c = s.explore.compare else { return nil }
        let first = MatrixMetric(key: c.firstKey, name: ExploreCatalogue.name(c.firstKey))
        let second = c.secondKey.map { MatrixMetric(key: $0, name: ExploreCatalogue.name($0)) }
        let candidates = ExploreCatalogue.sections.flatMap { $0.1 }.filter { $0.key != c.firstKey }
            .map { MatrixMetric(key: $0.key, name: $0.name) }
        let cell: MatrixCell? = c.secondKey == nil ? nil : c.result.map { MatrixCell.make(rho: $0.rho, n: $0.n, qValue: $0.q) }
            ?? MatrixCell(rho: nil, n: c.pairs.count, qValue: nil, blankReason: "not computed yet")
        return CompareState(sample: s.sample, first: first, second: second, candidates: candidates,
                            period: s.explore.period, lagDays: min(max(c.lagDays, 0), CompareState.maxLagDays),
                            xUnit: c.xUnit, yUnit: c.yUnit, pairs: c.pairs, cell: cell)
    }
}

/// Correlation matrix (UX §9): ≤ 8 metrics, cells from upstream; < 14 paired days blank; ρ = 1 on the diagonal.
public enum MatrixPresenter {
    public static func make(_ s: PresenterSnapshot) -> MatrixState {
        let keys = Array(s.explore.matrixKeys.prefix(MatrixState.maxMetrics))
        let metrics = keys.map { MatrixMetric(key: $0, name: ExploreCatalogue.name($0)) }
        let cells: [[MatrixCell]] = keys.indices.map { i in
            keys.indices.map { j in
                let input: CorrelationInput? = i < s.explore.matrixCells.count && j < s.explore.matrixCells[i].count
                    ? s.explore.matrixCells[i][j] : nil
                if i == j { return MatrixCell(rho: 1, n: input?.n ?? 0, qValue: nil, blankReason: nil) }
                guard let input else { return MatrixCell(rho: nil, n: 0, qValue: nil, blankReason: "not computed yet") }
                return MatrixCell.make(rho: input.rho, n: input.n, qValue: input.q)
            }
        }
        return MatrixState(sample: s.sample, metrics: metrics, period: s.explore.period, cells: cells)
    }
}
