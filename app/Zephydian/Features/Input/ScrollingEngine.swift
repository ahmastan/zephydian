import AppKit

/// Scrolling for mouse wheels: a smooth glide instead of jumps, or the same distance for every
/// notch, a direction separate from the trackpad's, and sideways scrolling with a held key.
/// Trackpads and the Magic Mouse (which already scroll smoothly) are never touched: only "line"
/// scrolls from wheel notches are changed.
final class ScrollingEngine: FeatureEngine {
    private let settings = InputSettings.shared
    private lazy var tap = EventTap([.scrollWheel]) { [weak self] _, event in self?.scrolled(event) ?? event }

    // The glide in progress, in pixels still to scroll.
    private var remaining = CGVector.zero
    private var glide: Timer?
    private var lastFrame = Date()

    func start() { tap.start() }

    func stop() {
        tap.stop()
        glide?.invalidate()
        glide = nil
        remaining = .zero
    }

    private func scrolled(_ event: CGEvent) -> CGEvent? {
        // Trackpads and the Magic Mouse send continuous (pixel) scrolling: leave them alone.
        guard event.getIntegerValueField(.scrollWheelEventIsContinuous) == 0, !settings.frontAppIgnoresMouse else { return event }
        var lines = (y: event.getIntegerValueField(.scrollWheelEventDeltaAxis1), x: event.getIntegerValueField(.scrollWheelEventDeltaAxis2))
        var points = (y: event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1), x: event.getDoubleValueField(.scrollWheelEventPointDeltaAxis2))

        // Sideways while a key is held (⇧ already does this in macOS).
        let flags = EventTap.modifiers(event)
        if settings.sidewaysKey != .shift, flags.contains(settings.sidewaysKey.flag), lines.x == 0 {
            lines = (0, lines.y)
            points = (0, points.y)
        }
        if settings.reverseMouseVertical { lines.y = -lines.y; points.y = -points.y }
        if settings.reverseMouseHorizontal { lines.x = -lines.x; points.x = -points.x }

        if settings.smoothScrolling {
            // A notch becomes a glide of about 30 points at medium speed (more when the wheel spins fast).
            func distance(_ line: Int64, _ point: Double) -> Double {
                guard line != 0 || point != 0 else { return 0 }
                let size = max(abs(point), Double(abs(line)) * 10) * 3 * settings.scrollSpeed
                return (line != 0 ? Double(line.signum()) : point.sign == .minus ? -1 : 1) * size
            }
            remaining.dy += distance(lines.y, points.y)
            remaining.dx += distance(lines.x, points.x)
            startGlide()
            return nil
        }
        if settings.linearScrolling {
            let step = Int64(settings.linearLines)
            lines = (lines.y.signum() * step, lines.x.signum() * step)
            points = (Double(lines.y) * 10, Double(lines.x) * 10)
        }
        event.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: lines.y)
        event.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: lines.x)
        event.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: points.y)
        event.setDoubleValueField(.scrollWheelEventPointDeltaAxis2, value: points.x)
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: Double(lines.y))
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: Double(lines.x))
        return event
    }

    /// Scrolls what's left a little each frame, slowing as it ends; the timer runs only during a glide.
    private func startGlide() {
        guard glide == nil else { return }
        lastFrame = Date()
        let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.frame() }
        }
        RunLoop.main.add(timer, forMode: .common)
        glide = timer
    }

    private func frame() {
        let now = Date()
        let dt = now.timeIntervalSince(lastFrame)
        lastFrame = now
        let tau = max(0.03, settings.scrollGlide / 3)
        let share = 1 - exp(-dt / tau)
        var step = CGVector(dx: remaining.dx * share, dy: remaining.dy * share)
        if abs(remaining.dx) < 1 && abs(remaining.dy) < 1 {
            step = remaining
            glide?.invalidate()
            glide = nil
        }
        let y = Int32(step.dy.rounded()), x = Int32(step.dx.rounded())
        remaining.dy -= Double(y)
        remaining.dx -= Double(x)
        if glide == nil { remaining = .zero }
        guard x != 0 || y != 0,
              let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: y, wheel2: x, wheel3: 0) else { return }
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        event.setIntegerValueField(.eventSourceUserData, value: EventTap.marker)
        event.post(tap: .cgSessionEventTap)
    }
}
