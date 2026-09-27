import AppKit

/// Reports mouse movement over other apps (global monitor) and over Zephydian (local monitor).
/// Only runs while the panel is open, for auto-hide. The corner itself is detected by
/// `CornerTrigger`'s sensor window, which costs nothing while the mouse is elsewhere.
final class MouseMonitor {
    var onMove: (NSPoint) -> Void = { _ in }
    private var globalMonitor: Any?
    private var localMonitor: Any?

    func start() {
        guard globalMonitor == nil else { return }
        // Always read the real pointer position. An event's own location can be relative to
        // another app's window (macOS sends mouse moves to the app you were using, even while
        // the pointer is over Zephydian's panel), which would make auto-hide misfire.
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
            self?.onMove(NSEvent.mouseLocation)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
            self?.onMove(NSEvent.mouseLocation)
            return event
        }
    }

    func stop() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
    }
}

/// Fires `onTrigger` when the pointer rests in the chosen screen corner for the dwell delay.
///
/// How: a light timer asks macOS where the pointer is (each check takes ~3 µs), 10× per second,
/// speeding up to ~30× per second when the pointer is near the corner so the trigger feels instant.
/// This doesn't depend on any window being under the pointer, so it works over the menu bar,
/// full-screen apps and every Space, and it never interferes with clicks.
/// (Earlier designs were a global mouse monitor, which woke the app on every mouse movement,
/// and an invisible corner window, which macOS didn't always route the pointer to.)
final class CornerTrigger: NSObject {
    private let settings: SettingsStore
    private let onTrigger: () -> Void
    private var timer: Timer?
    private var fast = false
    private var inCorner = false
    private var dwellTask: Task<Void, Never>?
    /// The corner square (cached; recomputed when the corner, display or screens change).
    private var zone: NSRect?

    /// How close (in points) to the exact corner counts as "in the corner".
    private static let slop: CGFloat = 4
    /// Within this distance of the corner, check more often.
    private static let nearDistance: CGFloat = 200

    init(settings: SettingsStore, onTrigger: @escaping () -> Void) {
        self.settings = settings
        self.onTrigger = onTrigger
        super.init()
        NotificationCenter.default.addObserver(
            self, selector: #selector(reposition),
            name: NSApplication.didChangeScreenParametersNotification, object: nil
        )
        schedule(fast: false)
    }

    /// Call after the corner, display or screen layout changes.
    @objc func reposition() { zone = nil }

    private func schedule(fast: Bool) {
        self.fast = fast
        timer?.invalidate()
        let interval = fast ? 0.03 : 0.1
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        timer.tolerance = interval * 0.2 // lets macOS batch wake-ups with other work to save energy
        RunLoop.main.add(timer, forMode: .common) // keeps running while menus are open
        self.timer = timer
    }

    private func check() {
        let point = NSEvent.mouseLocation
        let zone = currentZone()

        let near = zone.insetBy(dx: -Self.nearDistance, dy: -Self.nearDistance).contains(point)
        if near != fast { schedule(fast: near) }

        let nowInCorner = zone.contains(point)
        guard nowInCorner != inCorner else { return }
        inCorner = nowInCorner
        dwellTask?.cancel()
        guard nowInCorner else { return }

        let delay = settings.dwellMs
        dwellTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(delay))
            guard let self, !Task.isCancelled, self.inCorner else { return }
            self.onTrigger()
        }
    }

    private func currentZone() -> NSRect {
        if let zone { return zone }
        guard let frame = settings.targetScreen?.frame else { return .zero }
        let size = Self.slop + 1
        let x = settings.corner.isLeft ? frame.minX - 1 : frame.maxX - size
        let y = settings.corner.isTop ? frame.maxY - size : frame.minY - 1
        let rect = NSRect(x: x, y: y, width: size + 1, height: size + 1)
        zone = rect
        return rect
    }
}
