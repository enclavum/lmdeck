import Foundation
import Darwin

// System RAM readout. `total` from physicalMemory; `available` ≈ free + inactive pages.
//
// NOTE: free + inactive is an *optimistic* proxy for "usable now" — under macOS memory compression
// some inactive pages are dirty/not instantly reclaimable, so this overstates truly-free memory.
// The load gate (MemoryBudget) therefore leans optimistic; its reserve is the safety cushion.
// Reported in GB (1024³).
enum SystemMemory {
    static var totalBytes: UInt64 { ProcessInfo.processInfo.physicalMemory }

    static var availableBytes: UInt64 {
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        var stats = vm_statistics64_data_t()
        let kr = withUnsafeMutablePointer(to: &stats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, intPtr, &count)
            }
        }
        // Mach effectively never fails here; if it did, fall back to physical memory rather than 0 —
        // returning 0 would make every model with a known estimate look un-loadable.
        guard kr == KERN_SUCCESS else { return totalBytes }
        let ps = UInt64(vm_page_size)   // current kernel page size; no fallible host_page_size call
        return (UInt64(stats.free_count) + UInt64(stats.inactive_count)) * ps
    }

    static func gb(_ bytes: UInt64) -> Double { Double(bytes) / 1_073_741_824 }
}
