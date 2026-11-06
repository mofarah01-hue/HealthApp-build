import Foundation
import MGDomain

/// One night, retrospective, end to end (Python `mglab.ref.sleep.night`):
/// grid → ALG-030 rest window → ALG-120 hypnogram → ALG-150 accounting; the strap flag over the WHOLE
/// span + its own ALG-150 accounting (G-STAGE member "strap"; the strap night needs no rest window, Oct 16 2026); the ALG-151
/// fused stager over the strap-asleep night (Oct 17 2026, replaces the ALG-120 hybrid; Python `sleep_fused.stage_night`). Every
/// part is present; a part that cannot run is Missing with its reason. Pass the seconds of one night's search span
/// (recommended 18:00 → 18:00 on the wake day), the ALG-004 A corrected beats of the same span and, for the pipeline,
/// the result's local day (`wakeDay`: the night's wake instant must fall in it, D13; nil = no day limit). The night
/// belongs to the local date of `accounting.wakeTime` (`ALG030.wakeDay`).
public enum SleepNight {
    public struct Outcome: Sendable, Equatable {
        public var window: Computed<ALG030.RestWindow>
        public var stager: Computed<ALG120.StagedNight>
        public var accounting: Computed<ALG150.Accounting>
        public var strap: Computed<SleepStrapFlag.Epochs>
        public var strapAccounting: Computed<ALG150.Accounting>
        /// ALG-151 (Oct 17 2026, D-SLEEP-WALK-1): the strap flag decides asleep / awake, the fused stager picks light / deep /
        /// REM inside strap-asleep epochs. Missing when the strap flag is missing.
        public var fused: Computed<FusedStager.Night> = .missing("not computed")
        public var fusedAccounting: Computed<ALG150.Accounting> = .missing("not computed")

        /// The primary sleep accounting: tier M when it ran, else the strap flag's own ALG-150 (blank without a strap flag, e.g. WHOOP 4.0).
        public var primaryAccounting: Computed<ALG150.Accounting> {
            fusedAccounting.value != nil ? fusedAccounting : strapAccounting   // never ALG-120's rest-window accounting
        }

        public init(window: Computed<ALG030.RestWindow>, stager: Computed<ALG120.StagedNight>,
                    accounting: Computed<ALG150.Accounting>,
                    strap: Computed<SleepStrapFlag.Epochs>, strapAccounting: Computed<ALG150.Accounting>,
                    fused: Computed<FusedStager.Night> = .missing("not computed"),
                    fusedAccounting: Computed<ALG150.Accounting> = .missing("not computed")) {
            self.window = window
            self.stager = stager
            self.accounting = accounting
            self.strap = strap
            self.strapAccounting = strapAccounting
            self.fused = fused
            self.fusedAccounting = fusedAccounting
        }
    }

