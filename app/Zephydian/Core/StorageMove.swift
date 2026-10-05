import AppKit

/// Brings data over from the App Sandbox container, once.
///
/// Zephydian ran in the App Sandbox until 0.6. It left it so features like Dock Preview and the app
/// switcher can read other apps' windows (macOS Accessibility, which the sandbox blocks). Outside the
/// sandbox the app no longer sees its old container, so the first launch copies everything across:
///
///     ~/Library/Containers/com.ahmastan.zephydian/Data/Library/Application Support/Zephydian
///         → ~/Library/Application Support/Zephydian          (notes, installed packs, pack data)
///     ~/Library/Containers/com.ahmastan.zephydian/Data/Library/Preferences/com.ahmastan.zephydian.plist
///         → the app's normal preferences                       (settings, scores, saved games)
///
/// The container is copied, never changed, so it stays as a backup and older versions still find
/// their data. Settings are imported once; files are retried on the next launch if a copy fails.
enum StorageMove {
    enum Outcome: Equatable {
        /// Already done, or nothing to bring over (a fresh install, or a sandboxed build).
        case nothing
        case moved
        /// The files couldn't be copied. The container is untouched; the next launch tries again.
        case failed(String)
    }

    struct Paths {
        /// The container's `Data` folder.
        var container: URL
        /// Where the app keeps its data now: Application Support.
        var applicationSupport: URL
        /// The preferences domain to import into (the bundle ID).
        var domain: String

        static var live: Paths {
            let home = getpwuid(getuid()).flatMap { String(validatingCString: $0.pointee.pw_dir) } ?? NSHomeDirectory()
            let id = Bundle.main.bundleIdentifier ?? "com.ahmastan.zephydian"
            return Paths(
                container: URL(filePath: home, directoryHint: .isDirectory)
                    .appending(path: "Library/Containers/\(id)/Data", directoryHint: .isDirectory),
                applicationSupport: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0],
                domain: id)
        }
    }

    static let preferencesKey = "storage.movedPreferences"
    static let filesKey = "storage.movedFiles"
    /// Where an older folder already at the new place is put aside before the copy lands.
    static let asideName = "Zephydian (before the move)"

    /// Runs at launch, before anything reads settings or files.
    @discardableResult
    static func runIfNeeded(paths: Paths = .live, defaults: UserDefaults = .standard,
                            fileManager fm: FileManager = .default) -> Outcome {
        // A sandboxed build (an old one, or a test) still sees its container directly.
        if ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil { return .nothing }
        if defaults.bool(forKey: preferencesKey), defaults.bool(forKey: filesKey) { return .nothing }

        var didSomething = false
        guard fm.fileExists(atPath: paths.container.path) else {
            defaults.set(true, forKey: preferencesKey)
            defaults.set(true, forKey: filesKey)
            return .nothing
        }

        if !defaults.bool(forKey: preferencesKey) {
            didSomething = importPreferences(paths: paths, defaults: defaults) || didSomething
            defaults.set(true, forKey: preferencesKey)
        }

        if !defaults.bool(forKey: filesKey) {
            do {
                didSomething = try copyFiles(paths: paths, fileManager: fm) || didSomething
                defaults.set(true, forKey: filesKey)
            } catch {
                return .failed(error.localizedDescription)
            }
        }
        return didSomething ? .moved : .nothing
    }

    /// The container's settings win over anything already in the new domain, which only a test run
    /// outside the sandbox could have written. Returns whether there was anything to import.
    private static func importPreferences(paths: Paths, defaults: UserDefaults) -> Bool {
        let file = paths.container.appending(path: "Library/Preferences/\(paths.domain).plist")
        guard let data = try? Data(contentsOf: file),
              let old = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
              !old.isEmpty else { return false }
        let current = defaults.persistentDomain(forName: paths.domain) ?? [:]
        defaults.setPersistentDomain(current.merging(old) { _, container in container }, forName: paths.domain)
        return true
    }

    /// Copies into a staging folder, checks every file arrived whole, then swaps it into place.
    /// Returns whether there was anything to copy.
    private static func copyFiles(paths: Paths, fileManager fm: FileManager) throws -> Bool {
        let source = paths.container.appending(path: "Library/Application Support/Zephydian", directoryHint: .isDirectory)
        guard fm.fileExists(atPath: source.path) else { return false }

        let destination = paths.applicationSupport.appending(path: "Zephydian", directoryHint: .isDirectory)
        let staging = paths.applicationSupport.appending(path: "Zephydian.moving", directoryHint: .isDirectory)
        try fm.createDirectory(at: paths.applicationSupport, withIntermediateDirectories: true)
        try? fm.removeItem(at: staging)
        do {
            try fm.copyItem(at: source, to: staging)
            guard try inventory(of: source, fm) == inventory(of: staging, fm) else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "The copy didn't match the original."])
            }
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }

        // Something already there (only from a test run outside the sandbox): keep it, out of the way.
        var aside: URL?
        if fm.fileExists(atPath: destination.path) {
            var target = paths.applicationSupport.appending(path: asideName, directoryHint: .isDirectory)
            var n = 2
            while fm.fileExists(atPath: target.path) {
                target = paths.applicationSupport.appending(path: "\(asideName) \(n)", directoryHint: .isDirectory)
                n += 1
            }
            try fm.moveItem(at: destination, to: target)
            aside = target
        }
        do {
            try fm.moveItem(at: staging, to: destination)
        } catch {
            if let aside { try? fm.moveItem(at: aside, to: destination) }
            try? fm.removeItem(at: staging)
            throw error
        }
        return true
    }

    /// Every file and folder under `root`, by relative path, with file sizes.
    private static func inventory(of root: URL, _ fm: FileManager) throws -> [String: Int] {
        var out: [String: Int] = [:]
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey]
        guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: keys) else {
            throw CocoaError(.fileReadUnknown)
        }
        let base = root.standardizedFileURL.path
        for case let url as URL in walker {
            let values = try url.resourceValues(forKeys: Set(keys))
            let path = String(url.standardizedFileURL.path.dropFirst(base.count))
            out[path] = values.isDirectory == true ? -1 : (values.fileSize ?? 0)
        }
        return out
    }

    /// Tells the person their data stayed in the old folder, and where.
    static func reportFailure(_ message: String, paths: Paths = .live) {
        let alert = NSAlert()
        alert.messageText = "Zephydian couldn't bring over your notes and packs"
        alert.informativeText = "They're safe in the old folder, and Zephydian will try again next time it opens. (\(message))"
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Show Old Folder")
        NSApp.activate()
        if alert.runModal() == .alertSecondButtonReturn {
            let folder = paths.container.appending(path: "Library/Application Support/Zephydian", directoryHint: .isDirectory)
            NSWorkspace.shared.activateFileViewerSelecting([folder])
        }
    }
}
