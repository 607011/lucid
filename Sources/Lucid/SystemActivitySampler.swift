import Darwin
import Foundation
import IOKit

/// One CPU/GPU utilization reading. `gpu` is always `nil` on Intel – see
/// `SystemActivitySampler.isAppleSiliconAvailable`.
struct SystemActivitySample {
    /// Aggregate CPU usage across all cores, 0...1.
    let cpu: Double
    /// Apple Silicon GPU usage, 0...1, or `nil` on Intel / if unavailable.
    let gpu: Double?
}

/// Periodically samples system-wide CPU and (Apple Silicon only) GPU
/// utilization for `ActivityOverlayController`'s screensaver-style chart.
/// Both readings come from public APIs – no `dlopen`/private framework
/// needed here, unlike the display-brightness code elsewhere in the app.
final class SystemActivitySampler {

    /// Whether this Mac can report GPU utilization at all (Apple Silicon
    /// only – there's no equivalent path implemented here for Intel's
    /// integrated/discrete GPUs, matching the requirement that GPU only
    /// shows up on Apple Silicon).
    static let isAppleSiliconAvailable: Bool = {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        sysctlbyname("hw.optional.arm64", &value, &size, nil, 0)
        return value == 1
    }()

    private static let pollInterval: TimeInterval = 1.0

    private var timer: Timer?
    private var previousCPUTicks: (user: UInt32, system: UInt32, idle: UInt32, nice: UInt32)?
    private var handler: ((SystemActivitySample) -> Void)?

    /// No-op if already running. Takes one throwaway CPU sample
    /// immediately (there's nothing to diff the first reading against),
    /// so the first *reported* sample arrives after `pollInterval`, not
    /// instantly.
    func start(handler: @escaping (SystemActivitySample) -> Void) {
        guard timer == nil else { return }
        self.handler = handler
        _ = sampleCPUFraction()

        timer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        handler = nil
        previousCPUTicks = nil
    }

    private func tick() {
        guard let cpu = sampleCPUFraction() else { return }
        handler?(SystemActivitySample(cpu: cpu, gpu: sampleGPUFraction()))
    }

    // MARK: - CPU

    /// Aggregate CPU usage across all cores since the previous call, via
    /// `host_processor_info` (the same public Mach API `top`/htop-style
    /// tools use) – `nil` on the very first call, before there's a
    /// previous reading to diff against.
    private func sampleCPUFraction() -> Double? {
        var numCPUsU: natural_t = 0
        var cpuInfo: processor_info_array_t!
        var numCpuInfo: mach_msg_type_number_t = 0

        let result = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &numCPUsU, &cpuInfo, &numCpuInfo)
        guard result == KERN_SUCCESS, let cpuInfo else { return nil }
        defer {
            let size = vm_size_t(Int(numCpuInfo) * MemoryLayout<integer_t>.size)
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: UnsafeMutableRawPointer(cpuInfo))), size)
        }

        var totalUser: UInt32 = 0
        var totalSystem: UInt32 = 0
        var totalIdle: UInt32 = 0
        var totalNice: UInt32 = 0
        for i in 0..<Int(numCPUsU) {
            let offset = Int(CPU_STATE_MAX) * i
            totalUser += UInt32(cpuInfo[offset + Int(CPU_STATE_USER)])
            totalSystem += UInt32(cpuInfo[offset + Int(CPU_STATE_SYSTEM)])
            totalIdle += UInt32(cpuInfo[offset + Int(CPU_STATE_IDLE)])
            totalNice += UInt32(cpuInfo[offset + Int(CPU_STATE_NICE)])
        }

        let current = (user: totalUser, system: totalSystem, idle: totalIdle, nice: totalNice)
        defer { previousCPUTicks = current }
        guard let previous = previousCPUTicks else { return nil }

        // Wrapping subtraction: tick counters are cumulative since boot
        // and stored as 32-bit, so they can in principle roll over on a
        // long-running Mac. `&-` on UInt32 still yields the correct small
        // delta as long as it wraps at most once between two samples a
        // second apart, which any realistic tick rate guarantees.
        let userDiff = Double(current.user &- previous.user)
        let systemDiff = Double(current.system &- previous.system)
        let idleDiff = Double(current.idle &- previous.idle)
        let niceDiff = Double(current.nice &- previous.nice)
        let totalDiff = userDiff + systemDiff + idleDiff + niceDiff
        guard totalDiff > 0 else { return 0 }

        return (userDiff + systemDiff + niceDiff) / totalDiff
    }

    // MARK: - GPU (Apple Silicon only)

    /// Reads the Apple Silicon GPU's utilization from its IORegistry
    /// entry. `IOServiceMatching`/`IORegistryEntryCreateCFProperties` are
    /// standard public IOKit calls; only the specific property key
    /// ("PerformanceStatistics" -> "Device Utilization %") isn't in any
    /// public header – it's long-standing, widely relied-upon (e.g. by
    /// the Stats.app / asitop family of tools) informal API surface
    /// rather than a private symbol lookup, so unlike
    /// `NativeDisplayBrightness`/`ExternalDisplayBrightness` this needs
    /// no `dlopen` and no graceful-degradation-on-missing-symbol design –
    /// worst case the dictionary lookup below just doesn't find the key.
    private func sampleGPUFraction() -> Double? {
        guard Self.isAppleSiliconAvailable else { return nil }
        guard let matching = IOServiceMatching("IOAccelerator") else { return nil }

        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }

        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer {
                IOObjectRelease(service)
                service = IOIteratorNext(iterator)
            }
            var propertiesUnmanaged: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(service, &propertiesUnmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let properties = propertiesUnmanaged?.takeRetainedValue() as? [String: Any],
                  let stats = properties["PerformanceStatistics"] as? [String: Any],
                  let utilization = stats["Device Utilization %"] as? Int else {
                continue
            }
            return Double(utilization) / 100.0
        }
        return nil
    }

    deinit {
        stop()
    }
}
