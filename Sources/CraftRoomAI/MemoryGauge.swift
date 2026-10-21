import Darwin

/// phys_footprint of this process, in bytes (the metric jetsam watches).
func currentFootprint() -> UInt64 {
    var info = task_vm_info()
    var count = mach_msg_type_number_t(
        MemoryLayout<task_vm_info>.size / MemoryLayout<natural_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return kr == KERN_SUCCESS ? UInt64(info.phys_footprint) : 0
}
