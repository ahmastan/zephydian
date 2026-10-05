import AppKit
import CoreGraphics
import Foundation
import JavaScriptCore

// MARK: - What a pack shows

/// A color from a pack: a theme name (follows light/dark and the accent) or a fixed sRGB color.
nonisolated enum PackColor: Equatable {
    case theme(String)            // accent, text, secondary, fill, background
    case rgba(Double, Double, Double, Double)

    static let themeNames: Set<String> = ["accent", "text", "secondary", "fill", "background"]

    /// "accent", "#rgb", "#rrggbb", "#rrggbbaa", "rgb(…)" or "rgba(…)". nil if it isn't one of these.
    init?(_ string: String) {
        let s = string.trimmingCharacters(in: .whitespaces).lowercased()
        if Self.themeNames.contains(s) { self = .theme(s); return }
        if s.hasPrefix("#") {
            var hex = String(s.dropFirst())
            if hex.count == 3 { hex = hex.map { "\($0)\($0)" }.joined() }
            guard hex.count == 6 || hex.count == 8, let v = UInt64(hex, radix: 16) else { return nil }
            let n = hex.count == 6 ? v << 8 | 0xFF : v
            self = .rgba(Double(n >> 24 & 0xFF) / 255, Double(n >> 16 & 0xFF) / 255, Double(n >> 8 & 0xFF) / 255, Double(n & 0xFF) / 255)
            return
        }
        for prefix in ["rgba(", "rgb("] where s.hasPrefix(prefix) && s.hasSuffix(")") {
            let parts = s.dropFirst(prefix.count).dropLast().split(separator: ",").map { Double($0.trimmingCharacters(in: .whitespaces)) }
            guard parts.count == 3 || parts.count == 4, parts.allSatisfy({ $0 != nil }) else { return nil }
            let p = parts.map { $0! }
            self = .rgba(min(max(p[0] / 255, 0), 1), min(max(p[1] / 255, 0), 1), min(max(p[2] / 255, 0), 1),
                         p.count == 4 ? min(max(p[3], 0), 1) : 1)
            return
        }
        return nil
    }
}

/// One entry of a pack's drawing list (`draw(g)`), already checked.
nonisolated enum PackShape: Equatable {
    struct Style: Equatable {
        var fill: PackColor?
        var stroke: PackColor?
        var lineWidth: Double = 1
        /// Round caps and joins on the stroke (freehand lines, arrows).
        var round = false
    }
    enum Weight: String { case regular, medium, semibold, bold }
    enum Align: String { case left, center, right }
    enum Font: String { case system, rounded, mono }

    case clear(PackColor)
    case rect(CGRect, radius: Double, Style)
    case circle(CGPoint, radius: Double, Style)
    case line(CGPoint, CGPoint, color: PackColor, width: Double, round: Bool)
    case ellipse(CGRect, Style)
    case path([CGPoint], closed: Bool, Style)
    case text(String, CGPoint, size: Double, weight: Weight, color: PackColor, align: Align, font: Font)
    /// `pixelate` > 0 draws the image in blocks that many image pixels wide (to hide what's there).
    case image(String, CGRect, opacity: Double, pixelate: Double)
    /// Limits what follows (until `restore`) to a rectangle.
    case clip(CGRect, radius: Double)
    /// A soft shadow under what follows (until `restore`).
    case shadow(PackColor, radius: Double, dx: Double, dy: Double)
    /// An SF Symbol, centered on the point, `size` tall.
    case symbol(String, CGPoint, size: Double, color: PackColor)
    /// A rectangle filled with a gradient from its top-left to its bottom-right.
    case gradient(CGRect, radius: Double, [PackColor])
    case save, restore
    case translate(Double, Double), rotate(Double), scale(Double), alpha(Double)
}

nonisolated struct PackOverlay: Equatable {
    struct Button: Equatable { var label: String; var prominent: Bool }
    var title: String
    var subtitle: String?
    var buttons: [Button]
}

nonisolated struct PackMenu: Equatable {
    var title: String
    var items: [String]
    var selected: Int
}

/// A key press or release, in the form packs see it (`e.key` is like the web's KeyboardEvent.key).
nonisolated struct PackKey {
    var key: String
    var shift = false
    var option = false
    var isRepeat = false
    /// ⌘ was held. Only a pack's own window gets ⌘ keys (⌘C, ⌘S…); the panel keeps them.
    var command = false
}

/// What the runtime tells the game screen.
protocol PackHost: AnyObject {
    func packDidDraw(_ shapes: [PackShape])
    /// A utility's controls changed (SDK 2).
    func packViewChanged(_ node: PackUINode)
    func packScoreChanged(_ text: String)
    func packHintChanged(_ text: String)
    func packOverlayChanged(_ overlay: PackOverlay?)
    func packMenuChanged(_ menu: PackMenu?)
    func packToast(_ text: String)
    func packFailed(_ message: String)
}

/// What a pack's own window does for the runtime (the `windows` capability, SDK 3).
protocol PackWindowHost: AnyObject {
    func packWindowTitle(_ title: String)
    func packWindowEdited(_ edited: Bool)
    func packWindowClose()
    /// A standard alert on the window. `done` gets true for the confirm button.
    func packWindowConfirm(title: String, message: String?, button: String, destructive: Bool, done: @escaping (Bool) -> Void)
    /// An alert with several buttons and Cancel. `done` gets the button's index, or -1 for Cancel.
    func packWindowChoose(title: String, message: String?, buttons: [(label: String, destructive: Bool)], done: @escaping (Int) -> Void)
    /// "dark" keeps the window dark whatever the app's appearance; "auto" follows it.
    func packWindowAppearance(_ mode: String)
}

// MARK: - Runtime

/// Runs one pack's main.js in its own JavaScriptCore context and exposes the SDK (`z`, `zephydian`).
/// Packs get nothing beyond what's defined here: JavaScriptCore has no network, files or timers.
/// All calls happen on the main thread.
final class PackRuntime {
    nonisolated static let maxShapes = 20_000
    /// Longest a single call into the pack may run before it's stopped (an endless loop, say).
    static let callTimeLimit: Double = 1.0

    let bundle: PackBundle
    weak var host: PackHost?
    weak var windowHost: PackWindowHost?

    /// Where the pack runs: the panel, or its own window (SDK 3), which starts with `input`.
    enum Mode: Equatable {
        case panel
        case window(input: String)
        /// The utility's page in the Settings window (SDK 5): its `settings: { view() }` object.
        case settings
    }
    let mode: Mode

    private let context: JSContext
    private var sdk: JSValue!            // the prelude's private entry points
    private let storage: PackStorage
    private let defaults: UserDefaults
    private let services: PackServices
    /// The capabilities the manifest declared. Nothing else is allowed.
    private let capabilities: Set<String>
    private var isUtility: Bool { bundle.kind == .utility }
    private(set) var failure: String?
    private(set) var isStarted = false
    private(set) var isPaused = false

    // Loop and timers
    private var loopInterval: Int?       // ms the pack asked for; nil = loop off
    /// The utility's shortcut was pressed before it had started: tell it right after `start`.
    private var pendingShortcut = false
    private var ticker: Task<Void, Never>?
    private var timers: [Int: Task<Void, Never>] = [:]
    private var nextTimer = 1
    private var drawScheduled = false
    private var size = CGSize.zero

    var isLooping: Bool { ticker != nil }
    var bestScoreKey: String { "pack.\(bundle.id).best" }
    var bestTimeKey: String { "pack.\(bundle.id).bestTime" }
    /// The line under a utility's tile (`z.tile`).
    static func tileKey(_ id: String) -> String { "pack.\(id).tile" }

    /// Runs main.js right away. `host` is set first, so calls made while the script loads aren't lost.
    init(bundle: PackBundle, host: PackHost?, mode: Mode = .panel, storage: PackStorage? = nil, defaults: UserDefaults = .standard,
         services: PackServices = .shared) {
        self.bundle = bundle
        self.host = host
        self.mode = mode
        self.storage = storage ?? PackStorage.shared(packID: bundle.id)
        self.defaults = defaults
        self.services = services
        capabilities = Set(bundle.manifest.capabilities ?? [])
        context = JSContext()!
        context.name = "Zephydian pack: \(bundle.id)"
        Self.limitExecutionTime(of: context)
        context.exceptionHandler = { [weak self] _, exception in
            let message = Self.describe(exception)
            MainActor.assumeIsolated { self?.fail(message) }
        }
        installSDK()
        guard failure == nil else { return }
        context.evaluateScript(bundle.script, withSourceURL: URL(string: "main.js"))
        if failure == nil, sdk.invokeMethod("hasApp", withArguments: []).toBool() == false {
            fail(mode == .settings ? "main.js has no settings: { view() } in zephydian.utility({ … })"
                 : mode != .panel ? "main.js has no window: { view() } in zephydian.utility({ … })"
                 : isUtility ? "main.js never called zephydian.utility({ … })" : "main.js never called zephydian.game({ … })")
        }
        // Another runtime of this pack (its panel screen, window or settings page) saved something.
        self.storage.observe(by: self) { [weak self] in self?.storageChangedElsewhere() }
    }

    /// Tells the pack (SDK 5 `storageChanged()`), which reloads what it keeps in memory and is drawn again.
    private func storageChangedElsewhere() {
        guard isStarted, failure == nil else { return }
        call("storageChanged")
    }

    deinit {
        ticker?.cancel()
        timers.values.forEach { $0.cancel() }
    }

    // MARK: Calls from the game screen

    /// Sets the game area's size. The first time, the pack's `start()` runs.
    func setSize(_ newSize: CGSize) {
        guard newSize != size, newSize.width > 0, newSize.height > 0 else { return }
        size = newSize
        let z = context.objectForKeyedSubscript("z")!
        z.setObject(Double(size.width), forKeyedSubscript: "width" as NSString)
        z.setObject(Double(size.height), forKeyedSubscript: "height" as NSString)
        if !isStarted {
            isStarted = true
            call("start")
            if pendingShortcut {
                pendingShortcut = false
                call("shortcut")
            }
        }
        requestDraw()
    }

    /// `z.theme`: `dark` plus a color string for each theme name.
    func setTheme(dark: Bool, colors: [String: String]) {
        var theme: [String: Any] = colors
        theme["dark"] = dark
        sdk.invokeMethod("setTheme", withArguments: [theme])
        if isStarted { requestDraw() }
    }

