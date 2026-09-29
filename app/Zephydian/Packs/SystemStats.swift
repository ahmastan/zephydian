import Darwin
import Foundation
import IOKit.ps

/// Readings for the `system.stats` capability: CPU, memory, disk, battery, network and uptime.
/// Nothing runs in the background: each reading happens when a utility asks (the System utility
/// asks once a second while it's on screen). CPU and network are the change since the previous
/// reading. There are no per-app figures: inside the sandbox they can't match Activity Monitor.
final class SystemStats {
    private var lastCPU: (ticks: [UInt32], at: Date)?
    private var lastNet: (inBytes: UInt64, outBytes: UInt64, at: Date)?

    func read() -> [String: Any] {
        var out: [String: Any] = ["uptime": ProcessInfo.processInfo.systemUptime]
        out["cpu"] = cpu()
        out["memory"] = memory()
        out["disk"] = disk()
        out["battery"] = battery()
        out["network"] = network()
        return out
    }

    // MARK: CPU

    /// Percent busy (user, system) since the last reading, across all cores.
    private func cpu() -> [String: Any] {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count) }
        }
        guard result == KERN_SUCCESS else { return [:] }
        let ticks = [info.cpu_ticks.0, info.cpu_ticks.1, info.cpu_ticks.2, info.cpu_ticks.3]   // user, system, idle, nice
        defer { lastCPU = (ticks, Date()) }
        guard let last = lastCPU?.ticks else { return ["user": 0, "system": 0, "cores": ProcessInfo.processInfo.activeProcessorCount] }
        let d = zip(ticks, last).map { Double($0 &- $1) }
        let total = max(d.reduce(0, +), 1)
        return ["user": (d[0] + d[3]) / total * 100, "system": d[1] / total * 100,
                "cores": ProcessInfo.processInfo.activeProcessorCount]
    }

    // MARK: Memory

    /// Used = app memory + wired + compressed, like Activity Monitor's "Memory Used".
    private func memory() -> [String: Any] {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }
        let total = Double(ProcessInfo.processInfo.physicalMemory)
        guard result == KERN_SUCCESS else { return ["total": total] }
        let page = Double(getpagesize())
        let app = Double(stats.internal_page_count) - Double(stats.purgeable_count)
        let used = (app + Double(stats.wire_count) + Double(stats.compressor_page_count)) * page
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let pressure = sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0
            ? (level >= 4 ? "high" : level >= 2 ? "medium" : "normal") : "unknown"
        return ["used": min(used, total), "total": total, "pressure": pressure]
    }

    // MARK: Disk

    private func disk() -> [String: Any] {
        let url = URL(filePath: "/")
        guard let v = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]),
              let total = v.volumeTotalCapacity else { return [:] }
        return ["total": Double(total), "free": Double(v.volumeAvailableCapacityForImportantUsage ?? 0)]
    }

    // MARK: Battery

    private func battery() -> [String: Any] {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return ["present": false] }
        for source in list {
            guard let d = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  d[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
            let current = d[kIOPSCurrentCapacityKey] as? Int ?? 0, max = d[kIOPSMaxCapacityKey] as? Int ?? 100
            var out: [String: Any] = [
                "present": true,
                "level": max > 0 ? Double(current) / Double(max) * 100 : 0,
                "charging": d[kIOPSIsChargingKey] as? Bool ?? false,
                "pluggedIn": d[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue,
                "health": d[kIOPSBatteryHealthKey] as? String ?? "Unknown",
            ]
            if let minutes = d[kIOPSTimeToEmptyKey] as? Int, minutes > 0 { out["minutesLeft"] = minutes }
            if let minutes = d[kIOPSTimeToFullChargeKey] as? Int, minutes > 0 { out["minutesToFull"] = minutes }
            return out
        }
        return ["present": false]
    }

    // MARK: Network

    /// Bytes per second in and out since the last reading, over all physical interfaces.
    private func network() -> [String: Any] {
        var inBytes: UInt64 = 0, outBytes: UInt64 = 0
        var addrs: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addrs) == 0, let first = addrs else { return [:] }
        defer { freeifaddrs(addrs) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let ifa = cursor {
            let name = String(cString: ifa.pointee.ifa_name)
            if ifa.pointee.ifa_addr?.pointee.sa_family == UInt8(AF_LINK), name.hasPrefix("en") || name.hasPrefix("pdp_ip"),
               let data = ifa.pointee.ifa_data?.assumingMemoryBound(to: if_data.self) {
                inBytes += UInt64(data.pointee.ifi_ibytes)
                outBytes += UInt64(data.pointee.ifi_obytes)
            }
            cursor = ifa.pointee.ifa_next
        }
        let now = Date()
        defer { lastNet = (inBytes, outBytes, now) }
        guard let last = lastNet else { return ["in": 0, "out": 0] }
        let seconds = max(now.timeIntervalSince(last.at), 0.001)
        // The counters are 32-bit on some interfaces and wrap around; a wrap reads as 0 for one tick.
        let dIn = inBytes >= last.inBytes ? Double(inBytes - last.inBytes) : 0
        let dOut = outBytes >= last.outBytes ? Double(outBytes - last.outBytes) : 0
        return ["in": dIn / seconds, "out": dOut / seconds]
    }
}
