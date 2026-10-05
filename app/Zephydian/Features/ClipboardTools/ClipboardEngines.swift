import AppKit
import Carbon.HIToolbox

// MARK: - Paste as plain text

/// Paste as plain text: a shortcut (⌥⇧⌘V) pastes what you copied without its fonts, colors or
/// links. The clipboard holds the plain text only for the paste, then gets its original back.
final class PlainPasteEngine: FeatureEngine {
    private let settings = ClipboardToolsSettings.shared
    private let hotKey = GlobalHotKey(id: 700)
    private var running = false

    func start() {
        running = true
        hotKey.onPress = { Self.pastePlain() }
        follow()
    }

    func stop() {
        running = false
        hotKey.unregister()
    }

    private func follow() {
        guard running else { return }
        withObservationTracking { _ = settings.plainPasteShortcut } onChange: { [weak self] in
            Task { @MainActor in self?.follow() }
        }
        ClipboardToolsStatus.shared.plainPasteRegistered = hotKey.register(settings.plainPasteShortcut)
    }

    static func pastePlain() {
        let board = NSPasteboard.general
        guard let text = board.string(forType: .string) else { NSSound.beep(); return }
        let saved = board.pasteboardItems?.map { item -> NSPasteboardItem in
            let copy = NSPasteboardItem()
            for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }
            return copy
        } ?? []
        board.clearContents()
        board.setString(text, forType: .string)
        board.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        PasteboardWatcher.shared.markOwnChange()
        EventTap.pressKey(CGKeyCode(kVK_ANSI_V), flags: .maskCommand)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            board.clearContents()
            board.writeObjects(saved)
            PasteboardWatcher.shared.markOwnChange()
        }
    }
}

/// Whether the features' shortcuts could be registered (for their warnings).
@Observable
final class ClipboardToolsStatus {
    static let shared = ClipboardToolsStatus()
    var plainPasteRegistered = true
    var shelfRegistered = true
}

// MARK: - Auto-clear

/// Auto-clear: empties the system clipboard a while after your last copy, when the Mac sleeps and
/// when the screen locks, so a copied password or address doesn't linger. Clipboard's own history
/// is kept.
final class AutoClearEngine: FeatureEngine {
    private let settings = ClipboardToolsSettings.shared
    private var lastCopy = Date()
    private var expiry: Timer?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    func start() {
        PasteboardWatcher.shared.listen(self) { [weak self] _ in self?.copied() }
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append((workspace, workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if self?.settings.clearOnSleep == true { self?.clear() } }
        }))
        let distributed = DistributedNotificationCenter.default()
        observers.append((distributed, distributed.addObserver(forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if self?.settings.clearOnLock == true { self?.clear() } }
        }))
    }

    func stop() {
        PasteboardWatcher.shared.stopListening(self)
        expiry?.invalidate()
        expiry = nil
        for (center, token) in observers { center.removeObserver(token) }
        observers = []
    }

    private func copied() {
        lastCopy = Date()
        expiry?.invalidate()
        guard settings.clearAfter > 0 else { return }
        // One timer per copy, not a running clock.
        let timer = Timer(timeInterval: TimeInterval(settings.clearAfter), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.clear() }
        }
        RunLoop.main.add(timer, forMode: .common)
        expiry = timer
    }

    private func clear() {
        expiry?.invalidate()
        expiry = nil
        guard NSPasteboard.general.types?.isEmpty == false else { return }
        NSPasteboard.general.clearContents()
        PasteboardWatcher.shared.markOwnChange()
    }
}

// MARK: - Clean URLs

/// Clean URLs: a link you copy loses its tracking (utm_source, fbclid, gclid and the like) right
/// away, so what you paste is clean. Only known tracking parameters go; everything a page needs stays.
final class CleanURLEngine: FeatureEngine {
    private let settings = ClipboardToolsSettings.shared

    func start() {
        PasteboardWatcher.shared.listen(self) { [weak self] _ in self?.copied() }
    }

    func stop() {
        PasteboardWatcher.shared.stopListening(self)
    }

    private func copied() {
        if let app = NSWorkspace.shared.frontmostApplication?.bundleIdentifier, settings.cleanIgnoredApps.contains(app) { return }
        let board = NSPasteboard.general
        guard let text = board.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.contains(where: \.isWhitespace), let cleaned = URLCleaner.clean(text), cleaned != text else { return }
        board.clearContents()
        board.setString(cleaned, forType: .string)
        board.setString(cleaned, forType: .URL)
        PasteboardWatcher.shared.markOwnChange()
    }
}

/// Removes tracking parameters from web links.
enum URLCleaner {
    /// Parameters that only track where a click came from.
    static let tracking: Set<String> = [
        "fbclid", "gclid", "gclsrc", "dclid", "gbraid", "wbraid", "msclkid", "yclid", "twclid", "ttclid", "li_fat_id",
        "igshid", "igsh", "mc_cid", "mc_eid", "_hsenc", "_hsmi", "__hssc", "__hstc", "__hsfp", "hsctatracking",
        "mkt_tok", "vero_id", "vero_conv", "oly_anon_id", "oly_enc_id", "rb_clickid", "s_cid", "wickedid",
        "ref_src", "ref_url", "_ga", "_gl", "srsltid", "ncid", "cmpid",
    ]
    /// Parameter name beginnings that are tracking too (utm_source, utm_medium…).
    static let trackingPrefixes = ["utm_", "pk_", "mtm_", "hsa_", "oly_"]
    /// Parameters that are tracking only on certain sites (YouTube's and Spotify's share id is "si";
    /// "feature" is YouTube's). Elsewhere they're kept, since a page may need them.
    static let siteSpecific: [String: Set<String>] = [
        "si": ["youtube.com", "youtu.be", "spotify.com"],
        "feature": ["youtube.com", "youtu.be"],
        "spm": ["aliexpress.com", "taobao.com"],
        "scm": ["aliexpress.com", "taobao.com"],
    ]

    /// The cleaned link, or nil if `text` isn't a web link.
    static func clean(_ text: String) -> String? {
        guard var components = URLComponents(string: text), let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https", let host = components.host?.lowercased() else { return nil }
        guard let items = components.queryItems, !items.isEmpty else { return text }
        let kept = items.filter { item in
            let name = item.name.lowercased()
            if let sites = siteSpecific[name] {
                return !sites.contains { host == $0 || host.hasSuffix("." + $0) }
            }
            return !tracking.contains(name) && !trackingPrefixes.contains { name.hasPrefix($0) }
        }
        guard kept.count != items.count else { return text }
        components.queryItems = kept.isEmpty ? nil : kept
        return components.string ?? text
    }
}
