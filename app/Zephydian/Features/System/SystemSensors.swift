import Darwin
import Foundation
import IOKit

/// The readings beyond CPU, memory and disk: GPU, temperatures, fans, battery details, power draw,
/// the busiest apps and network addresses. Each is read when asked; nothing polls by itself.
nonisolated enum SystemSensors {
    /// A C string buffer as text (up to its first zero byte).
    static func text(_ buffer: [CChar]) -> String {
        String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    // MARK: GPU

    /// Percent busy, from the graphics driver's own statistics (nil when it doesn't publish them).
    static func gpu() -> Double? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var best: Double?
        var service = IOIteratorNext(iterator)
        while service != 0 {
            if let perf = IORegistryEntryCreateCFProperty(service, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any],
               let value = (perf["Device Utilization %"] as? NSNumber)?.doubleValue {
                best = max(best ?? 0, value)
            }
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
        return best
    }

    // MARK: Temperatures

    private typealias ClientCreate = @convention(c) (CFAllocator?) -> Unmanaged<AnyObject>?
    private typealias SetMatching = @convention(c) (AnyObject, CFDictionary) -> Void
    private typealias CopyServices = @convention(c) (AnyObject) -> Unmanaged<CFArray>?
    private typealias CopyEvent = @convention(c) (AnyObject, Int64, Int32, Int64) -> Unmanaged<AnyObject>?
    private typealias FloatValue = @convention(c) (AnyObject, Int32) -> Double
    private typealias CopyProperty = @convention(c) (AnyObject, CFString) -> Unmanaged<AnyObject>?

    private struct HID: @unchecked Sendable {
        /// Kept alive for as long as its services are used (they stop working once it's released).
        let client: AnyObject
        /// Only the sensors that are shown, with their group ("cpu", "battery", "ssd").
        let sensors: [(service: AnyObject, group: String)]
        let copyEvent: CopyEvent
        let value: FloatValue
    }

    /// Apple silicon's temperature sensors, through the HID event system (no special rights needed).
    private static let hid: HID? = {
        guard let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY),
              let create = dlsym(handle, "IOHIDEventSystemClientCreate"), let match = dlsym(handle, "IOHIDEventSystemClientSetMatching"),
              let copy = dlsym(handle, "IOHIDEventSystemClientCopyServices"), let event = dlsym(handle, "IOHIDServiceClientCopyEvent"),
              let value = dlsym(handle, "IOHIDEventGetFloatValue"), let property = dlsym(handle, "IOHIDServiceClientCopyProperty"),
              let client = unsafeBitCast(create, to: ClientCreate.self)(kCFAllocatorDefault)?.takeRetainedValue() else { return nil }
        // Usage page 0xff00, usage 5: temperature sensors.
        unsafeBitCast(match, to: SetMatching.self)(client, ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5] as CFDictionary)
        let services = (unsafeBitCast(copy, to: CopyServices.self)(client)?.takeRetainedValue() as? [AnyObject]) ?? []
        let name = unsafeBitCast(property, to: CopyProperty.self)
        let sensors: [(AnyObject, String)] = services.compactMap { service in
            guard let product = name(service, "Product" as CFString)?.takeRetainedValue() as? String else { return nil }
            let group = product.contains("tdie") ? "cpu" : product.hasPrefix("gas gauge") ? "battery" : product.hasPrefix("NAND") ? "ssd" : nil
            return group.map { (service, $0) }
        }
        return HID(client: client, sensors: sensors, copyEvent: unsafeBitCast(event, to: CopyEvent.self),
                   value: unsafeBitCast(value, to: FloatValue.self))
    }()

    static let smc = SMC()

    /// Reading every sensor takes tens of milliseconds, so it happens off the main thread and the
    /// latest values are kept here; `temperatures()` returns them and asks for fresh ones.
    private final class TemperatureCache: @unchecked Sendable {
        let lock = NSLock()
        var values: [String: Double] = [:]
        var reading = false
        var at = Date.distantPast
    }
    private static let cache = TemperatureCache()

    /// Averages in °C: "cpu" (the chip's die sensors), "battery", "ssd". Missing ones are left out.
    /// The values are at most a couple of seconds old (empty on the very first call).
    static func temperatures() -> [String: Double] {
        cache.lock.lock()
        let values = cache.values
        let stale = !cache.reading && Date().timeIntervalSince(cache.at) > 1.5
        if stale { cache.reading = true }
        cache.lock.unlock()
        if stale {
            DispatchQueue.global(qos: .utility).async {
                let fresh = readTemperatures()
                cache.lock.lock()
                cache.values = fresh
                cache.at = Date()
                cache.reading = false
                cache.lock.unlock()
            }
        }
        return values
    }

    /// The actual reading (slow; call it off the main thread).
    static func readTemperatures() -> [String: Double] {
        var groups: [String: [Double]] = [:]
        if let hid {
            for sensor in hid.sensors {
                guard let event = hid.copyEvent(sensor.service, 15, 0, 0)?.takeRetainedValue() else { continue }
                let celsius = hid.value(event, 15 << 16)
                guard celsius > 5, celsius < 130 else { continue }   // some sensors report junk
                groups[sensor.group, default: []].append(celsius)
            }
        }
        var out = groups.mapValues { $0.reduce(0, +) / Double($0.count) }
        if out["cpu"] == nil, let intel = smc?.read("TC0P"), intel > 5 { out["cpu"] = intel }   // Intel Macs
        return out
    }

    /// Each fan's speed in RPM (empty on Macs without fans).
    static func fans() -> [Double] { smc?.fans() ?? [] }

    // MARK: Battery and power

    /// Health (full charge now ÷ new), cycles, the battery's power and the whole Mac's power draw in watts.
    static func battery() -> [String: Any] {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return [:] }
        defer { IOObjectRelease(service) }
        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let d = props?.takeRetainedValue() as? [String: Any] else { return [:] }
        var out: [String: Any] = [:]
        if let cycles = d["CycleCount"] as? Int { out["cycles"] = cycles }
        let data = d["BatteryData"] as? [String: Any] ?? [:]
        let design = (data["DesignCapacity"] ?? d["DesignCapacity"]) as? Double
        let full = (data["NominalChargeCapacity"] ?? d["NominalChargeCapacity"] ?? d["AppleRawMaxCapacity"]) as? Double
        if let design, let full, design > 0 { out["healthPercent"] = min(100, full / design * 100) }
        if let telemetry = d["PowerTelemetryData"] as? [String: Any] {
            if let input = (telemetry["SystemPowerIn"] as? NSNumber)?.doubleValue { out["systemWatts"] = input / 1000 }
            if let battery = (telemetry["BatteryPower"] as? NSNumber)?.doubleValue { out["batteryWatts"] = battery / 1000 }
        }
        if let adapter = d["AdapterDetails"] as? [String: Any], let watts = adapter["Watts"] as? Int, watts > 0 { out["adapterWatts"] = watts }
        return out
    }

    // MARK: Network

    /// The Mac's IPv4 addresses on its network interfaces (Wi-Fi, Ethernet), like "192.168.1.20".
    static func localAddresses() -> [String] {
        var addrs: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addrs) == 0, let first = addrs else { return [] }
        defer { freeifaddrs(addrs) }
        var out: [String] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let ifa = cursor {
            defer { cursor = ifa.pointee.ifa_next }
            let name = String(cString: ifa.pointee.ifa_name)
            guard name.hasPrefix("en"), let addr = ifa.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  ifa.pointee.ifa_flags & UInt32(IFF_UP) != 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                out.append(SystemSensors.text(host))
            }
        }
        return out
    }
}

