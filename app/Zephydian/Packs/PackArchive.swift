import Compression
import Foundation

/// Unpacks a .zpack (a plain zip made by scripts/packs.swift) into a folder. Deliberately strict:
/// only stored or deflated files, no links, no paths that leave the folder, and size limits, so a
/// broken or hostile file can't write anywhere else or fill the disk. Runs only after the file's
/// SHA-256 has matched the signed catalog, so these checks are a second line of defence.
nonisolated enum PackArchive {
    static let maxEntries = 2000
    static let maxTotalBytes = 20 * 1024 * 1024

    struct Failure: Error, CustomStringConvertible { let description: String }

    static func extract(_ data: Data, to folder: URL) throws {
        let bytes = [UInt8](data)
        func u16(_ o: Int) throws -> Int {
            guard o >= 0, o + 2 <= bytes.count else { throw Failure(description: "the pack file is cut short") }
            return Int(bytes[o]) | Int(bytes[o + 1]) << 8
        }
        func u32(_ o: Int) throws -> Int {
            guard o >= 0, o + 4 <= bytes.count else { throw Failure(description: "the pack file is cut short") }
            return Int(bytes[o]) | Int(bytes[o + 1]) << 8 | Int(bytes[o + 2]) << 16 | Int(bytes[o + 3]) << 24
        }

        // The end-of-central-directory record is in the last 64 KB + 22 bytes.
        var eocd = -1
        var i = bytes.count - 22
        while i >= max(0, bytes.count - 65_557) {
            if try u32(i) == 0x0605_4B50 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { throw Failure(description: "not a pack file") }
        let count = try u16(eocd + 10)
        var offset = try u32(eocd + 16)
        guard count <= maxEntries else { throw Failure(description: "too many files in the pack") }

        let root = folder.standardizedFileURL
        var total = 0
        for _ in 0..<count {
            guard try u32(offset) == 0x0201_4B50 else { throw Failure(description: "the pack's file list is damaged") }
            let flags = try u16(offset + 8), method = try u16(offset + 10)
            let compressedSize = try u32(offset + 20), size = try u32(offset + 24)
            let nameLength = try u16(offset + 28), extraLength = try u16(offset + 30), commentLength = try u16(offset + 32)
            let externalAttributes = try u32(offset + 38), localOffset = try u32(offset + 42)
            guard offset + 46 + nameLength <= bytes.count,
                  let name = String(bytes: bytes[(offset + 46)..<(offset + 46 + nameLength)], encoding: .utf8) else {
                throw Failure(description: "a file name in the pack can't be read")
            }
            offset += 46 + nameLength + extraLength + commentLength

            guard flags & 0x1 == 0 else { throw Failure(description: "encrypted files aren't allowed") }
            let unixMode = externalAttributes >> 16
            guard unixMode & 0o170000 != 0o120000 else { throw Failure(description: "\(name) is a link, which isn't allowed") }
            let parts = name.split(separator: "/", omittingEmptySubsequences: false)
            guard !name.isEmpty, !name.hasPrefix("/"), !name.contains("\\"), !parts.contains(".."), !parts.dropLast().contains("") else {
                throw Failure(description: "\(name) isn't a safe file name")
            }
            let target = root.appending(path: name).standardizedFileURL
            guard target.path.hasPrefix(root.path + "/") else { throw Failure(description: "\(name) would leave the pack's folder") }

            if name.hasSuffix("/") {
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
                continue
            }
            total += size
            guard total <= maxTotalBytes else { throw Failure(description: "the pack is too big once unpacked") }

            // The local header repeats the name and has its own extra field; the data follows it.
            guard try u32(localOffset) == 0x0403_4B50 else { throw Failure(description: "the pack is damaged") }
            let start = localOffset + 30 + (try u16(localOffset + 26)) + (try u16(localOffset + 28))
            guard start >= 0, start + compressedSize <= bytes.count else { throw Failure(description: "the pack is cut short") }
            let stored = Data(bytes[start..<(start + compressedSize)])

            let contents: Data
            switch method {
            case 0: contents = stored
            case 8: contents = try inflate(stored, expectedSize: size)
            default: throw Failure(description: "\(name) uses a compression Zephydian can't read")
            }
            guard contents.count == size else { throw Failure(description: "\(name) has the wrong size") }
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: target)
        }
    }

    /// Raw DEFLATE (what zip uses), with Apple's Compression framework.
    private static func inflate(_ data: Data, expectedSize: Int) throws -> Data {
        guard expectedSize > 0 else { return Data() }
        guard !data.isEmpty else { throw Failure(description: "a file in the pack is empty") }
        var output = Data(count: expectedSize)
        let written = output.withUnsafeMutableBytes { out in
            data.withUnsafeBytes { input in
                compression_decode_buffer(out.bindMemory(to: UInt8.self).baseAddress!, expectedSize,
                                          input.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written == expectedSize else { throw Failure(description: "a file in the pack can't be unpacked") }
        return output
    }
}
