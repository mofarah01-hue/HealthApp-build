import Foundation
import UIKit

/// T9988 (2026-10-15): runs a sync inside `beginBackgroundTask`, so leaving the app mid-upload gives the engine the extra
/// seconds iOS grants instead of freezing it at once. File bodies already go through a background URLSession (they finish
/// on their own); this keeps the step in between (the next file, the commit, the receipts check) running too. When iOS
/// takes the time back, the work is cancelled: the engine stops at the next step and marks the drop part-way, so the next
/// sync sends only what the PC lacks.
enum SyncGrace {
    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var id = UIBackgroundTaskIdentifier.invalid
        private var cancel: (@Sendable () -> Void)?
        private var expired = false

        init(cancel: @escaping @Sendable () -> Void) { self.cancel = cancel }

        /// Stores the task id. If iOS already expired it (before `beginBackgroundTask` returned to us), end it at once so
        /// the id is never leaked (Codex r6phone review, finding 1).
        func arm(id: UIBackgroundTaskIdentifier) {
            lock.lock(); self.id = id; let late = expired; lock.unlock()
            if late { end() }
        }

        /// iOS is taking the time back.
        func expire() {
            lock.lock(); expired = true; let c = cancel; lock.unlock()
            c?()
            end()
        }

        func end() {
            lock.lock(); let taken = id; id = .invalid; cancel = nil; lock.unlock()
            guard taken != .invalid else { return }
            Task { @MainActor in UIApplication.shared.endBackgroundTask(taken) }
        }
    }

    static func run<T: Sendable>(_ name: String, _ work: @escaping @Sendable () async -> T) async -> T {
        let task = Task { await work() }
        let box = Box(cancel: { task.cancel() })
        let id = await MainActor.run { UIApplication.shared.beginBackgroundTask(withName: name) { box.expire() } }
        box.arm(id: id)
        let value = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        box.end()
        return value
    }
}
