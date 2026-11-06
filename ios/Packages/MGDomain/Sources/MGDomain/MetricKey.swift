import Foundation

/// Stable metric names of the B1 registry (ARCHITECTURE.md 8.3). Must equal `app/shared/contract/metric-registry.json`
/// (checked by app/pclab/tests/test_swift_parity.py and Scripts/gen_event_payloads.py --check). Members of one
/// comparison group share one name and differ by `Metric.variant`; units, groups and windows live in the registry.
public enum MetricKey: String, Codable, Sendable, CaseIterable {
    // ALG-012 resting / average HR, HR dip
    case rhr = "rhr"
    case hrAvg = "hr_avg"
    case hrDip = "hr_dip"
    // G-HRV, ALG-010
    case hrvRmssd = "hrv_rmssd"
    case hrvLnRmssd = "hrv_ln_rmssd"
    case hrvSdnn = "hrv_sdnn"
    case hrvPnn50 = "hrv_pnn50"
    case hrvSd1 = "hrv_sd1"
    case hrvSd2 = "hrv_sd2"
    // G-HRV, ALG-011 (lab / research only) / ALG-013. DFA alpha1, Kubios-style PNS / SNS, PRSA deceleration / acceleration
    // capacity, breathing-rate variability, focus window and second wind were REMOVED 2026-10-17 (D-HRV-WALK-1/2).
    case hrvLfHf = "hrv_lf_hf"
    case hrvSampen = "hrv_sampen"
    // ALG-004 (base signal quality) / ALG-005 (enhanced signal quality, share of good 10 s PPG segments)
    case rrArtefact = "rr_artefact"
    case ppgSqiGood = "ppg_sqi_good"
    // G-RESP: ALG-020, ALG-121, MS-07
    case respRate = "resp_rate"
    // G-SPO2, raw byte counts, never %
    case spo2StrapMean = "spo2_strap_mean"
    case spo2StrapMin = "spo2_strap_min"
    // G-TEMP, raw/100 and raw/128 variants, never degrees C
    case skinTempDev = "skin_temp_dev"
    // G-READY
    case readiness = "readiness"
    // G-WARN, ALG-161: one row per sign code (variant), level 0-2, the calm sentence in the note (r9h)
    case warningSign = "warning_sign"
    // G-TREND, ALG-170 (r9s, D-TRENDS-1): relative trends vs your own baseline, one row per variant; `trend` = z (AF burden: %), `trend_level` = 0-2
    case trend = "trend"
    case trendLevel = "trend_level"
    // minutes, ALG-150 / ALG-115
    case sleepTotal = "sleep_total"
    case sleepNeed = "sleep_need"
    case sleepDebt = "sleep_debt"
    case sleepLatency = "sleep_latency"
    case waso = "waso"
    case remLatency = "rem_latency"
    // fraction, ALG-150
    case sleepPerformance = "sleep_performance"
    case sleepEfficiency = "sleep_efficiency"
    // fraction, WHOOP export only (T8: WHOOP's own Sleep consistency, not the SRI)
    case sleepConsistency = "sleep_consistency"
    // count, ALG-150
    case awakenings = "awakenings"
    // unix_s, ALG-030 / ALG-115
    case sleepOnset = "sleep_onset"
    case wakeTime = "wake_time"
    case bedtimeRecommended = "bedtime_recommended"
    // 14 d, ALG-030
    case sri = "sri"
    case circadianIs = "circadian_is"
    case circadianIv = "circadian_iv"
    case circadianRa = "circadian_ra"
    case circadianL5 = "circadian_l5"
    case circadianM10 = "circadian_m10"
    // 28 d, ALG-116
    case chronotypeMsfSc = "chronotype_msf_sc"
    // G-STAGE
    case sleepDeep = "sleep_deep"
    case sleepLight = "sleep_light"
    case sleepRem = "sleep_rem"
    case sleepWake = "sleep_wake"
    // G-LOAD
    case strain = "strain"
    // G-LOAD
    case acwr = "acwr"
    // r9p (D-LOAD-WALK-2): this week vs the 4-week average (day) and one session's load score / session-RPE load (workout)
    case loadWeek = "load_week"
    case loadSession = "load_session"
    case ctl = "ctl"
    case atl = "atl"
    case tsb = "tsb"
    // G-VO2 / ALG-133
    case vo2max = "vo2max"
    case fitnessAge = "fitness_age"
    // G-HRMAX
    case hrmax = "hrmax"
    // G-STRESS
    case stress = "stress"
    // ALG-060
    case caffeineNow = "caffeine_now"
    case caffeineBedtime = "caffeine_bedtime"
    // G-CAFF
    case caffeineCutoff = "caffeine_cutoff"
    // ALG-069 / ALG-068
    case vapeHits = "vape_hits"
    case vapeFirstAfterWake = "vape_first_after_wake"
    // G-STEPS
    case steps = "steps"
    // G-CAL
    case caloriesActive = "calories_active"
    case caloriesBasal = "calories_basal"
    case caloriesTotal = "calories_total"
    // ALG-112
    case anomaly = "anomaly"
    // G-AF, class 0-3
    case afScreen = "af_screen"
    // ALG-050
    case pvtMeanRt = "pvt_mean_rt"
    case pvtLapses = "pvt_lapses"
    // ALG-051
    case alertness = "alertness"
    // Computed on the PC (WP-21; registry entries added 2026-10-11, approved by main)
    // G-HRV, ALG-011 re-score: LF / HF power
    case hrvLf = "hrv_lf"
    case hrvHf = "hrv_hf"
    // G-AGE, ALG-070 PhenoAge
    case phenoage = "phenoage"
    case phenoageAccel = "phenoage_accel"
    // ALG-079 group agreement (the metric's group is the group compared)
    case agreementSpearman = "agreement_spearman"
    case agreementBias = "agreement_bias"
    // G-CAUSE, ALG-124 case-crossover / ALG-064 distributed lag
    case causeOddsRatio = "cause_odds_ratio"
    case causeLagEffect = "cause_lag_effect"
    // Wave 1 (2026-10-11; registry entries added the same day, see SOURCE.md)
    // G-APNEA, ALG-023 CVHR screen (events per observed hour; never an AHI)
    case breathingDisturbance = "breathing_disturbance"
    // ALG-012 HR recovery after a logged workout
    case hrRecovery60 = "hr_recovery_60"
    case hrRecovery120 = "hr_recovery_120"
    case hrRecoveryTau = "hr_recovery_tau"
    // bpm, WHOOP export only (T56: WHOOP's own average HR of one workout; window workout:<activity>:<HHMM>)
    case workoutHrAvg = "workout_hr_avg"
    // G-STRESS, ALG-105 live stress onsets (count per day)
    case stressOnsets = "stress_onsets"
    // ALG-102 / ALG-132 / ALG-134 / ALG-135 / ALG-136 / ALG-138
    case scoreDrivers = "score_drivers"
    case keyPoints = "key_points"
    case bodyAge = "body_age"
    case hydrationGoal = "hydration_goal"
    case activityCost = "activity_cost"
    case percentileSelf = "percentile_self"
    // Raw motion R21 (wave W8, 2026-10-11 19:50 PT): ALG-113 ENMO day mean (mg) and ALG-114 wrist gait asymmetry (0-1)
    case enmo = "enmo"
    case imuAsym = "imu_asym"
    // T118 (2026-10-13): walking bouts from the raw accelerometer (WristWalking)
    case wristWalkSteps = "wrist_walk_steps"
    case wristWalkCadence = "wrist_walk_cadence"
    // Mo's script, PC side (pc.ms-script@1, mglab/ms_runner.py FUNCTIONS; registry entries added 2026-10-11, wave 2):
    // research tier, computed on the PC, shown as PC results (never mirrored to Apple Health)
    case msSpo2Dst = "ms_spo2_dst"
    case msBpSbp = "ms_bp_sbp"
    case msBpDbp = "ms_bp_dbp"
    case msOdi = "ms_odi"
    case msAhi = "ms_ahi"
    case msStrokeVolume = "ms_stroke_volume"
    case msCfpwv = "ms_cfpwv"
    case msStiffnessIndex = "ms_stiffness_index"
    case msPpgAix = "ms_ppg_aix"
    case msLvedpAnchor = "ms_lvedp_anchor"
    case msLvedpIndex = "ms_lvedp_index"
    case msLabHba1c = "ms_lab_hba1c"
    case msLabApob = "ms_lab_apob"
    case msLabNtprobnp = "ms_lab_ntprobnp"
    case msLabFerritin = "ms_lab_ferritin"
    case msLabHomaIr = "ms_lab_homa_ir"
    case msGeneticBpPrior = "ms_genetic_bp_prior"
    case msTestosteroneProxy = "ms_testosterone_proxy"
    case msCortisolCarProxy = "ms_cortisol_car_proxy"
    case msGlucoseRiskProxy = "ms_glucose_risk_proxy"
    case msMuscleInjuryProxy = "ms_muscle_injury_proxy"
    case msSqi = "ms_sqi"
    case msFuse = "ms_fuse"
    // Computed on the PC (Wave 3; registry entries added 2026-10-11, approved by main)
    // ALG-053 energy / focus / mood / KSS / PVT-B model (pc.checkin-model)
    case energyPred = "energy_pred"
    case focusPred = "focus_pred"
    case moodPred = "mood_pred"
    case kssPred = "kss_pred"
    case pvtRtPred = "pvt_rt_pred"
    // ALG-055 crash finder (pc.crash-finder)
    case crashEffect = "crash_effect"
    // G-LABS, ALG-062 personal caffeine half-life + sleep sensitivity (pc.caffeine-personal)
    case caffeineHalfLife = "caffeine_half_life"
    case caffeineSleepSensitivity = "caffeine_sleep_sensitivity"
    // G-AGE, ALG-077 KDM biological age + homeostatic dysregulation (pc.bioage)
    case kdmBioage = "kdm_bioage"
    case kdmBioageAccel = "kdm_bioage_accel"
    case hdDistance = "hd_distance"
    // Wave 4 (optical and SpO₂, 2026-10-11; registry entries logged in shared/contract/SOURCE.md)
    // G-SPO2: paired nights of noop's per-strap SpO₂ promotion gate (pc.spo2-gate)
    case spo2GateNights = "spo2_gate_nights"
    // #76: WHOOP's / Apple Health's own SpO₂ % and absolute skin temperature (their units, not strap counts)
    case spo2Pct = "spo2_pct"
    case skinTempC = "skin_temp_c"
    // ALG-108: heart rate and spot HRV from the strap's v26 PPG bursts (research)
    case ppgHr = "ppg_hr"
    case ppgHrvRmssd = "ppg_hrv_rmssd"
    // R18 optical signal-quality fields over the night (the band's own numbers; decoded, untested)
    case opticalSaturatedPct = "optical_saturated_pct"
    case opticalPsnr = "optical_psnr"
    case opticalLogvar = "optical_logvar"
    // G-VASC, ALG-015 pulse shape from raw optical block 0 (green; research)
    case pulseRiseTime = "pulse_rise_time"
    case pulseWidthHalf = "pulse_width_half"
    // T89 (2026-10-13): dicrotic notch time, reflection index and the share of beats with a notch found (ALG-015:notch)
    case pulseNotchTime = "pulse_notch_time"
    case pulseReflectionIndex = "pulse_reflection_index"
    case pulseNotchRate = "pulse_notch_rate"
    // Wave 9 (2026-10-11): imported from Apple Health by the PC (pc.history@1), Apple's / the cuff's values
    case walkingHr = "walking_hr"
    case bpSystolic = "bp_systolic"
    case bpDiastolic = "bp_diastolic"
    case sixMinWalkDistance = "six_min_walk_distance"
    // T63 (2026-10-13): Apple Health gait (iPhone), stairs and effort (Watch), distance, flights, exercise minutes (pc.history@1)
    case walkingSpeed = "walking_speed"
    case walkingStepLength = "walking_step_length"
    case walkingDoubleSupport = "walking_double_support"
    case walkingAsymmetry = "walking_asymmetry"
    case walkingSteadiness = "walking_steadiness"
    case stairAscentSpeed = "stair_ascent_speed"
    case stairDescentSpeed = "stair_descent_speed"
    case physicalEffort = "physical_effort"
    case distanceWalkRun = "distance_walk_run"
    case flightsClimbed = "flights_climbed"
    case exerciseMin = "exercise_min"
    // T136 (2026-10-13): the rest of the dropped Apple Health types and WHOOP workout numbers (pc.history@1)
    case standMin = "stand_min"
    case standHours = "stand_hours"
    case headphoneAudioDb = "headphone_audio_db"
    case environmentAudioDb = "environment_audio_db"
    case soundReductionDb = "sound_reduction_db"
    case audioExposureEvents = "audio_exposure_events"
    case highHrEvents = "high_hr_events"
    case lowCardioFitnessEvents = "low_cardio_fitness_events"
    case height = "height"
    // Bug 21 (round 2, 2026-10-14): Apple Health body measures, registry rows added the same day (pc.history@1).
    case weight = "weight"
    case bodyFat = "body_fat"
    case leanMass = "lean_mass"
    case bmi = "bmi"
    case runningSpeed = "running_speed"
    case snowDownhillDistance = "snow_downhill_distance"
    case sleepGoal = "sleep_goal"
    case ringMoveKcal = "ring_move_kcal"
    case ringExerciseMin = "ring_exercise_min"
    case ringStandHours = "ring_stand_hours"
    case workoutHrMax = "workout_hr_max"
    case workoutKcal = "workout_kcal"
    case workoutDuration = "workout_duration"
    case workoutHrZonePct = "workout_hr_zone_pct"
    // W10 #96 (2026-10-11): measured lab values per draw from the Health vault (pc.labs@1, mglab/alg/labs.py)
    case labAlbumin = "lab_albumin"
    case labCreatinine = "lab_creatinine"
    case labGlucose = "lab_glucose"
    case labCrp = "lab_crp"
    case labLymphocytePct = "lab_lymphocyte_pct"
    case labMcv = "lab_mcv"
    case labRdw = "lab_rdw"
    case labAlp = "lab_alp"
    case labWbc = "lab_wbc"
    case labHba1c = "lab_hba1c"
    case labTotalCholesterol = "lab_total_cholesterol"
    case labBun = "lab_bun"
    case labUricAcid = "lab_uric_acid"
    case labTestosteroneTotal = "lab_testosterone_total"
    case labTestosteroneFree = "lab_testosterone_free"
    case labCortisol = "lab_cortisol"
    case labShbg = "lab_shbg"
    case labEstradiol = "lab_estradiol"
    case labDheaS = "lab_dhea_s"
    // T14 (2026-10-12): the other 102 rows of the Function Health panel (phenoage.LAB_EXTRA)
    case labHdlCholesterol = "lab_hdl_cholesterol"
    case labLdlCholesterol = "lab_ldl_cholesterol"
    case labNonHdlCholesterol = "lab_non_hdl_cholesterol"
    case labTriglycerides = "lab_triglycerides"
    case labCholHdlRatio = "lab_chol_hdl_ratio"
    case labApob = "lab_apob"
    case labLpa = "lab_lpa"
    case labLdlParticleNumber = "lab_ldl_particle_number"
    case labLdlSmall = "lab_ldl_small"
    case labLdlMedium = "lab_ldl_medium"
    case labLdlPeakSize = "lab_ldl_peak_size"
    case labLdlPattern = "lab_ldl_pattern"
    case labHdlLarge = "lab_hdl_large"
    case labFerritin = "lab_ferritin"
    case labHomocysteine = "lab_homocysteine"
    case labIron = "lab_iron"
    case labIronSaturation = "lab_iron_saturation"
    case labIronBindingCapacity = "lab_iron_binding_capacity"
    case labMma = "lab_mma"
    case labVitaminD = "lab_vitamin_d"
    case labZinc = "lab_zinc"
    case labMagnesiumRbc = "lab_magnesium_rbc"
    case labOmega3Total = "lab_omega3_total"
    case labOmega3Omegacheck = "lab_omega3_omegacheck"
    case labOmega6Total = "lab_omega6_total"
    case labOmega63Ratio = "lab_omega6_3_ratio"
    case labOmega3Dha = "lab_omega3_dha"
    case labOmega3Dpa = "lab_omega3_dpa"
    case labOmega3Epa = "lab_omega3_epa"
    case labOmega6Arachidonic = "lab_omega6_arachidonic"
    case labOmega6Linoleic = "lab_omega6_linoleic"
    case labAaEpaRatio = "lab_aa_epa_ratio"
    case labHematocrit = "lab_hematocrit"
    case labHemoglobin = "lab_hemoglobin"
    case labRbcCount = "lab_rbc_count"
    case labMch = "lab_mch"
    case labMchc = "lab_mchc"
    case labMpv = "lab_mpv"
    case labPlatelets = "lab_platelets"
    case labAboGroup = "lab_abo_group"
    case labRhFactor = "lab_rh_factor"
    case labNeutrophilsPct = "lab_neutrophils_pct"
    case labMonocytesPct = "lab_monocytes_pct"
    case labEosinophilsPct = "lab_eosinophils_pct"
    case labBasophilsPct = "lab_basophils_pct"
    case labLymphocytesAbs = "lab_lymphocytes_abs"
    case labNeutrophilsAbs = "lab_neutrophils_abs"
    case labMonocytesAbs = "lab_monocytes_abs"
    case labEosinophilsAbs = "lab_eosinophils_abs"
    case labBasophilsAbs = "lab_basophils_abs"
    case labEgfr = "lab_egfr"
    case labUrineAlbumin = "lab_urine_albumin"
    case labSodium = "lab_sodium"
    case labPotassium = "lab_potassium"
    case labChloride = "lab_chloride"
    case labCarbonDioxide = "lab_carbon_dioxide"
    case labCalcium = "lab_calcium"
    case labAlt = "lab_alt"
    case labAst = "lab_ast"
    case labGgt = "lab_ggt"
    case labGlobulin = "lab_globulin"
    case labAlbuminGlobulinRatio = "lab_albumin_globulin_ratio"
    case labTotalBilirubin = "lab_total_bilirubin"
    case labTotalProtein = "lab_total_protein"
    case labLh = "lab_lh"
    case labFsh = "lab_fsh"
    case labProlactin = "lab_prolactin"
    case labPsaTotal = "lab_psa_total"
    case labPsaFree = "lab_psa_free"
    case labPsaFreePct = "lab_psa_free_pct"
    case labInsulin = "lab_insulin"
    case labLeptin = "lab_leptin"
    case labAmylase = "lab_amylase"
    case labLipase = "lab_lipase"
    case labTsh = "lab_tsh"
    case labFreeT4 = "lab_free_t4"
    case labFreeT3 = "lab_free_t3"
    case labTpoAntibodies = "lab_tpo_antibodies"
    case labTgAntibodies = "lab_tg_antibodies"
    case labRheumatoidFactor = "lab_rheumatoid_factor"
    case labAnaScreen = "lab_ana_screen"
    case labAnaPattern = "lab_ana_pattern"
    case labAnaTiter = "lab_ana_titer"
    case labLead = "lab_lead"
    case labMercury = "lab_mercury"
    case labFunctionBioAge = "lab_function_bio_age"
    case labUrineSpecificGravity = "lab_urine_specific_gravity"
    case labUrinePh = "lab_urine_ph"
    case labUrineAppearance = "lab_urine_appearance"
    case labUrineColor = "lab_urine_color"
    case labUrineBilirubin = "lab_urine_bilirubin"
    case labUrineGlucose = "lab_urine_glucose"
    case labUrineKetones = "lab_urine_ketones"
    case labUrineProtein = "lab_urine_protein"
    case labUrineNitrite = "lab_urine_nitrite"
    case labUrineLeukocyteEsterase = "lab_urine_leukocyte_esterase"
    case labUrineOccultBlood = "lab_urine_occult_blood"
    case labUrineRbc = "lab_urine_rbc"
    case labUrineWbc = "lab_urine_wbc"
    case labUrineSquamous = "lab_urine_squamous"
    case labUrineBacteria = "lab_urine_bacteria"
    case labUrineHyalineCasts = "lab_urine_hyaline_casts"
    // Wave 12 (2026-10-11, #82): pc.vitamin-d@1 on the PC — Apple's Time in Daylight and the sun vitamin D estimate
    case daylightMin = "daylight_min"
    case vitaminDIuEst = "vitamin_d_iu_est"
}
