import Foundation

/// The CPU budget of one compute run (T140, 2026-10-13). `CPUGovernor` rests between stages; this also stops a run
/// that is in the background on battery once it has used `runCPULimit` CPU seconds, so the rest of the days wait for the
/// app to come forward or for power (they are marked due again by the caller). Always at least one day per run: the
/// caller checks `hasRoom` only after it has done a day. Pure over an injected clock, so it is tested on Linux; the app
/// passes `getrusage` and the system uptime.
public struct WorkBudget: Sendable {
    public struct Clock: Sendable {
        public var cpu: @Sendable () -> Double?
        public var wall: @Sendable () -> Double
        public var sleep: @Sendable (Double) async -> Void
        public init(cpu: @escaping @Sendable () -> Double?, wall: @escaping @Sendable () -> Double,
                    sleep: @escaping @Sendable (Double) async -> Void) {
            self.cpu = cpu; self.wall = wall; self.sleep = sleep
        }
    }

    /// iOS killed background work at 48 s of CPU in about 55 s; stop well before.
    public static let backgroundCPULimit = 20.0
    /// T9995 (2026-10-17): a light background run (night pipeline of the newest day only) stops taking work after this
    /// many CPU seconds. iOS reported 90 s of CPU in 92 s against its limit of 50 % over 180 s, so a run has to stay far
    /// below 90 s and rest long enough between stages (`lightGovernor`) that its average share stays under a quarter.
    public static let lightCPULimit = 10.0
    /// Light runs rest up to 30 s after a slice (the normal background cap of 5 s let a 40 s stage run at 90 % CPU).
    public static let lightGovernor = CPUGovernor(maxShare: 0.2, maxPause: 30)

    public let governor: CPUGovernor
    /// CPU seconds this run may use before it stops taking new days; nil = no limit.
    public let runCPULimit: Double?
    private let clock: Clock
    private let startCPU: Double?
    private var lastCPU: Double?
    private var lastWall: Double

    public init(governor: CPUGovernor, runCPULimit: Double?, clock: Clock) {
        self.governor = governor
        self.runCPULimit = runCPULimit
        self.clock = clock
        startCPU = clock.cpu()
        lastCPU = startCPU
        lastWall = clock.wall()
    }

    /// Something the user waits on may use more of a core; background work less. Background on battery also gets the limit.
    /// `lightBackground` (T9995): the app is in the background, so the run gets the light governor and CPU limit whether
    /// or not the phone is charging (iOS's CPU limit does not care about power).
    public static func forRun(userWaiting: Bool, backgroundOnBattery: Bool, lightBackground: Bool = false,
                              clock: Clock) -> WorkBudget {
        if lightBackground { return WorkBudget(governor: lightGovernor, runCPULimit: lightCPULimit, clock: clock) }
        return WorkBudget(governor: userWaiting ? CPUGovernor(maxShare: 0.8, maxPause: 2) : CPUGovernor(maxShare: 0.4, maxPause: 5),
                   runCPULimit: backgroundOnBattery && !userWaiting ? backgroundCPULimit : nil, clock: clock)
    }

    /// CPU seconds since the run began (0 if the clock cannot say).
    public var spent: Double {
        guard let now = clock.cpu(), let start = startCPU else { return 0 }
        return max(now - start, 0)
    }

    /// False once the limit is used up.
    public var hasRoom: Bool { runCPULimit.map { spent < $0 } ?? true }

    /// Call after each slice of work: sleeps so the share stays under the governor's.
    public mutating func rest() async {
        let cpu = clock.cpu(), wall = clock.wall()
        defer { lastCPU = clock.cpu(); lastWall = clock.wall() }
        guard let cpu, let before = lastCPU else { return }
        let pause = governor.pause(afterSliceCPU: cpu - before, wall: wall - lastWall)
        if pause > 0.01 { await clock.sleep(pause) }
    }
}