    /// `unfinished` (D-SLEEP-LOW-2): the newest strap second and the time of the run; a night that ends within
    /// `ALG150.unfinishedWithinSeconds` of it is blank "night not finished" in all three accountings. nil = no check.
    public static func analyse(seconds s: SleepSeconds, beats: SleepBeats, wakeDay: (start: Double, end: Double)? = nil,
                               unfinished: (dataEnd: Int64, now: Int64)? = nil,
                               strapMethod: SleepStrapFlag.NightMethod = .strapFlag,
                               core: any SignalCore = Signal.core) -> Outcome {
        func settled(_ a: Computed<ALG150.Accounting>) -> Computed<ALG150.Accounting> {
            guard let u = unfinished, let acc = a.value,
                  let why = ALG150.unfinishedReason(acc, dataEnd: u.dataEnd, now: u.now) else { return a }
            return .missing(why)
        }
        let grid = SleepMotionGrid.build(s)
        let window = ALG030.sleepWindow(grid)
        let dayStart = wakeDay?.start
        let dayEnd = wakeDay?.end
        // the strap flag over the whole span: the strap night does not depend on the ALG-030 rest window
        let strapRaw: Computed<SleepStrapFlag.Epochs>
        if let t0 = s.ts.min(), let t1 = s.ts.max() {
            strapRaw = SleepStrapFlag.epochs(ts: s.ts, sleepState: s.sleepState, spanStart: Double(t0), spanEnd: Double(t1 + 1))
        } else {
            strapRaw = .missing("no strap data for this night")
        }
        // D-SLEEP-LOW-5: `.motionWindow` re-draws the strap hypnogram (and the fused one below) on the ALG-030 rest window
        // when the strap vouches for it; otherwise (or with `.strapFlag`) the strap's own code-2 night, as before
        var windowForMotion: ALG030.RestWindow?
        var strap = strapRaw
        if strapMethod == .motionWindow, let ep = strapRaw.value, let w = window.value,
           let h = SleepStrapFlag.motionWindowHypnogram(ep.hypnogram, strap: ep, window: w) {
            var drawn = ep
            drawn.hypnogram = h
            strap = .success(drawn)
            windowForMotion = w
        }
        let strapAccounting = settled(strap.flatMap { ALG150.account($0.hypnogram, dayStart: dayStart, dayEnd: dayEnd) })
        // ALG-151 fused stager: strap flag gate + HR + wrist-angle activity (no R-R, no rest window)
        var fused = strapRaw.map { FusedStager.stage(grid: grid, strap: $0) }
        if let w = windowForMotion, let ep = strapRaw.value {
            fused = fused.map { f in
                var f = f
                f.hypnogram = SleepStrapFlag.motionWindowHypnogram(f.hypnogram, strap: ep, window: w) ?? f.hypnogram
                return f
            }
        }
        let fusedAccounting = settled(fused.flatMap { ALG150.account($0.hypnogram, dayStart: dayStart, dayEnd: dayEnd) })
        guard let w = window.value else {
            let m = Missing(window.missingReason ?? "no sleep window")
            return Outcome(window: window, stager: .failure(m), accounting: .failure(m),
                          strap: strap, strapAccounting: strapAccounting, fused: fused,
                          fusedAccounting: fusedAccounting)
        }
        // ALG-120 on its own, on the rest window (the fallback when the strap has no sleep flag, e.g. WHOOP 4.0)
        let stager = ALG120.stage(grid: grid, beats: beats, spanStart: Double(w.restStart), spanEnd: Double(w.restEnd),
                                  core: core)
        let accounting = settled(stager.flatMap { ALG150.account($0.hypnogram, dayStart: dayStart, dayEnd: dayEnd) })
        return Outcome(window: window, stager: stager, accounting: accounting, strap: strap,
                      strapAccounting: strapAccounting, fused: fused, fusedAccounting: fusedAccounting)
    }
}

/// G-STAGE members written by this family (ALG-120, strap) plus the always-blank ALG-031:A; MS-21 is WP-17's.
public enum SleepStages {
    public static let group = "G-STAGE"

    static func spec(_ key: MetricKey, variant: String, method: String, tier: Tier, producer: Producer,
                     citation: String) -> MetricSpec {
        MetricSpec(key: key, unit: "min", group: group, variant: variant, method: method, tier: tier, source: "R18+rr",
                   window: "night", producer: producer, citation: citation)
    }

    static let keys: [MetricKey] = [.sleepDeep, .sleepLight, .sleepRem, .sleepWake]

    public static let alg120Specs: [MetricSpec] = keys.map {
        spec($0, variant: "ALG-120", method: "ALG-120@1 cole-kripke-webster+hrv", tier: .estimate, producer: .ours,
             citation: ALG120.citation)
    }
    /// Tier M, the primary stage member (D-9745; ALG-151 since Oct 17 2026): its minutes are ALG-150's over the fused hypnogram.
    public static let fusedSpecs: [MetricSpec] = keys.map {
        spec($0, variant: FusedStager.variant, method: FusedStager.method, tier: .estimate, producer: .ours,
             citation: FusedStager.citation + "; " + SleepStrapFlag.citation)
    }
    public static let strapSpecs: [MetricSpec] = keys.map {
        spec($0, variant: "strap", method: "strap@1 byte81-band-state", tier: .strap, producer: .strap,
             citation: SleepStrapFlag.citation)
    }
    public static let alg031ASpecs: [MetricSpec] = keys.map {
        spec($0, variant: "ALG-031:A", method: "ALG-031@A lightgbm-hmm", tier: .estimate, producer: .ours,
             citation: "ALGORITHM-REQUIREMENTS ALG-031 A")
    }

