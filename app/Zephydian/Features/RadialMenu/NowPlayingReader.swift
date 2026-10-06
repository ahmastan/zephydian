import AppKit
import os

/// What's playing on the Mac right now.
struct NowPlaying: Equatable {
    var title: String
    var artist: String
    var artwork: NSImage?
    var isPlaying: Bool
}

/// Reads macOS's Now Playing (the song, its artist and artwork, from any player).
///
/// Since macOS 15.4 only Apple-signed programs get an answer, so Zephydian can't ask itself: it runs
/// `/usr/bin/perl` with `now-playing.pl`, which loads `libZephydianNowPlaying.dylib` (copied from
/// Vorssaint, in Contents/Frameworks) and prints one JSON line. One short run per read, only when a
/// wheel with a now-playing slice opens; nothing stays running.
nonisolated enum NowPlayingReader {
    /// Nil when nothing is playing, or the read failed or took longer than two seconds.
    static func read() async -> NowPlaying? {
        guard let script = Bundle.main.url(forResource: "now-playing", withExtension: "pl"),
              let library = Bundle.main.privateFrameworksURL?.appending(path: "libZephydianNowPlaying.dylib"),
              FileManager.default.fileExists(atPath: library.path) else { return nil }
        let data: Data? = await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(filePath: "/usr/bin/perl")
            process.arguments = [script.path, library.path, "get"]
            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice
            do { try process.run() } catch { return nil }
            // A stuck read is stopped, so a wheel never waits on it for long.
            // (By its process id, which any SDK lets a closure carry.)
            let pid = process.processIdentifier
            let done = OSAllocatedUnfairLock(initialState: false)
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                if !done.withLock({ $0 }) { kill(pid, SIGTERM) }
            }
            defer { done.withLock { $0 = true } }
            // Read while it runs: artwork can be bigger than the pipe's buffer.
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return process.terminationReason == .exit && process.terminationStatus == 0 ? data : nil
        }.value
        guard let data, let line = data.split(separator: UInt8(ascii: "\n")).last,
              let reply = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { return nil }
        return parse(reply)
    }

    static func parse(_ reply: [String: Any]) -> NowPlaying? {
        guard reply["error"] == nil else { return nil }
        let title = (reply["kMRMediaRemoteNowPlayingInfoTitle"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !title.isEmpty else { return nil }
        let artist = (reply["kMRMediaRemoteNowPlayingInfoArtist"] as? String) ?? ""
        let artwork = (reply["artworkBase64"] as? String)
            .flatMap { Data(base64Encoded: $0) }
            .flatMap { $0.count <= 12 * 1024 * 1024 ? NSImage(data: $0) : nil }
        let rate = reply["kMRMediaRemoteNowPlayingInfoPlaybackRate"] as? Double ?? 0
        let isPlaying = reply["isPlaying"] as? Bool ?? (rate > 0)
        return NowPlaying(title: String(title.prefix(200)), artist: String(artist.prefix(200)), artwork: artwork, isPlaying: isPlaying)
    }
}
