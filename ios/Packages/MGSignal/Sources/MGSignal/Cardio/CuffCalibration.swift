/// Cuff readings paired with pulse-arrival time. This deliberately fits no blood-pressure model yet.
public enum CuffCalibration {
    public struct Reading: Sendable, Equatable {
        public var systolic: Double
        public var diastolic: Double
        public var pulseArrivalTimeMs: Double?

        public init(systolic: Double, diastolic: Double, pulseArrivalTimeMs: Double? = nil) {
            self.systolic = systolic
            self.diastolic = diastolic
            self.pulseArrivalTimeMs = pulseArrivalTimeMs
        }
    }

    public struct Pair: Sendable, Equatable {
        public var systolic: Double
        public var diastolic: Double
        public var pulseArrivalTimeMs: Double
    }

    /// Keeps only valid readings that have pulse-arrival time. These are calibration inputs, not BP estimates.
    public static func paired(_ readings: [Reading]) -> Computed<[Pair]> {
        let pairs = readings.compactMap { reading -> Pair? in
            guard let pat = reading.pulseArrivalTimeMs, reading.systolic.isFinite, reading.diastolic.isFinite,
                  pat.isFinite else { return nil }
            return Pair(systolic: reading.systolic, diastolic: reading.diastolic, pulseArrivalTimeMs: pat)
        }
        guard pairs.count >= 10 else { return .missing("needs at least 10 paired readings") }
        return .success(pairs)
    }
}
