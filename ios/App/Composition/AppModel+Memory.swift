import Foundation
import MGBLE
import MGSignal

// T10009 (2026-10-17): 55 "free memory" warnings between 2:45 and 6:21 AM while raw optical streamed; before this the
// recorder only wrote them down. A warning now gives memory back at once: the live graph buffer, the recent R20 records the
// Live screens read, the snapshot caches (they are rebuilt on the next refresh), and raw drops are not built for a minute.
// Nothing stored is touched: everything dropped here is a display copy of data already in the database.

extension AppModel {
    /// How long raw drop building waits after a memory warning.
    static let memoryWarningRawPause: TimeInterval = 60
    /// A history download that stored at least this many records folds the write-ahead log back (about an hour of strap seconds
    /// per 3,600; a night's offload is tens of thousands).
    static let bigHistoryWrite = 3000

    /// Called by the lifecycle recorder on `didReceiveMemoryWarning`. Main actor; cheap (no reads, no rebuild).
    func handleMemoryWarning() {
        let before = MemoryFootprint.text()
        LivePPGFeed.shared.reset()
        if !rawOpticalStatus.recentRecords.isEmpty { rawOpticalStatus.recentRecords = [] }
        matrixCache = nil
        modelOutputsCache = nil
        outputsCache = nil
        storedRecordCache = nil
        let coordinator = services.syncCoordinator
        Task { await coordinator.pauseRawDrops(for: AppModel.memoryWarningRawPause) }
        let after = MemoryFootprint.text()
        ComputeLog.shared.append(.note, "memory warning: dropped the live graph buffer, recent R20 records and snapshot caches; "
                                 + "raw drops paused \(Int(AppModel.memoryWarningRawPause)) s; memory \(before) -> \(after)",
                                 at: clock.now)
    }
}
