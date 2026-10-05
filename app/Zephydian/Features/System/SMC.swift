import Foundation
import IOKit

/// Reads System Management Controller keys (fans). The kernel's AppleSMC user client takes one
/// 80-byte structure in and out (selector 2); command 9 asks for a key's type and size, 5 reads it.
nonisolated final class SMC: @unchecked Sendable {
    private struct KeyData {
        var key: UInt32 = 0
        var vers: (UInt8, UInt8, UInt8, UInt8, UInt16) = (0, 0, 0, 0, 0)
        var pLimit: (UInt16, UInt16, UInt32, UInt32, UInt32) = (0, 0, 0, 0, 0)
        var dataSize: UInt32 = 0
        var dataType: UInt32 = 0
        var dataAttributes: UInt8 = 0
        var padding: (UInt8, UInt8, UInt8) = (0, 0, 0)   // C pads the key-info struct to 12 bytes
        var result: UInt8 = 0
        var status: UInt8 = 0
        var data8: UInt8 = 0
        var data32: UInt32 = 0
        var bytes: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) =
            (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    }

    private var connection: io_connect_t = 0
    private let lock = NSLock()

    init?() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard IOServiceOpen(service, mach_task_self_, 0, &connection) == KERN_SUCCESS else { return nil }
    }

    deinit { IOServiceClose(connection) }

    private static func code(_ text: String) -> UInt32 { text.utf8.reduce(0) { $0 << 8 | UInt32($1) } }

    private func call(_ input: inout KeyData) -> KeyData? {
        var output = KeyData()
        var size = MemoryLayout<KeyData>.stride
        let result = IOConnectCallStructMethod(connection, 2, &input, MemoryLayout<KeyData>.stride, &output, &size)
        return result == KERN_SUCCESS && output.result == 0 ? output : nil
    }

    /// A key's value as a number (handles the flt, fpe2, ui8, ui16 and ui32 types), or nil.
    func read(_ key: String) -> Double? {
        lock.lock(); defer { lock.unlock() }
        var input = KeyData()
        input.key = Self.code(key)
        input.data8 = 9
        guard let info = call(&input) else { return nil }
        input.dataSize = info.dataSize
        input.dataType = info.dataType
        input.data8 = 5
        guard let out = call(&input) else { return nil }
        let b = withUnsafeBytes(of: out.bytes) { Array($0.prefix(Int(info.dataSize))) }
        switch info.dataType {
        case Self.code("flt "): return b.count >= 4 ? Double(b.withUnsafeBytes { $0.loadUnaligned(as: Float32.self) }) : nil
        case Self.code("fpe2"): return b.count >= 2 ? Double(UInt16(b[0]) << 6 | UInt16(b[1]) >> 2) : nil
        case Self.code("ui8 "): return b.first.map(Double.init)
        case Self.code("ui16"): return b.count >= 2 ? Double(UInt16(b[0]) << 8 | UInt16(b[1])) : nil
        case Self.code("ui32"): return b.count >= 4 ? Double(UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3])) : nil
        default: return nil
        }
    }

    /// Each fan's current speed in RPM.
    func fans() -> [Double] {
        let count = Int(read("FNum") ?? 0)
        return (0..<min(count, 4)).compactMap { read("F\($0)Ac") }
    }
}
