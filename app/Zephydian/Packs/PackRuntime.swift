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
    }
    enum Weight: String { case regular, medium, semibold, bold }
    enum Align: String { case left, center, right }
    enum Font: String { case system, rounded, mono }

    case clear(PackColor)
    case rect(CGRect, radius: Double, Style)
    case circle(CGPoint, radius: Double, Style)
    case line(CGPoint, CGPoint, color: PackColor, width: Double, round: Bool)
    case path([CGPoint], closed: Bool, Style)
    case text(String, CGPoint, size: Double, weight: Weight, color: PackColor, align: Align, font: Font)
    case image(String, CGRect, opacity: Double)
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
}

/// What the runtime tells the game screen.
protocol PackHost: AnyObject {
    func packDidDraw(_ shapes: [PackShape])
    func packScoreChanged(_ text: String)
    func packHintChanged(_ text: String)
    func packOverlayChanged(_ overlay: PackOverlay?)
    func packMenuChanged(_ menu: PackMenu?)
    func packToast(_ text: String)
    func packFailed(_ message: String)
}

// MARK: - Runtime

/// Runs one pack's main.js in its own JavaScriptCore context and exposes the SDK (`z`, `zephydian`).
/// Packs get nothing beyond what's defined here: JavaScriptCore has no network, files or timers.
/// All calls happen on the main thread.
final class PackRuntime {
    static let maxShapes = 20_000
    /// Longest a single call into the pack may run before it's stopped (an endless loop, say).
    static let callTimeLimit: Double = 1.0

    let bundle: PackBundle
    weak var host: PackHost?

    private let context: JSContext
    private var sdk: JSValue!            // the prelude's private entry points
    private let storage: PackStorage
    private let defaults: UserDefaults
    private(set) var failure: String?
    private(set) var isStarted = false
    private(set) var isPaused = false

    // Loop and timers
    private var loopInterval: Int?       // ms the pack asked for; nil = loop off
    private var ticker: Task<Void, Never>?
    private var timers: [Int: Task<Void, Never>] = [:]
    private var nextTimer = 1
    private var drawScheduled = false
    private var size = CGSize.zero

    var isLooping: Bool { ticker != nil }
    var bestScoreKey: String { "pack.\(bundle.id).best" }
    var bestTimeKey: String { "pack.\(bundle.id).bestTime" }

    /// Runs main.js right away. `host` is set first, so calls made while the script loads aren't lost.
    init(bundle: PackBundle, host: PackHost?, storage: PackStorage? = nil, defaults: UserDefaults = .standard) {
        self.bundle = bundle
        self.host = host
        self.storage = storage ?? PackStorage(packID: bundle.id)
        self.defaults = defaults
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
        if failure == nil, sdk.invokeMethod("hasGame", withArguments: []).toBool() == false {
            fail("main.js never called zephydian.game({ … })")
        }
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
    func pressOverlayButton(_ index: Int) { call("overlayPress", index) }
    func selectMenuItem(_ index: Int) { call("menuSelect", index) }

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
        return failure == nil ? result : nil
    }

    private func requestDraw() {
        guard !drawScheduled, failure == nil, isStarted else { return }
        drawScheduled = true
        Task { @MainActor [weak self] in self?.draw() }
    }

