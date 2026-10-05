import AppKit
import ApplicationServices

/// One row in the Command Bar.
struct CommandResult: Identifiable {
    enum Kind: String {
        case answer, color, app, window, menu, file, clipboard, snippet, setting, zephydian, toggle, emoji, script

        /// The small label at the start of the row.
        var label: String {
            switch self {
            case .answer: "ANSWER"
            case .color: "COLOR"
            case .app: "APP"
            case .window: "WINDOW"
            case .menu: "MENU"
            case .file: "FILE"
            case .clipboard: "CLIPBOARD"
            case .snippet: "SNIPPET"
            case .setting: "SETTINGS"
            case .zephydian: "ZEPHYDIAN"
            case .toggle: "TOGGLE"
            case .emoji: "EMOJI"
            case .script: "SCRIPT"
            }
        }
    }

    enum Icon {
        case symbol(String)
        /// A file's or app's Finder icon, by path.
        case file(String)
        case app(pid_t)
        case color(NSColor)
        case glyph(String)
    }

    /// Stable across searches, so choices can be remembered (`CommandBarUsage`).
    let id: String
    let kind: Kind
    let title: String
    var subtitle: String?
    var icon: Icon
    var score: Double
    /// What ↵ does (the bar closes first).
    var run: () -> Void
    /// What ⌘↵ does, and its hint ("Show in Finder").
    var alt: (label: String, run: () -> Void)?
    /// Asks for a second ↵ first, with this line ("Press ↵ again to empty the Trash").
    var confirm: String?
}

/// Choices people made, to put them first next time.
enum CommandBarUsage {
    private static let key = "commandBar.usage"

    static func boost(_ id: String) -> Double {
        let count = counts[id] ?? 0
        return count == 0 ? 0 : min(18, log2(Double(count) + 1) * 6)
    }

    static func record(_ id: String) {
        var all = counts
        all[id, default: 0] += 1
        if all.count > 400 {   // forget the least used
            for (old, _) in all.sorted(by: { $0.value < $1.value }).prefix(100) { all[old] = nil }
        }
        UserDefaults.standard.set(all, forKey: key)
        cache = all
    }

    private static var cache: [String: Int]?
    private static var counts: [String: Int] {
        if let cache { return cache }
        let stored = UserDefaults.standard.dictionary(forKey: key) as? [String: Int] ?? [:]
        cache = stored
        return stored
    }
}

// MARK: - Sources read off the main thread

/// An installed app.
nonisolated struct AppEntry: Sendable {
    let name: String
    let path: String
    let bundleID: String?
}

/// A command in the front app's menus.
nonisolated struct MenuEntry: @unchecked Sendable {
    let path: [String]
    let title: String
    let shortcut: String?
    let element: AXUIElement
}