/// Which apps are using the CPU: the change in each process's CPU time between two readings,
/// added up per app (helpers count toward the app they live in), as a percent of one core like
/// Activity Monitor shows.
nonisolated final class BusyApps: @unchecked Sendable {
    private var last: [pid_t: UInt64] = [:]
    private var lastAt: UInt64 = 0
    private let lock = NSLock()
    private static let timebase: (numer: UInt64, denom: UInt64) = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return (UInt64(info.numer), UInt64(max(info.denom, 1)))
    }()

    func read(limit: Int = 6) -> [[String: Any]] {
        lock.lock(); defer { lock.unlock() }
        var pids = [pid_t](repeating: 0, count: 8192)
        let count = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
        let now = mach_absolute_time()
        var times: [pid_t: UInt64] = [:]
        var perApp: [String: Double] = [:]
        let elapsed = Double((now - lastAt) * Self.timebase.numer / Self.timebase.denom)   // ns
        for pid in pids.prefix(max(0, count)) where pid > 0 {
            var info = rusage_info_v4()
            let result = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
            }
            guard result == 0 else { continue }
            // Apple silicon reports these in mach time units; convert to nanoseconds.
            let cpu = (info.ri_user_time + info.ri_system_time) * Self.timebase.numer / Self.timebase.denom
            times[pid] = cpu
            guard lastAt != 0, let before = last[pid], cpu >= before, elapsed > 0 else { continue }
            let percent = Double(cpu - before) / elapsed * 100
            guard percent > 0.05 else { continue }
            perApp[Self.appName(pid), default: 0] += percent
        }
        last = times
        lastAt = now
        return perApp.sorted { $0.value > $1.value }.prefix(limit).map { ["name": $0.key, "cpu": $0.value] }
    }

    /// The outermost app a process belongs to ("Google Chrome" for its helpers), or its own name.
    private static func appName(_ pid: pid_t) -> String {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        if proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 {
            let path = SystemSensors.text(buffer)
            if let range = path.range(of: ".app/") {
                let appPath = String(path[..<range.lowerBound]) + ".app"
                return (appPath as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: "")
            }
            return (path as NSString).lastPathComponent
        }
        var name = [CChar](repeating: 0, count: 256)
        proc_name(pid, &name, UInt32(name.count))
        return SystemSensors.text(name)
    }
}