    /// sleep_deep / light / rem / wake for one member from its accounting (wake = W inside onset … final wake).
    public static func metrics(_ specs: [MetricSpec], _ acc: Computed<ALG150.Accounting>, at: Date) -> [Metric] {
        [
            specs[0].metric(acc.flatMap(\.deepMin), at: at),
            specs[1].metric(acc.flatMap(\.lightMin), at: at),
            specs[2].metric(acc.flatMap(\.remMin), at: at),
            specs[3].metric(acc.map(\.wakeMin), at: at),
        ]
    }

    /// ALG-120 member.
    public static func alg120Metrics(_ night: SleepNight.Outcome, at: Date) -> [Metric] {
        metrics(alg120Specs, night.accounting, at: at)
    }

    /// Tier M member: every figure carries the estimate note.
    public static func fusedMetrics(_ night: SleepNight.Outcome, at: Date) -> [Metric] {
        var m = metrics(fusedSpecs, night.fusedAccounting, at: at)
        for i in m.indices where m[i].value != nil { PipelineOutput.addNote(&m[i], FusedStager.confidenceNote) }
        return m
    }

    /// Strap member: deep / light / REM blank (the band flag is sleep / wake only), wake from its own accounting.
    public static func strapMetrics(_ night: SleepNight.Outcome, at: Date) -> [Metric] {
        metrics(strapSpecs, night.strapAccounting, at: at)
    }

    /// ALG-031 A: always blank until a trained model exists (§8.1 X).
    public static func alg031AMetrics(at: Date) -> [Metric] {
        alg031ASpecs.map { $0.blank("no trained staging model yet (ALG-031 A)", at: at) }
    }

    /// The `hypnogram` series for one member: one 30-s step per epoch, `values` null, `state` = the epoch's code
    /// (W L D R S for ALG-120; the strap's own "0"–"3" for the strap member), null for no data.
    public static func series(_ hyp: SleepHypnogram, variant: String, tier: Tier) -> Series {
        let states: [String?] = hyp.codes.map { $0 == "." ? nil : String($0) }
        return Series(name: "hypnogram", unit: "stage", start: Date(timeIntervalSince1970: Double(hyp.epoch0)),
                      stepS: 30, values: [Double?](repeating: nil, count: states.count), state: states, group: group,
                      variant: variant, tier: tier, computedOn: .phone)
    }

    public static func strapSeries(_ e: SleepStrapFlag.Epochs) -> Series {
        series(SleepHypnogram(epoch0: e.epoch0, codes: e.codes), variant: "strap", tier: .strap)
    }
}

/// Every registry metric the sleep family writes (WP-10), for WP-22's pipelines and the registry test.
public enum SleepFamily {
    public static let specs: [MetricSpec] = [
        ALG030.onsetSpec, ALG030.wakeSpec, ALG030.sriSpec, ALG030.isSpec, ALG030.ivSpec, ALG030.raSpec, ALG030.l5Spec,
        ALG030.m10Spec,
        ALG150.totalSpec, ALG150.latencySpec, ALG150.wasoSpec, ALG150.remLatencySpec, ALG150.efficiencySpec,
        ALG150.awakeningsSpec, ALG150.performanceSpec,
        ALG115.needSpec, ALG115.debtSpec, ALG115.bedtimeSpec,
        ALG116.spec,
    ] + SleepStages.alg120Specs + SleepStages.strapSpecs + SleepStages.alg031ASpecs
}
