import Foundation
import MGContext
import MGDomain
import MGHealth
import MGStore

// r9u (2026-10-17, CRITICAL for 0.6.0): two things the 0.5.9 phone could not see or do.
//   1. The Apple Health queue's size, in the compute log and in the 5-minute status post (`StorageNotes`).
//   2. Database compaction (`MGStore.runMaintenance`) while the phone charges and the app is open and idle, and from the
//      charging `.compute` BGProcessing task even when its compute is skipped. Before this the VACUUM sat at the end of the
//      `.compute` task, which never ran while raw streams kept the app awake: 467 MB of free pages and a 305 MB WAL stayed.

/// The last lines about the queue and the maintenance, for the status post (read synchronously by `statusExtras()`).
final class StorageNotes: @unchecked Sendable {
    static let shared = StorageNotes()
    private let lock = NSLock()
    private var queueText: String?
    private var maintenanceText: String?
    private var running = false

    var summary: String? {
        lock.lock(); defer { lock.unlock() }
        let parts = [queueText, maintenanceText].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: "; ")
    }

    /// Returns true when the text differs from the last one (the caller logs only changes).
    func setQueue(_ text: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        defer { queueText = text }
        return queueText != text
    }

    func setMaintenance(_ text: String) {
        lock.lock(); defer { lock.unlock() }
        maintenanceText = text
    }

    /// One maintenance at a time.
    func beginMaintenance() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if running { return false }
        running = true
        return true
    }

    func endMaintenance() {
        lock.lock(); defer { lock.unlock() }
        running = false
    }
}

enum HealthQueueNote {
    /// "apple health queue after a run: 3 batches, 1.2 MB, 4500 samples (last problem: ...)" in the compute log when it changed.
    static func record(_ auto: HealthAutoSync, context: String, at: Date) async {
        guard let stats = await auto.queueStats() else { return }
        let state = await auto.status()
        let line = "apple health queue: " + stats.text + (state.lastProblem.map { " (\($0))" } ?? "")
        if StorageNotes.shared.setQueue("apple health queue: " + stats.text) {
            ComputeLog.shared.append(.note, line + " [after \(context)]", at: at)
        }
    }
}

extension AppModel {
    /// Minimum gap between two foreground maintenance runs.
    static let maintenanceGap: TimeInterval = 6 * 3600
    private static let maintenanceLastKey = "mg.maintenance.lastAt"

    /// Called from the 60-second keep-up tick while the app is awake. Runs only when the app is open (`appActive`), the phone
    /// is charging and no history download is going; the first VACUUM (which stalls every store call for minutes) also waits for
    /// raw streams to be off, otherwise the charging background task does it.
    func maintenanceIfDue(charging: Bool, busy: Bool) {
        guard appActive, charging, !busy else { return }
        let last = UserDefaults.standard.double(forKey: Self.maintenanceLastKey)
        if last > 0, clock.now.timeIntervalSince1970 - last < Self.maintenanceGap { return }
        let streams = StrapStreamPolicy.keepsRealtimeOn(rawMotionOn: settings.rawMotionOn, rawOpticalOn: settings.rawOpticalOn,
                                                        opticalNightsOnly: settings.rawOpticalNightsOnly, sample: isSample)
        Task { [weak self] in
            await self?.runStoreMaintenance(reason: "charging, app open", allowFullVacuum: !streams)
        }
    }

    /// Runs `MGStore.runMaintenance`, writes the report (file sizes before and after, free pages, the VACUUM result and the
    /// checkpoint's busy / frames) to the compute log and the status post.
    @discardableResult
    func runStoreMaintenance(reason: String, allowFullVacuum: Bool) async -> String {
        guard StorageNotes.shared.beginMaintenance() else { return "already running" }
        defer { StorageNotes.shared.endMaintenance() }
        let report = await services.store.runMaintenance(allowFullVacuum: allowFullVacuum)
        UserDefaults.standard.set(clock.now.timeIntervalSince1970, forKey: Self.maintenanceLastKey)
        ComputeLog.shared.append(.note, "database maintenance (\(reason)): \(report)", at: clock.now)
        StorageNotes.shared.setMaintenance("database maintenance \(reason): db \(StoreMaintenanceReport.mb(report.dbBytesAfter)), "
                                           + "WAL \(StoreMaintenanceReport.mb(report.walBytesAfter)), free pages \(report.freePagesAfter), "
                                           + report.action + (report.problem.map { " (\($0))" } ?? ""))
        return "database maintenance: \(report.action); db \(StoreMaintenanceReport.mb(report.dbBytesBefore)) -> "
            + "\(StoreMaintenanceReport.mb(report.dbBytesAfter)), WAL \(StoreMaintenanceReport.mb(report.walBytesBefore)) -> "
            + "\(StoreMaintenanceReport.mb(report.walBytesAfter))" + (report.problem.map { " (\($0))" } ?? "")
    }
}
