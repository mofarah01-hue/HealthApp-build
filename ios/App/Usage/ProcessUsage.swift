import Darwin
import Foundation
import MGContext

// Settings › Usage (tracker #40): the app process's own counters, read from the kernel — CPU time (getrusage), the
// memory iOS charges the app with (TASK_VM_INFO phys_footprint), CPU wake-ups (TASK_POWER_INFO interrupt wake-ups and
// wake-ups from package idle: the energy-relevant counters an app can read about itself), the thermal state and Low
// Power Mode. All since the process started; across launches only per background run (BackgroundRunLog).

enum ProcessUsage {
    /// User + system CPU seconds of this process; nil if getrusage fails.
    static func cpuSeconds() -> Double? {
        cpu().map { $0.user + $0.system }
    }

    static func cpu() -> (user: Double, system: Double)? {
        var r = rusage()
        guard getrusage(RUSAGE_SELF, &r) == 0 else { return nil }
        func s(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1_000_000 }
        return (s(r.ru_utime), s(r.ru_stime))
    }

    /// When this process started (sysctl KERN_PROC_PID p_starttime); the first call's time if that fails.
    static var launchedAt: Date {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        if sysctl(&mib, 4, &info, &size, nil, 0) == 0 {
            let t = info.kp_proc.p_un.__p_starttime
            if t.tv_sec > 0 { return Date(timeIntervalSince1970: Double(t.tv_sec) + Double(t.tv_usec) / 1_000_000) }
        }
        return fallbackLaunch
    }

    private static let fallbackLaunch = Date()

    static func memoryFootprint() -> Int64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { p in
            p.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? Int64(info.phys_footprint) : nil
    }

    static func wakeups() -> (interrupt: Int64, idle: Int64)? {
        var info = task_power_info()
        var count = mach_msg_type_number_t(MemoryLayout<task_power_info>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { p in
            p.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_POWER_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        return (Int64(info.task_interrupt_wakeups), Int64(info.task_platform_idle_wakeups))
    }

    static func sample() -> ProcessUsageSample {
        let c = cpu()
        let w = wakeups()
        let thermal: String
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: thermal = "nominal"
        case .fair: thermal = "fair"
        case .serious: thermal = "serious"
        case .critical: thermal = "critical"
        @unknown default: thermal = "unknown"
        }
        return ProcessUsageSample(launchedAt: launchedAt, cpuUserSeconds: c?.user ?? 0,
                                  cpuSystemSeconds: c?.system ?? 0, memoryBytes: memoryFootprint(),
                                  interruptWakeups: w?.interrupt, idleWakeups: w?.idle, thermalState: thermal,
                                  lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled)
    }
}
