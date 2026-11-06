import Foundation
import Darwin

/// T10009 (2026-10-17): the process memory iOS judges the app by (`phys_footprint` from `task_vm_info`: the number its
/// memory limit and the "free memory" warnings are about). Read-only, cheap (one kernel call); logged in the heartbeat and
/// with every memory warning so the overnight growth shows up in the app-status log.
enum MemoryFootprint {
    /// Bytes, or nil when the kernel call fails.
    static func bytes() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : nil
    }

    /// "212 MB", or "memory unknown".
    static func text() -> String {
        guard let b = bytes() else { return "memory unknown" }
        return "\(b / 1_048_576) MB"
    }
}