nonisolated enum CommandSources {
    /// Every app in the usual folders (and one folder deeper, like /Applications/Utilities).
    static func apps() -> [AppEntry] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let roots = ["/Applications", "/System/Applications", "/System/Applications/Utilities",
                     "/System/Library/CoreServices/Applications", "\(home)/Applications"]
        var seen = Set<String>(), out: [AppEntry] = []
        func add(_ path: String) {
            guard seen.insert(path).inserted else { return }
            let bundle = Bundle(path: path)
            out.append(AppEntry(name: FileManager.default.displayName(atPath: path), path: path, bundleID: bundle?.bundleIdentifier))
        }
        for root in roots {
            for name in (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? [] where !name.hasPrefix(".") {
                let path = "\(root)/\(name)"
                if name.hasSuffix(".app") { add(path); continue }
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { continue }
                for inner in (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? [] where inner.hasSuffix(".app") {
                    add("\(path)/\(inner)")
                }
            }
        }
        // Finder lives elsewhere.
        add("/System/Library/CoreServices/Finder.app")
        return out
    }

    /// Every titled window of the open apps, on every desktop.
    static func windows() -> [(window: SystemWindow, app: String)] {
        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && !$0.isTerminated }
        let server = SystemWindows.serverWindows()
        var out: [(SystemWindow, String)] = []
        for app in apps {
            let name = app.localizedName ?? "App"
            for window in SystemWindows.windows(of: app, allSpaces: true, server: server[app.processIdentifier] ?? [:])
            where !window.title.isEmpty {
                out.append((window, name))
            }
        }
        return out
    }

    /// The commands in an app's menu bar (not the Apple menu), up to three levels deep.
    static func menus(of pid: pid_t) -> [MenuEntry] {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.4)
        guard let bar = copy(app, kAXMenuBarAttribute) else { return [] }
        let top = (copy(bar as! AXUIElement, kAXChildrenAttribute) as? [AXUIElement]) ?? []
        var out: [MenuEntry] = []
        func walk(_ item: AXUIElement, path: [String], depth: Int) {
            guard out.count < 2500, depth < 4 else { return }
            for menu in (copy(item, kAXChildrenAttribute) as? [AXUIElement]) ?? [] {
                for child in (copy(menu, kAXChildrenAttribute) as? [AXUIElement]) ?? [] {
                    guard let title = copy(child, kAXTitleAttribute) as? String, !title.isEmpty else { continue }
                    let submenu = (copy(child, kAXChildrenAttribute) as? [AXUIElement])?.isEmpty == false
                    if submenu {
                        walk(child, path: path + [title], depth: depth + 1)
                    } else if (copy(child, kAXEnabledAttribute) as? Bool) != false {
                        out.append(MenuEntry(path: path, title: title, shortcut: shortcut(of: child), element: child))
                    }
                }
            }
        }
        for item in top.dropFirst() {
            guard let title = copy(item, kAXTitleAttribute) as? String, !title.isEmpty else { continue }
            walk(item, path: [title], depth: 1)
        }
        return out
    }

    /// "⇧⌘S" from the menu item's key and modifier mask (0 = ⌘, 1 adds ⇧, 2 adds ⌥, 4 adds ⌃, 8 removes ⌘).
    private static func shortcut(of item: AXUIElement) -> String? {
        guard let key = copy(item, kAXMenuItemCmdCharAttribute) as? String, !key.isEmpty, key != "\u{7f}" else { return nil }
        let mask = (copy(item, kAXMenuItemCmdModifiersAttribute) as? Int) ?? 0
        var s = ""
        if mask & 4 != 0 { s += "⌃" }
        if mask & 2 != 0 { s += "⌥" }
        if mask & 1 != 0 { s += "⇧" }
        if mask & 8 == 0 { s += "⌘" }
        return s + key.uppercased()
    }

    static func press(_ entry: MenuEntry) {
        Task.detached(priority: .userInitiated) { AXUIElementPerformAction(entry.element, kAXPressAction as CFString) }
    }

    private static func copy(_ element: AXUIElement, _ attribute: String) -> AnyObject? {
        var value: AnyObject?
        return AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success ? value : nil
    }

    /// Emoji with their Unicode names ("grinning face"), built once.
    static let emoji: [(glyph: String, name: String)] = {
        var out: [(String, String)] = []
        let ranges: [ClosedRange<UInt32>] = [0x1F300...0x1F5FF, 0x1F600...0x1F64F, 0x1F680...0x1F6FF, 0x1F900...0x1F9FF,
                                             0x1FA70...0x1FAFF, 0x2600...0x27BF]
        for range in ranges {
            for value in range {
                guard let scalar = Unicode.Scalar(value), scalar.properties.isEmojiPresentation,
                      let name = scalar.properties.name else { continue }
                out.append((String(scalar), name.lowercased()))
            }
        }
        return out
    }()
}

