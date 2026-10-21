import Darwin

/// phys_footprint of this process, in bytes (the metric jetsam watches).
func currentFootprint() -> UInt64 {
    var info = task_vm_info()
    var count = mach_msg_type_t(
        MemoryLayout<task_vm_info>.stride / MemoryLayout<integer_t>.stride)
    let kr = withUnsafePointer(of: &info) { p in
        task_info(mach_task_self(), task_flavor_t(TASK_VM_INFO),
                  p.bindMemory(to: integer_t.self, capacity: Int(count)), &count)
    }
    return kr == KERN_SUCCESS ? UInt64(info.phys_footprint) : 0
}