    func key(_ e: PackKey) -> Bool { call("key", Self.keyObject(e))?.toBool() ?? false }
    func keyUp(_ e: PackKey) -> Bool { call("keyUp", Self.keyObject(e))?.toBool() ?? false }
    func click(x: Double, y: Double, right: Bool) { call("click", ["x": x, "y": y, "button": right ? "right" : "left"]) }
    func undo() -> Bool { call("undo")?.toBool() ?? false }
    func redo() -> Bool { call("redo")?.toBool() ?? false }
    /// A window's close button or ⌘W. False keeps it open (the pack may ask first, then close it).
    func shouldClose() -> Bool { call("shouldClose")?.toBool() ?? true }
    /// The utility was opened with its own shortcut (SDK 4): its `shortcut()` runs.
    func shortcut() {
        if isStarted { call("shortcut") } else { pendingShortcut = true }
    }
    func pressOverlayButton(_ index: Int) { call("overlayPress", index) }
    func selectMenuItem(_ index: Int) { call("menuSelect", index) }

    /// A utility control was used. `event` is the handler's name on the control (onPress, onChange…).
    func uiEvent(_ id: String, _ event: String, _ value: Any) { call("event", id, event, value) }

    /// Draws (or, for a utility, asks for its view) again soon.
    func refresh() { requestDraw() }

    /// Hands the result of something that finished later (a save dialog, the color sampler) to the
    /// function the pack passed in. Dropped if the pack has stopped.
    private func respond(_ callback: Int, _ value: Any) {
        guard callback > 0 else { return }
        call("callback", callback, value)
    }

    /// Stops the loop and pending `z.after` calls, then tells the pack.
    func pause() {
        guard !isPaused, failure == nil else { return }
        isPaused = true
        stopTicker()
        cancelTimers()
        call("pause")
    }

    /// Tells the pack, then restarts its loop if it was running.
    func resume() {
        guard isPaused, failure == nil else { return }
        isPaused = false
        call("resume")
        if loopInterval != nil { startTicker() }
    }

    // MARK: Calling into the pack

    /// Calls one of the prelude's entry points. Returns nil if the pack has failed (now or before).
    @discardableResult
    private func call(_ name: String, _ args: Any...) -> JSValue? {
        guard failure == nil else { return nil }
        let result = sdk.invokeMethod(name, withArguments: args)
        // A utility's view follows its state: after anything that could change it, ask again.
        if isUtility && name != "view" { requestDraw() }
        return failure == nil ? result : nil
    }

    private func requestDraw() {
        guard !drawScheduled, failure == nil, isStarted else { return }
        drawScheduled = true
        Task { @MainActor [weak self] in self?.draw() }
    }

    private func draw() {
        drawScheduled = false
        if isUtility {
            guard let json = call("view"), json.isString else { return }
            do {
                host?.packViewChanged(try PackUINode.parse(json: json.toString()))
            } catch {
                fail("view: \(error)")
            }
            return
        }
        guard let list = call("draw") else { return }
        do {
            host?.packDidDraw(try Self.parseShapes(list))
        } catch {
            fail("draw: \(error)")
        }
    }

    private func fail(_ message: String) {
        guard failure == nil else { return }
        failure = message
        stopTicker()
        cancelTimers()
        #if DEBUG
        print("Pack \(bundle.id) stopped: \(message)")
        #endif
        host?.packFailed(message)
    }

    // MARK: Loop and timers

