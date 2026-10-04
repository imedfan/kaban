import Darwin
import Foundation

/// Снимок процесса для полосы метрик. `task_info(TASK_VM_INFO)` — обычный способ
/// получить phys_footprint; с SDK 26 это не сверялось. Если константа не соберётся,
/// см. README, раздел «Если не собирается».
enum ProcessStats {
    struct Snapshot {
        var footprintBytes: UInt64?
        var cpuSeconds: TimeInterval
    }

    static func snapshot() -> Snapshot {
        Snapshot(footprintBytes: physicalFootprint(), cpuSeconds: cpuSeconds())
    }

    static func physicalFootprint() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.stride / MemoryLayout<integer_t>.stride
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer -> kern_return_t in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return UInt64(info.phys_footprint)
    }

    static func cpuSeconds() -> TimeInterval {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
        return seconds(usage.ru_utime) + seconds(usage.ru_stime)
    }

    private static func seconds(_ value: timeval) -> TimeInterval {
        TimeInterval(value.tv_sec) + TimeInterval(value.tv_usec) / 1_000_000
    }
}