/// System Settings pages, opened through their `x-apple.systempreferences:` links.
enum SystemSettingsPanes {
    static let all: [(name: String, id: String, symbol: String, keywords: String)] = [
        ("Wi-Fi", "com.apple.wifi-settings-extension", "wifi", "wireless internet"),
        ("Bluetooth", "com.apple.BluetoothSettings", "dot.radiowaves.left.and.right", "headphones airpods"),
        ("Network", "com.apple.Network-Settings.extension", "network", "vpn ethernet proxy"),
        ("Notifications", "com.apple.Notifications-Settings.extension", "bell.badge", "alerts banners"),
        ("Sound", "com.apple.Sound-Settings.extension", "speaker.wave.2", "volume output input"),
        ("Focus", "com.apple.Focus-Settings.extension", "moon", "do not disturb"),
        ("Screen Time", "com.apple.Screen-Time-Settings.extension", "hourglass", "limits"),
        ("General", "com.apple.systempreferences.GeneralSettings", "gearshape", ""),
        ("About This Mac", "com.apple.SystemProfiler.AboutExtension", "info.circle", "serial version"),
        ("Software Update", "com.apple.Software-Update-Settings.extension", "arrow.down.circle", "upgrade"),
        ("Storage", "com.apple.settings.Storage", "internaldrive", "disk space"),
        ("Login Items", "com.apple.LoginItems-Settings.extension", "list.bullet", "startup extensions"),
        ("Language & Region", "com.apple.Localization-Settings.extension", "globe", "locale"),
        ("Date & Time", "com.apple.Date-Time-Settings.extension", "clock", "timezone"),
        ("Sharing", "com.apple.Sharing-Settings.extension", "square.and.arrow.up", "airdrop remote"),
        ("Time Machine", "com.apple.Time-Machine-Settings.extension", "clock.arrow.circlepath", "backup"),
        ("Appearance", "com.apple.Appearance-Settings.extension", "circle.lefthalf.filled", "dark light accent"),
        ("Accessibility", "com.apple.Accessibility-Settings.extension", "accessibility", "zoom voiceover"),
        ("Control Center", "com.apple.ControlCenter-Settings.extension", "switch.2", "menu bar"),
        ("Siri", "com.apple.Siri-Settings.extension", "mic", "apple intelligence"),
        ("Privacy & Security", "com.apple.settings.PrivacySecurity.extension", "hand.raised", "permissions accessibility screen recording"),
        ("Desktop & Dock", "com.apple.Desktop-Settings.extension", "dock.rectangle", "hot corners stage manager"),
        ("Displays", "com.apple.Displays-Settings.extension", "display", "resolution night shift"),
        ("Wallpaper", "com.apple.Wallpaper-Settings.extension", "photo", "background"),
        ("Screen Saver", "com.apple.ScreenSaver-Settings.extension", "sparkles.tv", ""),
        ("Battery", "com.apple.Battery-Settings.extension", "battery.100", "energy power"),
        ("Lock Screen", "com.apple.Lock-Screen-Settings.extension", "lock", "password sleep"),
        ("Touch ID & Password", "com.apple.Touch-ID-Settings.extension", "touchid", "fingerprint"),
        ("Users & Groups", "com.apple.Users-Groups-Settings.extension", "person.2", "accounts"),
        ("Passwords", "com.apple.Passwords-Settings.extension", "key", ""),
        ("Internet Accounts", "com.apple.Internet-Accounts-Settings.extension", "at", "mail"),
        ("Keyboard", "com.apple.Keyboard-Settings.extension", "keyboard", "shortcuts input sources"),
        ("Mouse", "com.apple.Mouse-Settings.extension", "computermouse", "scroll"),
        ("Trackpad", "com.apple.Trackpad-Settings.extension", "rectangle.and.hand.point.up.left", "gestures"),
        ("Printers & Scanners", "com.apple.Print-Scanner-Settings.extension", "printer", ""),
        ("Startup Disk", "com.apple.Startup-Disk-Settings.extension", "internaldrive", "boot"),
    ]

    static func open(_ id: String) {
        if let url = URL(string: "x-apple.systempreferences:\(id)") { NSWorkspace.shared.open(url) }
    }
}