    private func startTicker() {
        stopTicker()
        guard let ms = loopInterval, !isPaused, failure == nil else { return }
        ticker = Task { @MainActor [weak self] in
            let clock = ContinuousClock()
            var last = clock.now
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(ms))
                guard !Task.isCancelled, let self else { return }
                let now = clock.now
                let dt = Double((now - last).components.attoseconds) / 1e15 + Double((now - last).components.seconds) * 1000
                last = now
                self.call("tick", dt)
            }
        }
    }

    private func stopTicker() {
        ticker?.cancel()
        ticker = nil
    }

    private func cancelTimers() {
        timers.values.forEach { $0.cancel() }
        timers = [:]
        sdk?.invokeMethod("clearTimers", withArguments: [])
    }

    // MARK: The SDK

    private func installSDK() {
        let native = JSValue(newObjectIn: context)!
        func define(_ name: String, _ block: Any) { native.setObject(block, forKeyedSubscript: name as NSString) }

        define("redraw", { [weak self] in MainActor.assumeIsolated { self?.requestDraw() } } as @convention(block) () -> Void)
        define("loopStart", { [weak self] (ms: Double) in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.loopInterval = Int(max(8, ms.isFinite ? ms : 8))
                self.startTicker()
            }
        } as @convention(block) (Double) -> Void)
        define("loopStop", { [weak self] in
            MainActor.assumeIsolated { self?.loopInterval = nil; self?.stopTicker() }
        } as @convention(block) () -> Void)
        define("after", { [weak self] (ms: Double) -> Int in
            MainActor.assumeIsolated {
                guard let self, !self.isPaused, self.failure == nil else { return 0 }
                let id = self.nextTimer
                self.nextTimer += 1
                let delay = Int(max(0, ms.isFinite ? ms : 0))
                self.timers[id] = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .milliseconds(delay))
                    guard !Task.isCancelled, let self else { return }
                    self.timers[id] = nil
                    self.call("fire", id)
                }
                return id
            }
        } as @convention(block) (Double) -> Int)
        define("cancel", { [weak self] (id: Int) in
            MainActor.assumeIsolated { self?.timers.removeValue(forKey: id)?.cancel() }
        } as @convention(block) (Int) -> Void)
        define("score", { [weak self] (s: String) in MainActor.assumeIsolated { self?.host?.packScoreChanged(s) } } as @convention(block) (String) -> Void)
        define("hint", { [weak self] (s: String) in MainActor.assumeIsolated { self?.host?.packHintChanged(s) } } as @convention(block) (String) -> Void)
        define("toast", { [weak self] (s: String) in MainActor.assumeIsolated { self?.host?.packToast(s) } } as @convention(block) (String) -> Void)
        define("overlay", { [weak self] (json: JSValue) in
            MainActor.assumeIsolated { self?.host?.packOverlayChanged(Self.decodeOverlay(json)) }
        } as @convention(block) (JSValue) -> Void)
        define("menu", { [weak self] (json: JSValue) in
            MainActor.assumeIsolated { self?.host?.packMenuChanged(Self.decodeMenu(json)) }
        } as @convention(block) (JSValue) -> Void)

        define("bestScore", { [weak self] () -> Int in
            MainActor.assumeIsolated { self.map { $0.defaults.integer(forKey: $0.bestScoreKey) } ?? 0 }
        } as @convention(block) () -> Int)
        define("submitScore", { [weak self] (n: Double) -> Bool in
            MainActor.assumeIsolated {
                guard let self, n.isFinite else { return false }
                let value = Int(n)
                guard value > self.defaults.integer(forKey: self.bestScoreKey) else { return false }
                self.defaults.set(value, forKey: self.bestScoreKey)
                return true
            }
        } as @convention(block) (Double) -> Bool)
        define("bestTime", { [weak self] () -> Int in
            MainActor.assumeIsolated { self.map { $0.defaults.integer(forKey: $0.bestTimeKey) } ?? 0 }
        } as @convention(block) () -> Int)
        define("submitTime", { [weak self] (s: Double) -> Bool in
            MainActor.assumeIsolated {
                guard let self, s.isFinite, s > 0 else { return false }
                let value = Int(s.rounded()), best = self.defaults.integer(forKey: self.bestTimeKey)
                guard best == 0 || value < best else { return false }
                self.defaults.set(value, forKey: self.bestTimeKey)
                return true
            }
        } as @convention(block) (Double) -> Bool)

        define("storageGet", { [weak self] (key: String) -> Any in
            let value: String? = MainActor.assumeIsolated { self?.storage.get(key) }
            return value ?? NSNull()
        } as @convention(block) (String) -> Any)
        define("storageSet", { [weak self] (key: String, json: String) -> Bool in
            MainActor.assumeIsolated { guard let self else { return false }; return self.storage.set(key, json: json, by: self) }
        } as @convention(block) (String, String) -> Bool)
        define("storageRemove", { [weak self] (key: String) in MainActor.assumeIsolated { guard let self else { return }; self.storage.remove(key, by: self) } } as @convention(block) (String) -> Void)
        define("storageClear", { [weak self] in MainActor.assumeIsolated { guard let self else { return }; self.storage.clear(by: self) } } as @convention(block) () -> Void)
        define("data", { [weak self] (name: String) -> Any in
            let text: String? = MainActor.assumeIsolated {
                self?.bundle.assetURL(name).flatMap { try? String(contentsOf: $0, encoding: .utf8) }
            }
            return text ?? NSNull()
        } as @convention(block) (String) -> Any)
        define("tile", { [weak self] (s: String) in
            MainActor.assumeIsolated {
                guard let self else { return }
                let key = Self.tileKey(self.bundle.id)
                if s.isEmpty { self.defaults.removeObject(forKey: key) } else { self.defaults.set(String(s.prefix(40)), forKey: key) }
            }
        } as @convention(block) (String) -> Void)
        define("randomInt", { (max: Double) -> Double in
            // SystemRandomNumberGenerator is the system's cryptographically secure source.
            guard max.isFinite, max >= 1 else { return 0 }
            return Double(UInt64.random(in: 0..<UInt64(min(max, 9_007_199_254_740_991))))
        } as @convention(block) (Double) -> Double)
        define("clipboardWrite", { [weak self] (s: String, concealed: Bool) in
            MainActor.assumeIsolated {
                guard let self, self.capabilities.contains("clipboard.write") else { return }
                PackClipboard.write(s, concealed: concealed)
            }
        } as @convention(block) (String, Bool) -> Void)
        define("awakeStart", { [weak self] (minutes: Double, display: Bool) -> Bool in
            MainActor.assumeIsolated {
                guard let self, self.capabilities.contains("power.awake") else { return false }
                return self.services.startAwake(packID: self.bundle.id, packName: self.bundle.manifest.name,
                                                minutes: minutes > 0 && minutes.isFinite ? minutes : nil, display: display)
            }
        } as @convention(block) (Double, Bool) -> Bool)
        define("awakeStop", { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.capabilities.contains("power.awake") else { return }
                self.services.stopAwake(packID: self.bundle.id)
            }
        } as @convention(block) () -> Void)
        define("awakeStatus", { [weak self] () -> String in
            MainActor.assumeIsolated {
                guard let self, self.capabilities.contains("power.awake") else { return "{\"on\":false,\"until\":null}" }
                let status = self.services.awakeStatus(packID: self.bundle.id)
                let until = status.until.map { String(Int($0.timeIntervalSince1970 * 1000)) } ?? "null"
                return "{\"on\":\(status.on),\"until\":\(until)}"
            }
        } as @convention(block) () -> String)
        // App management (SDK 9): the Uninstaller, Cleaner, Chat Files, Ports, App Updates and Homebrew utilities.
        define("tools", { [weak self] (action: String, arg: String, callback: Int) -> String in
            MainActor.assumeIsolated {
                guard let self else { return "null" }
                let files = self.services.files, tools = self.services.tools, id = self.bundle.id
                let o = Self.jsonObject(arg) ?? [:]
                let reply: (Any) -> Void = { [weak self] result in self?.respond(callback, result) }
                let ids = (o["ids"] as? [String]) ?? []
                let capabilities = self.capabilities
                func need(_ capability: String) -> Bool { capabilities.contains(capability) }
                switch action {
                case "apps": if need("apps.uninstall") { files.apps(packID: id) { reply($0) } }
                case "chooseApp": if need("apps.uninstall") { files.chooseApp(done: reply) }
                case "leftovers": if need("apps.uninstall") { files.leftovers(appID: o["app"] as? String ?? "", packID: id, done: reply) }
                case "uninstall": if need("apps.uninstall") { files.uninstall(appID: o["app"] as? String ?? "", ids: ids, packID: id, done: reply) }
                case "scanClean": if need("files.clean") { files.scanClean(packID: id, done: reply) }
                case "scanChats": if need("files.clean") { files.scanChats(days: (o["days"] as? NSNumber)?.intValue ?? 90, packID: id, done: reply) }
                case "trash": if need("files.clean") || need("apps.uninstall") { files.trash(ids: ids, packID: id, done: reply) }
                case "fullDiskAccess": if need("files.clean") { files.openFullDiskAccess() }
                case "reminder":
                    guard need("files.clean") else { break }
                    if let value = o["set"] as? String { self.services.cleanReminder.set(value, packID: id) }
                    return Self.jsonString(self.services.cleanReminder.schedule(id))
                case "busy": return (files.busy.contains(id)) ? "true" : "false"
                case "ports": if need("ports") { tools.ports(done: reply) }
                case "stopPort":
                    guard need("ports") else { break }
                    return tools.stop(pid: (o["pid"] as? NSNumber)?.intValue ?? 0, force: o["force"] as? Bool ?? false) ? "true" : "false"
                case "brewStatus": if need("homebrew") || need("updates.check") { return Self.jsonString(tools.brewStatus(packID: id)) }
                case "brewRead": if need("homebrew") { tools.brewRead(o["what"] as? String ?? "", o["query"] as? String ?? "", done: reply) }
                case "brewJob":
                    if need("homebrew") { tools.brewJob(o["what"] as? String ?? "", name: o["name"] as? String, cask: o["cask"] as? Bool ?? false, packID: id, done: reply) }
                case "cancelJob": if need("homebrew") || need("updates.check") { tools.cancelJob(packID: id) }
                case "checkUpdates": if need("updates.check") { tools.checkUpdates(packID: id, done: reply) }
                case "update": if need("updates.check") { tools.update(o["id"] as? String ?? "", packID: id, done: reply) }
                default: break
                }
                return "null"
            }
        } as @convention(block) (String, String, Int) -> String)
        // Keep-awake rules (SDK 8): apps, power, an external display.
        define("awakeRules", { [weak self] (action: String, arg: String, callback: Int) -> String in
            MainActor.assumeIsolated {
                guard let self, self.capabilities.contains("power.awake") else { return "null" }
                let rules = self.services.awakeRules
                let packID = self.bundle.id
                switch action {
                case "get":
                    let r = rules.rules(for: packID)
                    return Self.jsonString([
                        "apps": r.apps.map { ["id": $0, "name": AppNames.name($0)] },
                        "onPower": r.onPower, "externalDisplay": r.externalDisplay, "display": r.display,
                        "active": rules.activeReason(for: packID) as Any,
                    ] as [String: Any])
                case "set":
                    guard let o = Self.jsonObject(arg) else { return "null" }
                    var r = rules.rules(for: packID)
                    if let apps = o["apps"] as? [String] { r.apps = Array(apps.prefix(50)) }
                    if let v = o["onPower"] as? Bool { r.onPower = v }
                    if let v = o["externalDisplay"] as? Bool { r.externalDisplay = v }
                    if let v = o["display"] as? Bool { r.display = v }
                    rules.set(r, for: packID, packName: self.bundle.manifest.name)
                case "pickApp":
                    let panel = NSOpenPanel()
                    panel.allowedContentTypes = [.application]
                    panel.directoryURL = URL(filePath: "/Applications")
                    panel.level = .statusBar + 1
                    self.services.holdPanel()
                    NSApp.activate()
                    panel.begin { [weak self] response in
                        MainActor.assumeIsolated {
                            self?.services.releasePanel()
                            guard response == .OK, let url = panel.url, let id = Bundle(url: url)?.bundleIdentifier else {
                                self?.respond(callback, NSNull()); return
                            }
                            self?.respond(callback, ["id": id, "name": AppNames.name(id)])
                        }
                    }
                default: break
                }
                return "null"
            }
        } as @convention(block) (String, String, Int) -> String)
        define("base64Encode", { (s: String) -> String in PackNative.base64Encode(s) } as @convention(block) (String) -> String)
        define("base64Decode", { (s: String) -> Any in PackNative.base64Decode(s) ?? NSNull() } as @convention(block) (String) -> Any)
        define("sha256", { (s: String) -> String in PackNative.sha256(s) } as @convention(block) (String) -> String)
        define("uuid", { () -> String in UUID().uuidString } as @convention(block) () -> String)
        define("qr", { (text: String, level: String) -> Any in
            let rows: [String]? = MainActor.assumeIsolated { PackNative.qr(text, level: level) }
            return rows ?? NSNull()
        } as @convention(block) (String, String) -> Any)
        define("clipboardWriteImage", { [weak self] (json: String) -> Bool in
            MainActor.assumeIsolated {
                guard let self, self.capabilities.contains("clipboard.write"),
                      let png = PackNative.png(fromDrawingJSON: json) else { return false }
                PackNative.copyImage(png)
                return true
            }
        } as @convention(block) (String) -> Bool)
        define("filesSave", { [weak self] (name: String, text: JSValue, image: JSValue, callback: Int) in
            MainActor.assumeIsolated {
                guard let self, self.capabilities.contains("files.save") else { return }
                let data: Data? = image.isString ? PackNative.png(fromDrawingJSON: image.toString())
                    : text.isString ? Data(text.toString().utf8) : nil
                guard let data, data.count <= 50 * 1024 * 1024 else { return self.respond(callback, false) }
                PackNative.save(name: name, data: data) { [weak self] saved in self?.respond(callback, saved) }
            }
        } as @convention(block) (String, JSValue, JSValue, Int) -> Void)
        define("colorSample", { [weak self] (callback: Int) in
            MainActor.assumeIsolated {
                guard let self, self.capabilities.contains("color.sample") else { return }
                PackNative.sampleColor { [weak self] color in
                    self?.respond(callback, color.map(PackNative.colorObject) ?? NSNull())
                }
            }
        } as @convention(block) (Int) -> Void)
        // Wave 2: timers, clipboard history, a shortcut and system readings. Each needs its capability.
        let id = bundle.id, name = bundle.manifest.name
        func allowed(_ capability: String) -> Bool { capabilities.contains(capability) }
        define("timersStart", { [weak self] (json: String) -> String in
            MainActor.assumeIsolated {
                guard let self, allowed("timers"), let o = Self.jsonObject(json) else { return "" }
                let seconds = min(max((o["seconds"] as? NSNumber)?.doubleValue ?? 0, 1), 7 * 86_400)
                let chain = (o["chain"] as? [[String: Any]] ?? []).map {
                    PackTimers.Phase(label: String(($0["label"] as? String ?? "").prefix(60)),
                                     seconds: min(max(($0["seconds"] as? NSNumber)?.doubleValue ?? 0, 1), 7 * 86_400))
                }
                return self.services.timers.start(packID: id, packName: name, label: o["label"] as? String ?? "", seconds: seconds,
                                                  sound: o["sound"] as? String, notify: allowed("notifications"), chain: chain)
            }
        } as @convention(block) (String) -> String)
        define("timersList", { [weak self] () -> String in
            MainActor.assumeIsolated {
                guard let self, allowed("timers") else { return "[]" }
                return Self.jsonString(self.services.timers.list(packID: id).map { t in
                    ["id": t.id, "label": t.label, "seconds": t.seconds, "paused": t.endsAt == nil,
                     "endsAt": t.endsAt.map { $0.timeIntervalSince1970 * 1000 } ?? NSNull(), "remaining": t.remaining * 1000,
                     "phase": t.phase, "phases": t.phases, "sound": t.sound ?? NSNull()] as [String: Any]
                })
            }
        } as @convention(block) () -> String)
        define("timersControl", { [weak self] (action: String, timer: String) in
            MainActor.assumeIsolated {
                guard let self, allowed("timers") else { return }
                switch action {
                case "pause": self.services.timers.pause(packID: id, id: timer)
                case "resume": self.services.timers.resume(packID: id, id: timer)
                case "cancel": self.services.timers.cancel(packID: id, id: timer)
                default: break
                }
            }
        } as @convention(block) (String, String) -> Void)
        define("timersFinished", { [weak self] () -> String in
            MainActor.assumeIsolated {
                guard let self, allowed("timers") else { return "[]" }
                return Self.jsonString(self.services.timers.finishedLog(packID: id).map {
                    ["label": $0.label, "at": $0.at.timeIntervalSince1970 * 1000] as [String: Any]
                })
            }
        } as @convention(block) () -> String)
        define("timerSounds", { () -> [String] in PackTimers.sounds } as @convention(block) () -> [String])
        define("timerPreview", { (sound: String) in MainActor.assumeIsolated { PackTimers.preview(sound) } } as @convention(block) (String) -> Void)

        define("clipRecording", { [weak self] () -> Bool in
            MainActor.assumeIsolated { self.map { allowed("clipboard.read") && $0.services.clipboard.isRecording(packID: id) } ?? false }
        } as @convention(block) () -> Bool)
        define("clipRecord", { [weak self] (on: Bool) in
            MainActor.assumeIsolated {
                guard let self, allowed("clipboard.read") else { return }
                self.services.clipboard.setRecording(on, packID: id, packName: name)
            }
        } as @convention(block) (Bool) -> Void)
        define("clipItems", { [weak self] (query: String) -> String in
            MainActor.assumeIsolated {
                guard let self, allowed("clipboard.read") else { return "[]" }
                return Self.jsonString(self.services.clipboard.items(packID: id, query: query).map { item in
                    ["id": item.id, "kind": item.kind, "text": item.text.map { String($0.prefix(2000)) } ?? NSNull(),
                     "image": item.kind != "text" ? "clipboard:\(item.id)" : NSNull(), "width": item.width ?? 0, "height": item.height ?? 0,
                     "files": item.files?.count ?? 0,
                     "bytes": item.bytes, "app": item.app ?? NSNull(), "appName": item.appName ?? NSNull(),
                     "at": item.at.timeIntervalSince1970 * 1000, "pinned": item.pinned] as [String: Any]
                })
            }
        } as @convention(block) (String) -> String)
        define("clipControl", { [weak self] (action: String, item: String, on: Bool) -> Bool in
            MainActor.assumeIsolated {
                guard let self, allowed("clipboard.read") else { return false }
                let history = self.services.clipboard
                switch action {
                case "copy": return history.copy(packID: id, id: item)
                case "paste": return allowed("clipboard.paste") && history.paste(packID: id, id: item)
                case "pin": history.pin(packID: id, id: item, on)
                case "remove": history.remove(packID: id, id: item)
                case "clear": history.clear(packID: id)
                case "ignore": history.setIgnored(packID: id, app: item, on)
                default: return false
                }
                return true
            }
        } as @convention(block) (String, String, Bool) -> Bool)
        define("clipApps", { [weak self] () -> String in
            MainActor.assumeIsolated {
                guard let self, allowed("clipboard.read") else { return "[]" }
                return Self.jsonString(self.services.clipboard.apps(packID: id).map { ["id": $0.id, "name": $0.name, "ignored": $0.ignored] as [String: Any] })
            }
        } as @convention(block) () -> String)

        define("shortcutGet", { [weak self] () -> Any in
            let label: String? = MainActor.assumeIsolated {
                guard let self, allowed("shortcut") else { return nil }
                return self.services.shortcuts.current(packID: id)?.label
            }
            return label ?? NSNull()
        } as @convention(block) () -> Any)
        define("shortcutClear", { [weak self] in
            MainActor.assumeIsolated {
                guard let self, allowed("shortcut") else { return }
                self.services.shortcuts.remove(packID: id)
            }
        } as @convention(block) () -> Void)

        define("systemStats", { [weak self] () -> String in
            MainActor.assumeIsolated {
                guard let self, allowed("system.stats") else { return "{}" }
                return Self.jsonString(self.services.system.read())
            }
        } as @convention(block) () -> String)
        // System (SDK 8): the graphs' history, and the network checks the person starts.
        define("system", { [weak self] (action: String, callback: Int) -> String in
            MainActor.assumeIsolated {
                guard let self else { return "null" }
                switch action {
                case "history":
                    guard allowed("system.stats") else { return "[]" }
                    return Self.jsonString(SystemHistory.shared.json())
                case "publicIP":
                    guard allowed("network.test") else { return "null" }
                    Task { [weak self] in
                        let address = await NetworkTests.publicAddress()
                        self?.respond(callback, ["address": address as Any])
                    }
                case "speedTest":
                    guard allowed("network.test") else { return "null" }
                    Task { [weak self] in
                        let result = await NetworkTests.speedTest { _ in }
                        self?.respond(callback, result.map { $0 as [String: Any] } ?? ["error": "The test couldn't reach the server"])
                    }
                default: break
                }
                return "null"
            }
        } as @convention(block) (String, Int) -> String)
        // Words (dictionary, SDK 4): read on demand from the dictionary and thesaurus in macOS.
        define("dictionary", { [weak self] (action: String, arg: String) -> String in
            MainActor.assumeIsolated {
                guard let self, allowed("dictionary") else { return "null" }
                let words = self.services.dictionary
                switch action {
                case "define": return Self.jsonString(words.define(arg))
                case "synonyms": return Self.jsonString(words.synonyms(arg))
                case "suggest": return Self.jsonString(words.suggestions(String(arg.prefix(PackDictionary.maxWord))))
                case "status": return Self.jsonString(words.status())
                case "speak": words.speak(arg)
                case "open": words.openInApp(arg)
                default: break
                }
                return "null"
            }
        } as @convention(block) (String, String) -> String)
        // The text on the clipboard (clipboard.text, SDK 4), only while the utility is on screen.
        define("clipboardText", { [weak self] () -> Any in
            let value: String? = MainActor.assumeIsolated {
                guard let self, allowed("clipboard.text"), !self.isPaused else { return nil }
                return NSPasteboard.general.string(forType: .string).map { String($0.prefix(2000)) }
            }
            return value ?? NSNull()
        } as @convention(block) () -> Any)
        // Screenshots (screen.capture).
        define("screen", { [weak self] (action: String, arg: String, callback: Int) -> String in
            MainActor.assumeIsolated {
                guard let self, allowed("screen.capture") else { return "null" }
                let capture = self.services.capture
                func shotJSON(_ shot: ScreenCapture.Shot) -> [String: Any] {
                    ["id": shot.id, "width": shot.image.width, "height": shot.image.height, "at": shot.date.timeIntervalSince1970 * 1000,
                     "saved": shot.savedURL?.lastPathComponent ?? NSNull(), "image": "screenshot:\(shot.id)"]
                }
                switch action {
                case "permission": return capture.hasPermission ? "true" : "false"
                case "requestPermission": capture.requestPermission()
                case "capture" where arg == "scrolling":
                    capture.scrollingCapture(packID: id)
                case "capture":
                    capture.capture(packID: id, mode: ScreenCapture.Mode(rawValue: arg) ?? .area) { [weak self] shot, error in
                        self?.respond(callback, shot.map { ["id": $0] as [String: Any] } ?? ["error": error ?? ""])
                    }
                // SDK 7: the capture bar, text, colors, pins and recording.
                case "openBar": capture.openBar(packID: id)
                case "copyText": if allowed("screen.text") { self.services.hidePanel(); capture.copyText() }
                case "pickColor": self.services.hidePanel(); capture.pickColor()
                case "pin": if let shot = capture.shot(arg) { capture.pins.pin(shot.image, near: NSEvent.mouseLocation) }
                case "record":
                    guard allowed("screen.record") else { break }
                    self.services.hidePanel()
                    capture.recorder.start(packID: id, target: arg == "window" ? .window : arg == "screen" ? .screen : .area)
                case "isRecording": return capture.recorder.isRecording ? "true" : "false"
                case "stopRecording": capture.recorder.stop()
                case "recordings":
                    guard allowed("screen.record") else { break }
                    return Self.jsonString(capture.recorder.recordings.map {
                        ["id": $0.id, "at": $0.date.timeIntervalSince1970 * 1000, "clicks": $0.clicks.count] as [String: Any]
                    })
                case "openRecording":
                    if allowed("screen.record"), let recording = capture.recorder.recording(arg) { capture.recorder.editors.open(recording) }
                case "recordPrefs":
                    let p = capture.recordPrefs(id)
                    return Self.jsonString(["systemAudio": p.systemAudio, "microphone": p.microphone, "fps": p.fps, "pointer": p.showsPointer] as [String: Any])
                case "setRecordPrefs":
                    guard let o = Self.jsonObject(arg) else { break }
                    var p = capture.recordPrefs(id)
                    if let v = o["systemAudio"] as? Bool { p.systemAudio = v }
                    if let v = o["microphone"] as? Bool { p.microphone = v }
                    if let v = (o["fps"] as? NSNumber)?.intValue { p.fps = v == 30 ? 30 : 60 }
                    if let v = o["pointer"] as? Bool { p.showsPointer = v }
                    capture.setRecordPrefs(p, packID: id)
                case "prefs":
                    let p = capture.prefs(id)
                    return Self.jsonString(["delay": p.delay, "pointer": p.pointer, "sound": p.sound, "format": p.format, "autoCopy": p.autoCopy,
                                            "freeze": p.freeze, "shortcutAction": p.shortcutAction, "instantMode": p.instantMode] as [String: Any])
                case "setPrefs":
                    guard let o = Self.jsonObject(arg) else { break }
                    var p = capture.prefs(id)
                    if let v = (o["delay"] as? NSNumber)?.intValue { p.delay = [0, 3, 5, 10].contains(v) ? v : 0 }
                    if let v = o["pointer"] as? Bool { p.pointer = v }
                    if let v = o["sound"] as? Bool { p.sound = v }
                    if let v = o["format"] as? String { p.format = v == "jpeg" ? "jpeg" : "png" }
                    if let v = o["autoCopy"] as? Bool { p.autoCopy = v }
                    if let v = o["freeze"] as? Bool { p.freeze = v }
                    if let v = o["shortcutAction"] as? String { p.shortcutAction = v == "instant" ? "instant" : "bar" }
                    if let v = o["instantMode"] as? String { p.instantMode = ["area", "window", "screen"].contains(v) ? v : "area" }
                    capture.setPrefs(p, packID: id)
                case "folder":
                    return Self.jsonString(["label": capture.folderLabel(id), "custom": capture.folder(id).custom] as [String: Any])
                case "chooseFolder": capture.chooseFolder(packID: id) { [weak self] ok in self?.respond(callback, ok) }
                case "resetFolder": capture.resetFolder(packID: id)
                case "openFolder": capture.openFolder(packID: id)
                case "shots": return Self.jsonString(capture.shots.map(shotJSON))
                case "copy": return capture.copy(arg) ? "true" : "false"
                case "save": return capture.save(arg, packID: id).map { Self.jsonString([$0]) } ?? "null"
                case "saveAs": capture.saveAs(arg, packID: id) { [weak self] ok in self?.respond(callback, ok) }
                case "delete": capture.delete(arg)
                case "canEdit": return self.services.imageEditor() == nil ? "false" : "true"
                case "edit": if let editor = self.services.imageEditor() { self.services.openInEditor(editor, arg) }
                default: break
                }
                return "null"
            }
        } as @convention(block) (String, String, Int) -> String)
        // Media tools (media.convert, SDK 7): files come in by id only.
        define("media", { [weak self] (action: String, arg: String, callback: Int) -> String in
            MainActor.assumeIsolated {
                guard let self, allowed("media.convert") else { return "null" }
                let media = self.services.media
                let o = Self.jsonObject(arg) ?? [:]
                let reply: ([String: Any]) -> Void = { [weak self] result in self?.respond(callback, result) }
                let ids = (o["ids"] as? [String]) ?? (o["id"] as? String).map { [$0] } ?? []
                switch action {
                case "pick":
                    media.pick(kind: o["kind"] as? String ?? "images", multiple: o["multiple"] as? Bool ?? true, packID: id) { [weak self] files in
                        self?.respond(callback, files)
                    }
                case "shrink": media.shrink(ids.first ?? "", quality: o["quality"] as? String ?? "medium", packID: id, done: reply)
                case "gif": media.gif(ids.first ?? "", width: (o["width"] as? NSNumber)?.intValue ?? 720, fps: (o["fps"] as? NSNumber)?.intValue ?? 12, packID: id, done: reply)
                case "convert": media.convert(ids, format: o["format"] as? String ?? "jpeg", packID: id, done: reply)
                case "watermark":
                    media.watermark(ids, text: o["text"] as? String ?? "", position: o["position"] as? String ?? "bottomRight",
                                    opacity: (o["opacity"] as? NSNumber)?.doubleValue ?? 0.8, packID: id, done: reply)
                case "status":
                    guard let job = media.job else { return "null" }
                    return Self.jsonString(["label": job.label, "progress": job.progress] as [String: Any])
                default: break
                }
                return "null"
            }
        } as @convention(block) (String, String, Int) -> String)
        // Its own window (windows, SDK 3).
        define("window", { [weak self] (action: String, arg: String, callback: Int) in
            MainActor.assumeIsolated {
                guard let self, allowed("windows") else { return }
                switch action {
                case "open":
                    // From the panel: a new window running this pack, started with `arg` (JSON).
                    guard case .panel = self.mode, let input = Self.jsonObject(arg) else { return }
                    if let image = input["image"] as? String, self.services.images.entry(image)?.packID != id { return }
                    self.services.windows.open(self.bundle, input: Self.jsonString(input))
                case "title": self.windowHost?.packWindowTitle(String(arg.prefix(120)))
                case "edited": self.windowHost?.packWindowEdited(arg == "true")
                case "close": self.windowHost?.packWindowClose()
                case "appearance": self.windowHost?.packWindowAppearance(arg)
                case "choose":
                    guard let o = Self.jsonObject(arg), let host = self.windowHost else { return self.respond(callback, -1) }
                    let buttons = (o["buttons"] as? [[String: Any]] ?? []).prefix(3).map {
                        (label: String(($0["label"] as? String ?? "OK").prefix(40)), destructive: $0["destructive"] as? Bool ?? false)
                    }
                    host.packWindowChoose(title: String((o["title"] as? String ?? "").prefix(200)),
                                          message: (o["message"] as? String).map { String($0.prefix(500)) },
                                          buttons: Array(buttons)) { [weak self] i in self?.respond(callback, i) }
                case "confirm":
                    guard let o = Self.jsonObject(arg), let host = self.windowHost else { return self.respond(callback, false) }
                    host.packWindowConfirm(title: String((o["title"] as? String ?? "").prefix(200)),
                                           message: (o["message"] as? String).map { String($0.prefix(500)) },
                                           button: String((o["button"] as? String ?? "OK").prefix(40)),
                                           destructive: o["destructive"] as? Bool ?? false) { [weak self] ok in self?.respond(callback, ok) }
                default: break
                }
            }
        } as @convention(block) (String, String, Int) -> Void)
        // Images an editor works on (images.edit, SDK 3).
        define("images", { [weak self] (action: String, arg: String, drawing: String, callback: Int) -> String in
            MainActor.assumeIsolated {
                guard let self, allowed("images.edit") else { return "null" }
                return self.imagesCall(action, arg, drawing, callback)
            }
        } as @convention(block) (String, String, String, Int) -> String)
        define("log", { [weak self] (s: String) in
            #if DEBUG
            MainActor.assumeIsolated { print("[\(self?.bundle.id ?? "pack")] \(s)") }
            #endif
        } as @convention(block) (String) -> Void)

        let setup = context.evaluateScript(Self.prelude, withSourceURL: URL(string: "zephydian-sdk.js"))
        let input: String? = if case .window(let input) = mode { input } else { nil }
        guard let result = setup?.call(withArguments: [native, bundle.manifest.kind, Array(capabilities).sorted(), input ?? NSNull(),
                                                       mode == .settings]),
              failure == nil else { return }
        sdk = result.objectForKeyedSubscript("sdk")
        // `z` and `zephydian` can't be replaced by the pack.
        for name in ["z", "zephydian"] {
            context.globalObject.defineProperty(name, descriptor: [
                JSPropertyDescriptorValueKey: result.objectForKeyedSubscript(name)!,
                JSPropertyDescriptorWritableKey: false, JSPropertyDescriptorConfigurableKey: false,
                JSPropertyDescriptorEnumerableKey: false,
            ])
        }
    }

    /// `z.images`: the pictures an image editor works on. Everything here needs `images.edit`;
    /// copying also needs `clipboard.write`, and Save as… `files.save`.
    private func imagesCall(_ action: String, _ arg: String, _ drawing: String, _ callback: Int) -> String {
        let images = services.images, capture = services.capture, id = bundle.id
        func info(_ imageID: String?) -> String {
            imageID.flatMap { images.entry($0) }.map { Self.jsonString(images.info($0)) } ?? "null"
        }
        /// The image this pack may use, by its "image:<id>".
        func own(_ imageID: String) -> PackImages.Entry? {
            images.entry(imageID).flatMap { $0.packID == id ? $0 : nil }
        }
        func render() -> CGImage? {
            PackImages.render(drawingJSON: drawing) { [weak self] name in self?.picture(name) }
        }
        switch action {
        case "screenshots":
            return Self.jsonString(capture.shots.map { shot in
                ["id": shot.id, "width": shot.image.width, "height": shot.image.height, "at": shot.date.timeIntervalSince1970 * 1000,
                 "saved": shot.savedURL?.lastPathComponent ?? NSNull(), "image": "screenshot:\(shot.id)"] as [String: Any]
            })
        case "fromScreenshot": return info(images.fromScreenshot(arg, packID: id))
        case "open": images.open(packID: id) { [weak self] new in self?.respond(callback, new.flatMap { images.entry($0) }.map(images.info) ?? NSNull()) }
        case "paste": return info(images.paste(packID: id))
        case "info": return own(arg).map { Self.jsonString(images.info($0)) } ?? "null"
        case "copy":
            guard capabilities.contains("clipboard.write"), let image = render(),
                  let png = PackImages.encode(image, format: "png") else { return "false" }
            PackNative.copyImage(png)
            return "true"
        case "update":
            // Hands the edited picture back to where it came from (a screenshot's list entry).
            guard let entry = own(arg), case .screenshot(let shot) = entry.source, let image = render() else { return "false" }
            capture.replace(shot, with: image)
            return "true"
        case "save":
            // Saves over where the picture came from: the screenshot's file (or its folder), or the opened file.
            guard let entry = own(arg), let image = render() else { return "null" }
            switch entry.source {
            case .screenshot(let shot):
                guard let owner = capture.shot(shot) else { return "null" }
                capture.replace(shot, with: image)
                let screenshotPack = owner.packID ?? PackLibrary.shared.packs.first { $0.manifest.capabilities?.contains("screen.capture") == true }?.id ?? "screenshot"
                return capture.save(shot, packID: screenshotPack).map { Self.jsonString([$0]) } ?? "null"
            case .file(let url):
                // Written in place (not atomically), so the file keeps its identity, like Preview does.
                guard let data = PackImages.encode(image, format: url.pathExtension),
                      ["png", "jpg", "jpeg", "tif", "tiff"].contains(url.pathExtension.lowercased()),
                      (try? data.write(to: url)) != nil else { return "null" }
                return Self.jsonString([url.lastPathComponent])
            case .clipboard:
                return "null"
            }
        case "saveAs":
            guard capabilities.contains("files.save"), let entry = own(arg), let image = render() else { respond(callback, false); return "null" }
            var format = "png"
            switch entry.source {
            case .screenshot(let shot): format = capture.prefs(capture.shot(shot)?.packID ?? "screenshot").format
            case .file(let url): format = ["jpg", "jpeg"].contains(url.pathExtension.lowercased()) ? "jpeg" : "png"
            case .clipboard: break
            }
            guard let data = PackImages.encode(image, format: format) else { respond(callback, false); return "null" }
            PackNative.save(name: "\(entry.name).\(format == "jpeg" ? "jpg" : "png")", data: data) { [weak self] ok in self?.respond(callback, ok) }
        case "discard":
            // Delete: a screenshot is forgotten and its saved file goes to the Trash. Opened files are never deleted.
            guard let entry = own(arg) else { return "false" }
            if case .screenshot(let shot) = entry.source { capture.delete(shot) }
            images.forget(arg)
            return "true"
        default: break
        }
        return "null"
    }

    /// A picture for `g.image` in an exported drawing (the same ones the pack can show).
    func picture(_ name: String) -> NSImage? {
        services.images.picture(name, packID: bundle.id, capabilities: capabilities)
    }

    /// The SDK's JavaScript side. It checks and flattens what packs pass in, so Swift only sees plain values.
    private static let prelude = #"""
    (function (N, KIND, CAPS, INPUT, SETTINGS) {
      "use strict";
      const num = v => (typeof v === "number" && isFinite(v)) ? v : 0;
      const col = v => (typeof v === "string" && v.length < 64) ? v : null;
      const MAX = \#(maxShapes);
      class Draw {
        constructor() { this._c = []; }
        _p(c) { if (this._c.length >= MAX) throw new Error("too many shapes in one frame (the limit is " + MAX + ")"); this._c.push(c); }
        clear(fill) { this._p(["clear", col(fill) || "background"]); }
        rect(x, y, w, h, o = {}) { this._p(["rect", num(x), num(y), num(w), num(h), col(o.fill), col(o.stroke), num(o.lineWidth) || 1, num(o.radius)]); }
        circle(x, y, r, o = {}) { this._p(["circle", num(x), num(y), num(r), col(o.fill), col(o.stroke), num(o.lineWidth) || 1]); }
        ellipse(x, y, w, h, o = {}) { this._p(["ellipse", num(x), num(y), num(w), num(h), col(o.fill), col(o.stroke), num(o.lineWidth) || 1]); }
        clip(x, y, w, h, o = {}) { this._p(["clip", num(x), num(y), num(w), num(h), num(o.radius)]); }
        shadow(color, o = {}) { this._p(["shadow", col(color) || "#00000059", num(o.radius), num(o.x), num(o.y)]); }
        symbol(name, x, y, size, o = {}) { this._p(["symbol", String(name).slice(0, 80), num(x), num(y), num(size) || 24, col(o.color) || "text"]); }
        gradient(x, y, w, h, colors, o = {}) {
          this._p(["gradient", num(x), num(y), num(w), num(h), num(o.radius), (Array.isArray(colors) ? colors : []).slice(0, 4).map(c => col(c) || "fill")]);
        }
        line(x1, y1, x2, y2, o = {}) { this._p(["line", num(x1), num(y1), num(x2), num(y2), col(o.stroke) || "text", num(o.lineWidth) || 1, o.cap === "round" ? 1 : 0]); }
        path(points, o = {}) {
          const flat = [];
          for (const p of (Array.isArray(points) ? points : [])) flat.push(num(p && p[0]), num(p && p[1]));
          this._p(["path", flat, col(o.fill), col(o.stroke), num(o.lineWidth) || 1, o.closed ? 1 : 0,
                   (o.cap === "round" || o.join === "round") ? 1 : 0]);
        }
        text(s, x, y, o = {}) {
          this._p(["text", String(s).slice(0, 500), num(x), num(y), num(o.size) || 13, String(o.weight || "regular"),
                   col(o.color) || "text", String(o.align || "left"), String(o.font || "system")]);
        }
        image(name, x, y, w, h, o = {}) { this._p(["image", String(name), num(x), num(y), num(w), num(h), o.opacity == null ? 1 : num(o.opacity), num(o.pixelate)]); }
        save() { this._p(["save"]); }
        restore() { this._p(["restore"]); }
        translate(x, y) { this._p(["translate", num(x), num(y)]); }
        rotate(r) { this._p(["rotate", num(r)]); }
        scale(s) { this._p(["scale", s == null ? 1 : num(s)]); }
        alpha(a) { this._p(["alpha", num(a)]); }
      }

      let game = null, menu = null, buttons = [];
      const pending = new Map();
      const call = (name, ...a) => (game && typeof game[name] === "function") ? game[name](...a) : undefined;
      const text = v => v == null ? "" : String(v);
      const callbacks = new Map();
      let nextCallback = 1;
      const later = fn => {
        if (fn == null) return 0;
        if (typeof fn !== "function") throw new TypeError("expected a function");
        const id = nextCallback++;
        callbacks.set(id, fn);
        return id;
      };
      // A drawing to export: { width, height, scale, draw(g, width, height) } → JSON for Swift.
      const drawing = d => {
        if (!d || typeof d.draw !== "function") throw new TypeError("expected { width, height, draw(g) }");
        const g = new Draw(), w = num(d.width) || 100, h = num(d.height) || 100;
        d.draw(g, w, h);
        return JSON.stringify({ width: w, height: h, scale: num(d.scale) || 2, shapes: g._c });
      };
      const need = c => {
        if (CAPS.indexOf(c) < 0) throw new Error('add "' + c + '" to "capabilities" in manifest.json to use this');
      };

      // Utility controls (SDK 2). Builders make plain objects; walk() checks them, keeps their
      // handlers here by key, and sends Swift only plain values.
      const MAXN = \#(PackUINode.maxNodes), MAXD = \#(PackUINode.maxDepth);
      const handlers = new Map();
      let nodeCount = 0;
      const list = v => (Array.isArray(v) ? v : [v]).filter(c => c != null && c !== false);
      const ui = Object.freeze({
        text: (s, o = {}) => Object.assign({}, o, { t: "text", text: text(s) }),
        field: (o = {}) => Object.assign({}, o, { t: "field", value: text(o.value) }),
        button: (label, onPress, o = {}) => Object.assign({}, o, { t: "button", label: text(label), onPress }),
        toggle: (label, value, onChange, o = {}) => Object.assign({}, o, { t: "toggle", label: text(label), value: !!value, onChange }),
        slider: (o = {}) => Object.assign({}, o, { t: "slider" }),
        segmented: (options, selected, onChange, o = {}) => Object.assign({}, o, { t: "segmented", options: list(options).map(text), selected, onChange }),
        picker: (label, options, selected, onChange, o = {}) => Object.assign({}, o, { t: "picker", label: text(label), options: list(options).map(text), selected, onChange }),
        copy: (value, o = {}) => Object.assign({}, o, { t: "copy", text: text(value) }),
        row: (children, o = {}) => Object.assign({}, o, { t: "row", children: list(children) }),
        flow: (children, o = {}) => Object.assign({}, o, { t: "flow", children: list(children) }),
        column: (children, o = {}) => Object.assign({}, o, { t: "column", children: list(children) }),
        section: (title, children, o = {}) => Object.assign({}, o, { t: "section", title: title == null ? null : text(title), children: list(children) }),
        list: (items, o = {}) => Object.assign({}, o, { t: "list", items: list(items).map(i => ({
          id: text(i.id), title: text(i.title), subtitle: i.subtitle == null ? null : text(i.subtitle),
          detail: i.detail == null ? null : text(i.detail), symbol: i.symbol == null ? null : text(i.symbol),
          image: i.image == null ? null : text(i.image),
          actions: list(i.actions || []).map(a => ({ symbol: text(a.symbol), label: text(a.label) })) })) }),
        canvas: (o = {}) => Object.assign({}, o, { t: "canvas" }),
        toolbar: (children, o = {}) => Object.assign({}, o, { t: "toolbar", children: list(children) }),
        logo: (o = {}) => Object.assign({}, o, { t: "logo" }),
        band: (left, center, right, o = {}) => Object.assign({}, o, { t: "band", children: [left, center, right].map(c => c || { t: "spacer" }) }),
        menu: (label, items, selected, onSelect, o = {}) => Object.assign({}, o, { t: "menu", label: text(label), items: list(items).map(text), selected, onSelect }),
        swatch: (color, o = {}) => Object.assign({}, o, { t: "swatch", color: text(color) }),
        shortcut: (label, o = {}) => { need("shortcut"); return Object.assign({}, o, { t: "shortcut", label: text(label) }); },
        disclosure: (label, expanded, onToggle, children, o = {}) => Object.assign({}, o, {
          t: "disclosure", label: text(label), expanded: !!expanded, onToggle, children: list(children) }),
        divider: () => ({ t: "divider" }),
        spacer: () => ({ t: "spacer" }),
      });
      function walk(n, path, depth) {
        if (!n || typeof n !== "object" || typeof n.t !== "string") throw new TypeError("view() must return z.ui controls");
        if (++nodeCount > MAXN) throw new Error("the view has more than " + MAXN + " controls");
        if (depth > MAXD) throw new Error("the view is nested more than " + MAXD + " deep");
        const k = (typeof n.id === "string" || typeof n.id === "number") ? String(n.id) : path;
        const out = { k };
        for (const key of Object.keys(n)) {
          const v = n[key];
          if (typeof v === "function") { if (key !== "draw") (out.on = out.on || []).push(key); }
          else if (key !== "children" && key !== "id" && key !== "on") out[key] = v;
        }
        handlers.set(k, n);
        if (n.t === "canvas") {
          const g = new Draw();
          const fit = n.fit && typeof n.fit === "object" ? n.fit : null;
          if (typeof n.draw === "function") n.draw(g, fit ? num(fit.width) : (num(n.width) || z.width), fit ? num(fit.height) : (num(n.height) || 100));
          out.shapes = g._c;
        }
        if (Array.isArray(n.children)) out.children = n.children.map((c, i) => walk(c, k + "." + i, depth + 1));
        return out;
      }

      const z = {
        width: 0, height: 0, theme: Object.freeze({}),
        redraw() { N.redraw(); },
        loop: Object.freeze({ start(ms) { N.loopStart(num(ms)); }, stop() { N.loopStop(); } }),
        after(ms, fn) {
          if (typeof fn !== "function") throw new TypeError("z.after needs a function");
          const id = N.after(num(ms));
          if (id) pending.set(id, fn);
          return id;
        },
        cancel(id) { pending.delete(id); N.cancel(num(id)); },
        score(t) { N.score(text(t)); },
        hint(t) { N.hint(text(t)); },
        toast(t) { N.toast(text(t)); },
        menu(m) {
          menu = m || null;
          N.menu(m ? JSON.stringify({ title: text(m.title), items: (Array.isArray(m.items) ? m.items : []).map(text),
                                      selected: typeof m.selected === "number" ? m.selected : -1 }) : null);
        },
        overlay(o) {
          buttons = (o && Array.isArray(o.buttons)) ? o.buttons : [];
          N.overlay(o ? JSON.stringify({ title: text(o.title), subtitle: o.subtitle == null ? null : text(o.subtitle),
                                         buttons: buttons.map(b => ({ label: text(b && b.label), prominent: !!(b && b.prominent) })) }) : null);
        },
        best: Object.freeze({
          score() { return N.bestScore(); },
          submitScore(n) { return N.submitScore(num(n)); },
          time() { return N.bestTime(); },
          submitTime(s) { return N.submitTime(num(s)); },
        }),
        storage: Object.freeze({
          get(k) { const s = N.storageGet(text(k)); return s == null ? null : JSON.parse(s); },
          set(k, v) {
            const s = JSON.stringify(v);
            if (s === undefined) throw new TypeError("z.storage.set needs a JSON value");
            if (!N.storageSet(text(k), s)) throw new Error("storage is full (the limit is 1 MB per pack)");
          },
          remove(k) { N.storageRemove(text(k)); },
          clear() { N.storageClear(); },
        }),
        data(name) {
          const s = N.data(text(name));
          if (s == null) throw new Error("no such file: assets/" + name);
          return /\.json$/i.test(name) ? JSON.parse(s) : s;
        },
        log(...a) { N.log(a.map(x => typeof x === "string" ? x : JSON.stringify(x)).join(" ")); },
        ui,
        tile(t) { N.tile(text(t)); },
        random: Object.freeze({
          int(max) { return N.randomInt(Math.floor(num(max))); },
          pick(arr) { return (Array.isArray(arr) && arr.length) ? arr[N.randomInt(arr.length)] : undefined; },
          uuid() { return N.uuid(); },
        }),
        clipboard: Object.freeze({
          write(t, o = {}) { need("clipboard.write"); N.clipboardWrite(text(t), !!(o && o.concealed)); },
          writeImage(d) { need("clipboard.write"); return N.clipboardWriteImage(drawing(d)); },
          readText() { need("clipboard.text"); return N.clipboardText(); },
        }),
        dictionary: (() => {
          const D = (action, arg) => { need("dictionary"); return JSON.parse(N.dictionary(action, arg == null ? "" : text(arg))); };
          return Object.freeze({
            define(word) { return D("define", word); },
            synonyms(word) { return D("synonyms", word); },
            suggest(word) { return D("suggest", word) || []; },
            status() { return D("status"); },
            speak(word) { D("speak", word); },
            open(word) { D("open", word); },
          });
        })(),
        text: Object.freeze({
          base64Encode(s) { return N.base64Encode(text(s)); },
          base64Decode(s) { return N.base64Decode(text(s)); },
          sha256(s) { return N.sha256(text(s)); },
        }),
        qr(t, o = {}) {
          const rows = N.qr(text(t), String((o && o.level) || "M"));
          return rows == null ? null : rows.map(r => Array.from(r, c => c === "1"));
        },
        files: Object.freeze({
          save(o, done) {
            need("files.save");
            if (!o || typeof o.name !== "string") throw new TypeError("z.files.save needs { name, text } or { name, image }");
            N.filesSave(o.name, o.image ? null : text(o.text), o.image ? drawing(o.image) : null, later(done));
          },
        }),
        color: Object.freeze({
          sample(done) { need("color.sample"); N.colorSample(later(done)); },
        }),
        timers: Object.freeze({
          start(o = {}) {
            need("timers");
            const chain = list((o && o.chain) || []).map(p => ({ label: text(p && p.label), seconds: num(p && p.seconds) }));
            return N.timersStart(JSON.stringify({ label: text(o.label), seconds: num(o.seconds),
                                                 sound: o.sound == null ? null : text(o.sound), chain }));
          },
          list() { need("timers"); return JSON.parse(N.timersList()); },
          pause(id) { need("timers"); N.timersControl("pause", text(id)); },
          resume(id) { need("timers"); N.timersControl("resume", text(id)); },
          cancel(id) { need("timers"); N.timersControl("cancel", text(id)); },
          finished() { need("timers"); return JSON.parse(N.timersFinished()); },
          sounds() { return N.timerSounds(); },
          preview(sound) { N.timerPreview(text(sound)); },
        }),
        history: Object.freeze({
          recording() { need("clipboard.read"); return N.clipRecording(); },
          record(on) { need("clipboard.read"); N.clipRecord(!!on); },
          items(o = {}) { need("clipboard.read"); return JSON.parse(N.clipItems(text(o && o.query))); },
          copy(id) { need("clipboard.read"); return N.clipControl("copy", text(id), false); },
          paste(id) { need("clipboard.read"); need("clipboard.paste"); return N.clipControl("paste", text(id), false); },
          pin(id, on) { need("clipboard.read"); N.clipControl("pin", text(id), !!on); },
          remove(id) { need("clipboard.read"); N.clipControl("remove", text(id), false); },
          clear() { need("clipboard.read"); N.clipControl("clear", "", false); },
          apps() { need("clipboard.read"); return JSON.parse(N.clipApps()); },
          ignore(app, on) { need("clipboard.read"); N.clipControl("ignore", text(app), !!on); },
        }),
        shortcut: Object.freeze({
          get() { need("shortcut"); return N.shortcutGet(); },
          clear() { need("shortcut"); N.shortcutClear(); },
        }),
        screen: (() => {
          const S = (action, arg, done) => { need("screen.capture"); return JSON.parse(N.screen(action, arg == null ? "" : String(arg), later(done))); };
          return Object.freeze({
            permission() { return S("permission"); },
            requestPermission() { S("requestPermission"); },
            capture(mode, done) { S("capture", text(mode || "area"), done); },
            prefs() { return S("prefs"); },
            setPrefs(o) { S("setPrefs", JSON.stringify(o || {})); },
            folder() { return S("folder"); },
            chooseFolder(done) { S("chooseFolder", "", done); },
            resetFolder() { S("resetFolder"); },
            openFolder() { S("openFolder"); },
            shots() { return S("shots"); },
            copy(id) { return S("copy", text(id)); },
            save(id) { const r = S("save", text(id)); return r ? r[0] : null; },
            saveAs(id, done) { S("saveAs", text(id), done); },
            delete(id) { S("delete", text(id)); },
            canEdit() { return S("canEdit"); },
            edit(id) { S("edit", text(id)); },
            // SDK 7
            openBar() { S("openBar"); },
            copyText() { need("screen.text"); S("copyText"); },
            pickColor() { S("pickColor"); },
            pin(id) { S("pin", text(id)); },
            record(target) { need("screen.record"); S("record", text(target || "area")); },
            isRecording() { return S("isRecording"); },
            stopRecording() { S("stopRecording"); },
            recordings() { need("screen.record"); return S("recordings") || []; },
            openRecording(id) { need("screen.record"); S("openRecording", text(id)); },
            recordPrefs() { return S("recordPrefs"); },
            setRecordPrefs(o) { S("setRecordPrefs", JSON.stringify(o || {})); },
          });
        })(),
        media: (() => {
          const M = (action, o, done) => { need("media.convert"); return JSON.parse(N.media(action, JSON.stringify(o || {}), later(done))); };
          return Object.freeze({
            pick(kind, done, multiple) { M("pick", { kind: text(kind || "images"), multiple: multiple !== false }, done); },
            shrink(id, quality, done) { M("shrink", { id: text(id), quality: text(quality || "medium") }, done); },
            gif(id, o, done) { M("gif", Object.assign({ id: text(id) }, o || {}), done); },
            convert(ids, format, done) { M("convert", { ids: (ids || []).map(text), format: text(format || "jpeg") }, done); },
            watermark(ids, o, done) { M("watermark", Object.assign({ ids: (ids || []).map(text) }, o || {}), done); },
            status() { return M("status"); },
          });
        })(),
        system: Object.freeze({
          stats() { need("system.stats"); return JSON.parse(N.systemStats()); },
          history() { need("system.stats"); return JSON.parse(N.system("history", 0)); },
          publicIP(done) { need("network.test"); N.system("publicIP", later(done)); },
          speedTest(done) { need("network.test"); N.system("speedTest", later(done)); },
        }),
        window: Object.freeze({
          isWindow: INPUT != null,
          input: INPUT == null ? null : Object.freeze(JSON.parse(INPUT)),
          open(input) { need("windows"); N.window("open", JSON.stringify(input || {}), 0); },
          title(t) { need("windows"); N.window("title", text(t), 0); },
          edited(on) { need("windows"); N.window("edited", on ? "true" : "false", 0); },
          close() { need("windows"); N.window("close", "", 0); },
          appearance(mode) { need("windows"); N.window("appearance", mode === "dark" ? "dark" : "auto", 0); },
          choose(o, done) {
            need("windows");
            N.window("choose", JSON.stringify({ title: text(o && o.title), message: o && o.message != null ? text(o.message) : null,
                                                buttons: list((o && o.buttons) || []).map(b => ({ label: text(b.label), destructive: !!b.destructive })) }), later(done));
          },
          confirm(o, done) {
            need("windows");
            N.window("confirm", JSON.stringify({ title: text(o && o.title), message: o && o.message != null ? text(o.message) : null,
                                                 button: text((o && o.button) || "OK"), destructive: !!(o && o.destructive) }), later(done));
          },
        }),
        images: (() => {
          const I = (action, arg, d, done) => {
            need("images.edit");
            return JSON.parse(N.images(action, arg == null ? "" : String(arg), d ? drawing(Object.assign({ scale: 1 }, d)) : "", later(done)));
          };
          return Object.freeze({
            screenshots() { return I("screenshots"); },
            fromScreenshot(id) { return I("fromScreenshot", text(id)); },
            open(done) { I("open", "", null, done); },
            paste() { return I("paste"); },
            info(id) { return I("info", text(id)); },
            copy(d) { need("clipboard.write"); return I("copy", "", d); },
            update(id, d) { return I("update", text(id), d); },
            save(id, d) { return I("save", text(id), d); },
            saveAs(id, d, done) { need("files.save"); I("saveAs", text(id), d, done); },
            discard(id) { I("discard", text(id)); },
          });
        })(),
        apps: (() => {
          const T = (action, o, done) => { need("apps.uninstall"); return JSON.parse(N.tools(action, JSON.stringify(o || {}), later(done))); };
          return Object.freeze({
            list(done) { T("apps", {}, done); },
            choose(done) { T("chooseApp", {}, done); },
            leftovers(app, done) { T("leftovers", { app: text(app) }, done); },
            uninstall(app, ids, done) { T("uninstall", { app: text(app), ids: (ids || []).map(text) }, done); },
          });
        })(),
        clean: (() => {
          const T = (action, o, done) => { need("files.clean"); return JSON.parse(N.tools(action, JSON.stringify(o || {}), later(done))); };
          return Object.freeze({
            scan(done) { T("scanClean", {}, done); },
            chats(days, done) { T("scanChats", { days: num(days) }, done); },
            trash(ids, done) { T("trash", { ids: (ids || []).map(text) }, done); },
            busy() { return JSON.parse(N.tools("busy", "{}", 0)); },
            reminder(value) { return T("reminder", value == null ? {} : { set: text(value) }); },
            openFullDiskAccess() { T("fullDiskAccess"); },
          });
        })(),
        ports: Object.freeze({
          list(done) { need("ports"); N.tools("ports", "{}", later(done)); },
          stop(pid, force) { need("ports"); return JSON.parse(N.tools("stopPort", JSON.stringify({ pid: num(pid), force: !!force }), 0)); },
        }),
        brew: (() => {
          const T = (action, o, done) => { need("homebrew"); return JSON.parse(N.tools(action, JSON.stringify(o || {}), later(done))); };
          return Object.freeze({
            status() { return T("brewStatus"); },
            search(query, done) { T("brewRead", { what: "search", query: text(query) }, done); },
            installed(done) { T("brewRead", { what: "installed" }, done); },
            outdated(done) { T("brewRead", { what: "outdated" }, done); },
            install(name, cask, done) { T("brewJob", { what: "install", name: text(name), cask: !!cask }, done); },
            uninstall(name, cask, done) { T("brewJob", { what: "uninstall", name: text(name), cask: !!cask }, done); },
            upgrade(name, cask, done) { T("brewJob", { what: "upgrade", name: text(name), cask: !!cask }, done); },
            update(done) { T("brewJob", { what: "update" }, done); },
            upgradeAll(done) { T("brewJob", { what: "upgradeAll" }, done); },
            cleanup(done) { T("brewJob", { what: "cleanup" }, done); },
            cancel() { T("cancelJob"); },
          });
        })(),
        updates: (() => {
          const T = (action, o, done) => { need("updates.check"); return JSON.parse(N.tools(action, JSON.stringify(o || {}), later(done))); };
          return Object.freeze({
            check(done) { T("checkUpdates", {}, done); },
            update(id, done) { T("update", { id: text(id) }, done); },
            status() { return T("brewStatus"); },
            cancel() { T("cancelJob"); },
          });
        })(),
        awake: Object.freeze({
          start(o = {}) { need("power.awake"); return N.awakeStart(num(o && o.minutes), !!(o && o.display)); },
          stop() { need("power.awake"); N.awakeStop(); },
          status() { need("power.awake"); return JSON.parse(N.awakeStatus()); },
          rules() { need("power.awake"); return JSON.parse(N.awakeRules("get", "", 0)); },
          setRules(o) { need("power.awake"); N.awakeRules("set", JSON.stringify(o || {}), 0); },
          pickApp(done) { need("power.awake"); N.awakeRules("pickApp", "", later(done)); },
        }),
      };
      Object.seal(z);

      const zephydian = Object.freeze({
        game(g) {
          if (KIND !== "game") throw new Error('this pack is a utility: call zephydian.utility() (or set "kind": "game")');
          if (game) throw new Error("zephydian.game() was called twice");
          if (!g || typeof g !== "object") throw new TypeError("zephydian.game() needs an object");
          game = g;
        },
        utility(u) {
          if (KIND !== "utility") throw new Error('this pack is a game: call zephydian.game() (or set "kind": "utility")');
          if (game) throw new Error("zephydian.utility() was called twice");
          if (!u || typeof u !== "object" || typeof u.view !== "function") throw new TypeError("zephydian.utility() needs an object with view()");
          if (SETTINGS) {
            // The utility's page in the Settings window (SDK 5): the settings object takes its place.
            if (!u.settings || typeof u.settings.view !== "function") return;
            game = u.settings;
          } else if (INPUT != null) {
            // Running in the pack's own window: the window object takes the utility's place.
            if (!u.window || typeof u.window.view !== "function") return;
            game = u.window;
          } else {
            game = u;
          }
        },
      });

      const sdk = {
        hasApp: () => game !== null,
        view: () => {
          handlers.clear();
          nodeCount = 0;
          return JSON.stringify(walk(call("view"), "0", 0));
        },
        callback: (id, v) => { const f = callbacks.get(id); callbacks.delete(id); if (f) f(v); },
        event: (k, name, v) => {
          const n = handlers.get(k), f = n && n[name];
          if (typeof f !== "function") return;
          if (name === "onAction" && v) f(v.id, v.action); else f(v);
        },
        setTheme(t) { z.theme = Object.freeze(t); },
        start: () => { call("start", z.window.input); },
        storageChanged: () => { call("storageChanged"); },
        draw: () => { const g = new Draw(); call("draw", g); return g._c; },
        tick: dt => { call("tick", dt); },
        key: e => call("key", Object.freeze(e)) === true,
        keyUp: e => call("keyUp", Object.freeze(e)) === true,
        click: e => { call("click", Object.freeze(e)); },
        pause: () => { call("pause"); },
        resume: () => { call("resume"); },
        undo: () => call("undo") === true,
        redo: () => call("redo") === true,
        shouldClose: () => call("shouldClose") !== false,
        shortcut: () => { call("shortcut"); },
        fire: id => { const f = pending.get(id); pending.delete(id); if (f) f(); },
        clearTimers: () => { pending.clear(); },
        overlayPress: i => { const b = buttons[i]; if (b && typeof b.action === "function") b.action(); },
        menuSelect: i => {
          if (!menu) return;
          const m = menu;
          z.menu(Object.assign({}, m, { selected: i }));   // tick the picked item
          if (typeof m.onSelect === "function") m.onSelect(i);
        },
      };
      return { z, zephydian, sdk };
    })
    """#

    // MARK: Decoding

    private static func keyObject(_ e: PackKey) -> [String: Any] {
        ["key": e.key, "shift": e.shift, "option": e.option, "repeat": e.isRepeat, "command": e.command]
    }

    static func jsonObject(_ s: String) -> [String: Any]? {
        s.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }

    static func jsonString(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value) else { return "null" }
        return String(decoding: data, as: UTF8.self)
    }

    private static func json(_ value: JSValue) -> [String: Any]? {
        guard value.isString, let data = value.toString().data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func decodeOverlay(_ value: JSValue) -> PackOverlay? {
        guard let o = json(value) else { return nil }
        let buttons = (o["buttons"] as? [[String: Any]] ?? []).prefix(4).map {
            PackOverlay.Button(label: $0["label"] as? String ?? "", prominent: $0["prominent"] as? Bool ?? false)
        }
        return PackOverlay(title: o["title"] as? String ?? "", subtitle: o["subtitle"] as? String, buttons: Array(buttons))
    }

    static func decodeMenu(_ value: JSValue) -> PackMenu? {
        guard let m = json(value) else { return nil }
        return PackMenu(title: m["title"] as? String ?? "", items: Array((m["items"] as? [String] ?? []).prefix(30)),
                        selected: (m["selected"] as? NSNumber)?.intValue ?? -1)
    }

    nonisolated struct ShapeError: Error, CustomStringConvertible { let description: String }

    /// Turns the prelude's flat arrays into shapes, checking each one.
    static func parseShapes(_ list: JSValue) throws -> [PackShape] {
        try parseShapes(list.toArray() ?? [])
    }

    nonisolated static func parseShapes(_ items: [Any]) throws -> [PackShape] {
        guard items.count <= maxShapes else { throw ShapeError(description: "more than \(maxShapes) shapes") }
        var shapes: [PackShape] = []
        shapes.reserveCapacity(items.count)
        for case let item as [Any] in items {
            guard let op = item.first as? String else { continue }
            func d(_ i: Int) -> Double { (item[safe: i] as? NSNumber)?.doubleValue ?? 0 }
            func c(_ i: Int) -> PackColor? { (item[safe: i] as? String).flatMap(PackColor.init) }
            func s(_ i: Int) -> String { item[safe: i] as? String ?? "" }
            func style(_ at: Int) -> PackShape.Style { .init(fill: c(at), stroke: c(at + 1), lineWidth: max(0, d(at + 2))) }
            switch op {
            case "clear": shapes.append(.clear(c(1) ?? .theme("background")))
            case "rect": shapes.append(.rect(CGRect(x: d(1), y: d(2), width: d(3), height: d(4)), radius: max(0, d(8)), style(5)))
            case "circle": shapes.append(.circle(CGPoint(x: d(1), y: d(2)), radius: max(0, d(3)), style(4)))
            case "ellipse": shapes.append(.ellipse(CGRect(x: d(1), y: d(2), width: d(3), height: d(4)), style(5)))
            case "clip": shapes.append(.clip(CGRect(x: d(1), y: d(2), width: d(3), height: d(4)), radius: max(0, d(5))))
            case "shadow": shapes.append(.shadow(c(1) ?? .rgba(0, 0, 0, 0.35), radius: min(max(d(2), 0), 500), dx: d(3), dy: d(4)))
            case "symbol": shapes.append(.symbol(s(1), CGPoint(x: d(2), y: d(3)), size: min(max(d(4), 4), 4000), color: c(5) ?? .theme("text")))
            case "gradient":
                let colors = (item[safe: 6] as? [Any] ?? []).compactMap { ($0 as? String).flatMap(PackColor.init) }
                shapes.append(.gradient(CGRect(x: d(1), y: d(2), width: d(3), height: d(4)), radius: max(0, d(5)), colors))
            case "line": shapes.append(.line(CGPoint(x: d(1), y: d(2)), CGPoint(x: d(3), y: d(4)), color: c(5) ?? .theme("text"),
                                             width: max(0, d(6)), round: d(7) == 1))
            case "path":
                let flat = (item[safe: 1] as? [Any] ?? []).map { ($0 as? NSNumber)?.doubleValue ?? 0 }
                let points = stride(from: 0, to: flat.count - 1, by: 2).map { CGPoint(x: flat[$0], y: flat[$0 + 1]) }
                var pathStyle = style(2)
                pathStyle.round = d(6) == 1
                shapes.append(.path(points, closed: d(5) == 1, pathStyle))
            case "text":
                shapes.append(.text(s(1), CGPoint(x: d(2), y: d(3)), size: min(max(d(4), 4), 200),
                                    weight: .init(rawValue: s(5)) ?? .regular, color: c(6) ?? .theme("text"),
                                    align: .init(rawValue: s(7)) ?? .left, font: .init(rawValue: s(8)) ?? .system))
            case "image": shapes.append(.image(s(1), CGRect(x: d(2), y: d(3), width: d(4), height: d(5)), opacity: min(max(d(6), 0), 1),
                                               pixelate: min(max(d(7), 0), 500)))
            case "save": shapes.append(.save)
            case "restore": shapes.append(.restore)
            case "translate": shapes.append(.translate(d(1), d(2)))
            case "rotate": shapes.append(.rotate(d(1)))
            case "scale": shapes.append(.scale(d(1)))
            case "alpha": shapes.append(.alpha(min(max(d(1), 0), 1)))
            default: throw ShapeError(description: "unknown drawing command \(op)")
            }
        }
        return shapes
    }

    private static func describe(_ exception: JSValue?) -> String {
        guard let exception else { return "unknown error" }
        let message = exception.toString() ?? "unknown error"
        if exception.objectForKeyedSubscript("sourceURL")?.toString() == "main.js",
           let line = exception.objectForKeyedSubscript("line"), line.isNumber {
            return "\(message) (main.js line \(line.toInt32()))"
        }
        return message
    }

    // MARK: Time limit

    /// Stops any single call into the pack that runs longer than `callTimeLimit`, so a pack stuck in
    /// an endless loop can't freeze the app. JavaScriptCore has this ability but doesn't publish it
    /// in its headers, so it's looked up by name, and skipped if a future macOS doesn't have it.
    private static func limitExecutionTime(of context: JSContext) {
        typealias SetLimit = @convention(c) (JSContextGroupRef?, Double, UnsafeRawPointer?, UnsafeMutableRawPointer?) -> Void
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "JSContextGroupSetExecutionTimeLimit") else { return }
        let setLimit = unsafeBitCast(symbol, to: SetLimit.self)
        setLimit(JSContextGetGroup(context.jsGlobalContextRef), callTimeLimit, nil, nil)
    }
}

nonisolated extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