/// Things that use the network, only when the person asks: the public IP address and a speed test
/// (Cloudflare's speed test endpoints, which don't need an account).
nonisolated enum NetworkTests {
    static func publicAddress() async -> String? {
        guard let url = URL(string: "https://api.ipify.org") else { return nil }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
        request.setValue("Zephydian", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              text.count <= 45 else { return nil }
        return text
    }

    /// Download and upload speeds in megabits per second, and the round trip in milliseconds.
    static func speedTest(progress: @escaping @Sendable (String) -> Void) async -> [String: Double]? {
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        guard let ping = URL(string: "https://speed.cloudflare.com/__down?bytes=0"),
              let down = URL(string: "https://speed.cloudflare.com/__down?bytes=25000000"),
              let up = URL(string: "https://speed.cloudflare.com/__up") else { return nil }
        progress("latency")
        var latencies: [Double] = []
        for _ in 0..<3 {
            let start = Date()
            guard (try? await session.data(from: ping)) != nil else { return nil }
            latencies.append(Date().timeIntervalSince(start) * 1000)
        }
        progress("download")
        var start = Date()
        guard let (data, _) = try? await session.data(from: down) else { return nil }
        let download = Double(data.count) * 8 / Date().timeIntervalSince(start) / 1_000_000
        progress("upload")
        var request = URLRequest(url: up)
        request.httpMethod = "POST"
        let payload = Data(count: 10_000_000)
        start = Date()
        guard (try? await session.upload(for: request, from: payload)) != nil else { return nil }
        let upload = Double(payload.count) * 8 / Date().timeIntervalSince(start) / 1_000_000
        return ["download": download, "upload": upload, "latency": latencies.min() ?? 0]
    }
}
