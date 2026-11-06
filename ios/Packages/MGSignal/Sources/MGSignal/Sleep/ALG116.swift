import Foundation
import MGDomain

/// ALG-116 v1 — chronotype (MSFsc) and social jetlag from strap sleep timing, MCTQ logic (Roenneberg et al. 2004;
/// Wittmann et al. 2006). Python: `mglab.ref.sleep.chronotype`.
public enum ALG116 {
    static let minNights = 14                // ALG-116: after 14 nights
    static let minFree = 2
    static let sjlMinWork = 2
    public static let citation = "Roenneberg et al. 2004 Curr Biol 14:R1038 (MSFsc); Wittmann et al. 2006 "
        + "Chronobiol Int 23:497 (social jetlag)"

    public struct Night: Sendable, Equatable {
        public var onset: Double
        public var wake: Double
        /// No "must be up by" that morning.
        public var free: Bool

        public init(onset: Double, wake: Double, free: Bool) {
            self.onset = onset
            self.wake = wake
            self.free = free
        }
    }

    public struct Chronotype: Sendable, Equatable {
        public var msfHours: Double
        public var msfScHours: Double
        public var sdFreeHours: Double
        public var sdWeekHours: Double
        public var freeNights: Int
        public var workNights: Int
        public var mswHours: Computed<Double>
        public var socialJetlagHours: Computed<Double>

        public init(msfHours: Double, msfScHours: Double, sdFreeHours: Double, sdWeekHours: Double, freeNights: Int,
                    workNights: Int, mswHours: Computed<Double>, socialJetlagHours: Computed<Double>) {
            self.msfHours = msfHours
            self.msfScHours = msfScHours
            self.sdFreeHours = sdFreeHours
            self.sdWeekHours = sdWeekHours
            self.freeNights = freeNights
            self.workNights = workNights
            self.mswHours = mswHours
            self.socialJetlagHours = socialJetlagHours
        }
    }

    /// Local clock time in hours, unwrapped to [12, 36) so a night never straddles midnight.
    static func hoursFromNoon(_ t: Double, _ off: Int) -> Double {
        let h = Double(SleepMath.floorMod(Int64(t.rounded(.down)) + Int64(off), 86_400)) / 3600.0
        return h < 12.0 ? h + 24.0 : h
    }

    static func wrap24(_ h: Double) -> Double {
        let r = h.truncatingRemainder(dividingBy: 24.0)
        return r < 0 ? r + 24.0 : r
    }

    /// mid-sleep = onset + duration / 2 (local hours, unwrapped); MSF / MSW = mean over free / work nights;
    /// SDweek = count-weighted mean duration (MCTQ uses 5:2 work:free days; we have the real counts);
    /// MSFsc = MSF − (SDf − SDweek) / 2 when SDf > SDweek, else MSF; social jetlag = |MSF − MSW|.
    public static func chronotype(nights: [Night], utcOffsetSeconds: Int) -> Computed<Chronotype> {
        guard nights.count >= minNights else { return .missing("Learning your chronotype: \(nights.count) of \(minNights) nights so far") }
        let free = nights.filter(\.free)
        let work = nights.filter { !$0.free }
        guard free.count >= minFree else { return .missing("Learning your chronotype: \(free.count) of \(minFree) free nights so far") }
        func mids(_ ns: [Night]) -> [Double] {
            ns.map { hoursFromNoon($0.onset + ($0.wake - $0.onset) / 2.0, utcOffsetSeconds) }
        }
        func durs(_ ns: [Night]) -> [Double] { ns.map { ($0.wake - $0.onset) / 3600.0 } }
        func total(_ x: [Double]) -> Double {
            var s = 0.0
            for v in x { s += v }
            return s
        }
        let msf = total(mids(free)) / Double(free.count)
        let sdf = total(durs(free)) / Double(free.count)
        let sdWeek = total(durs(nights)) / Double(nights.count)
        let msfsc = sdf > sdWeek ? msf - (sdf - sdWeek) / 2.0 : msf
        var msw: Computed<Double> = .missing("needs \(sjlMinWork) work nights ('must be up by' set) (have \(work.count))")
        var sjl = msw
        if work.count >= sjlMinWork {
            let m = total(mids(work)) / Double(work.count)
            msw = .success(wrap24(m))
            sjl = .success(Swift.abs(msf - m))
        }
        return .success(Chronotype(msfHours: wrap24(msf), msfScHours: wrap24(msfsc), sdFreeHours: sdf,
                                   sdWeekHours: sdWeek, freeNights: free.count, workNights: work.count,
                                   mswHours: msw, socialJetlagHours: sjl))
    }

    public static let spec = MetricSpec(
        key: .chronotypeMsfSc, unit: "hours", group: nil, variant: "ALG-116", method: "ALG-116@1 mctq-msfsc",
        tier: .estimate, source: "derived", window: "28d", citation: citation, paramsVersion: "min14 free2")

    /// chronotype_msf_sc (28 days ending `at`). Social jetlag has no registry name yet (shown in Explore text).
    public static func metric(_ c: Computed<Chronotype>, at: Date) -> Metric {
        spec.metric(c.map(\.msfScHours), at: at)
    }
}
