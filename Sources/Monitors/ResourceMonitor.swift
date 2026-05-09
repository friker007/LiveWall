import Foundation
import Combine

class ResourceMonitor: ObservableObject {
    static let shared = ResourceMonitor()
    
    @Published var cpuUsage: Double = 0.0
    @Published var memoryUsageBytes: UInt64 = 0
    
    private var timer: Timer?
    
    private init() {
        start()
    }
    
    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.update()
        }
        update()
    }
    
    func stop() {
        timer?.invalidate()
        timer = nil
    }
    
    private func update() {
        if let cpu = getCPUUsage() {
            self.cpuUsage = min(100.0, max(0.0, cpu))
        }
        if let mem = getMemoryUsage() {
            self.memoryUsageBytes = mem
        }
    }
    
    private func getMemoryUsage() -> UInt64? {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
        let kerr: kern_return_t = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        if kerr == KERN_SUCCESS {
            return info.resident_size
        }
        return nil
    }
    
    private func getCPUUsage() -> Double? {
        var threadList: thread_act_array_t?
        var threadCount: mach_msg_type_number_t = 0
        let kerr = task_threads(mach_task_self_, &threadList, &threadCount)
        
        guard kerr == KERN_SUCCESS, let threads = threadList else { return nil }
        defer {
            let size = vm_size_t(threadCount) * vm_size_t(MemoryLayout<thread_t>.size)
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: threads)), size)
        }
        
        var totalCPU: Double = 0.0
        for i in 0..<Int(threadCount) {
            var threadInfo = thread_basic_info()
            var threadInfoCount = mach_msg_type_number_t(THREAD_INFO_MAX)
            let infoKerr = withUnsafeMutablePointer(to: &threadInfo) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(threadInfoCount)) {
                    thread_info(threads[i], thread_flavor_t(THREAD_BASIC_INFO), $0, &threadInfoCount)
                }
            }
            
            if infoKerr == KERN_SUCCESS {
                if (threadInfo.flags & TH_FLAGS_IDLE) == 0 {
                    totalCPU += Double(threadInfo.cpu_usage) / Double(TH_USAGE_SCALE) * 100.0
                }
            }
        }
        
        return totalCPU
    }
}