    private func draw() {
        drawScheduled = false
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
            MainActor.assumeIsolated { self?.storage.set(key, json: json) ?? false }
        } as @convention(block) (String, String) -> Bool)
        define("storageRemove", { [weak self] (key: String) in MainActor.assumeIsolated { self?.storage.remove(key) } } as @convention(block) (String) -> Void)
        define("storageClear", { [weak self] in MainActor.assumeIsolated { self?.storage.clear() } } as @convention(block) () -> Void)
        define("data", { [weak self] (name: String) -> Any in
            let text: String? = MainActor.assumeIsolated {
                self?.bundle.assetURL(name).flatMap { try? String(contentsOf: $0, encoding: .utf8) }
            }
            return text ?? NSNull()
        } as @convention(block) (String) -> Any)
        define("log", { [weak self] (s: String) in
            #if DEBUG
            MainActor.assumeIsolated { print("[\(self?.bundle.id ?? "pack")] \(s)") }
            #endif
        } as @convention(block) (String) -> Void)

        let setup = context.evaluateScript(Self.prelude, withSourceURL: URL(string: "zephydian-sdk.js"))
        guard let result = setup?.call(withArguments: [native]), failure == nil else { return }
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

    /// The SDK's JavaScript side. It checks and flattens what packs pass in, so Swift only sees plain values.
    private static let prelude = #"""
    (function (N) {
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
        line(x1, y1, x2, y2, o = {}) { this._p(["line", num(x1), num(y1), num(x2), num(y2), col(o.stroke) || "text", num(o.lineWidth) || 1, o.cap === "round" ? 1 : 0]); }
        path(points, o = {}) {
          const flat = [];
          for (const p of (Array.isArray(points) ? points : [])) flat.push(num(p && p[0]), num(p && p[1]));
          this._p(["path", flat, col(o.fill), col(o.stroke), num(o.lineWidth) || 1, o.closed ? 1 : 0]);
        }
        text(s, x, y, o = {}) {
          this._p(["text", String(s).slice(0, 500), num(x), num(y), num(o.size) || 13, String(o.weight || "regular"),
                   col(o.color) || "text", String(o.align || "left"), String(o.font || "system")]);
        }
        image(name, x, y, w, h, o = {}) { this._p(["image", String(name), num(x), num(y), num(w), num(h), o.opacity == null ? 1 : num(o.opacity)]); }
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
      };
      Object.seal(z);

      const zephydian = Object.freeze({
        game(g) {
          if (game) throw new Error("zephydian.game() was called twice");
          if (!g || typeof g !== "object") throw new TypeError("zephydian.game() needs an object");
          game = g;
        },
      });

      const sdk = {
        hasGame: () => game !== null,
        setTheme(t) { z.theme = Object.freeze(t); },
        start: () => { call("start"); },
        draw: () => { const g = new Draw(); call("draw", g); return g._c; },
        tick: dt => { call("tick", dt); },
        key: e => call("key", Object.freeze(e)) === true,
        keyUp: e => call("keyUp", Object.freeze(e)) === true,
        click: e => { call("click", Object.freeze(e)); },
        pause: () => { call("pause"); },
        resume: () => { call("resume"); },
        undo: () => call("undo") === true,
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
        ["key": e.key, "shift": e.shift, "option": e.option, "repeat": e.isRepeat]
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

    struct ShapeError: Error, CustomStringConvertible { let description: String }

    /// Turns the prelude's flat arrays into shapes, checking each one.
    static func parseShapes(_ list: JSValue) throws -> [PackShape] {
        guard let items = list.toArray() else { return [] }
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
            case "line": shapes.append(.line(CGPoint(x: d(1), y: d(2)), CGPoint(x: d(3), y: d(4)), color: c(5) ?? .theme("text"),
                                             width: max(0, d(6)), round: d(7) == 1))
            case "path":
                let flat = (item[safe: 1] as? [Any] ?? []).map { ($0 as? NSNumber)?.doubleValue ?? 0 }
                let points = stride(from: 0, to: flat.count - 1, by: 2).map { CGPoint(x: flat[$0], y: flat[$0 + 1]) }
                shapes.append(.path(points, closed: d(5) == 1, style(2)))
            case "text":
                shapes.append(.text(s(1), CGPoint(x: d(2), y: d(3)), size: min(max(d(4), 4), 200),
                                    weight: .init(rawValue: s(5)) ?? .regular, color: c(6) ?? .theme("text"),
                                    align: .init(rawValue: s(7)) ?? .left, font: .init(rawValue: s(8)) ?? .system))
            case "image": shapes.append(.image(s(1), CGRect(x: d(2), y: d(3), width: d(4), height: d(5)), opacity: min(max(d(6), 0), 1)))
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
