import AppKit
import SwiftUI

/// Cleaning mode's settings.
@Observable
final class CleaningModeSettings {
    static let shared = CleaningModeSettings()

    /// Starts cleaning mode from anywhere.
    var shortcut: KeyShortcut? { didSet { UserDefaults.standard.set(try? JSONEncoder().encode(shortcut), forKey: "cleaning.shortcut") } }
    var registered = true

    init() {
        shortcut = UserDefaults.standard.data(forKey: "cleaning.shortcut")
            .flatMap { try? JSONDecoder().decode(KeyShortcut?.self, from: $0) } ?? nil
    }
}

/// Counts the unlock presses: Esc five times in a row, each within 1.5 s of the last. Any other
/// key starts over, and held-down repeats don't count.
nonisolated struct UnlockCounter {
    static let needed = 5
    static let gap: TimeInterval = 1.5

    private(set) var count = 0
    private var last: TimeInterval = 0

    /// Returns true when the fifth press lands.
    mutating func press(isEscape: Bool, isRepeat: Bool, at time: TimeInterval) -> Bool {
        guard !isRepeat else { return false }
        guard isEscape else { count = 0; return false }
        count = time - last <= Self.gap ? count + 1 : 1
        last = time
        return count >= Self.needed
    }
}

/// Cleaning mode: the keyboard and the trackpad (or mouse) do nothing, so you can wipe them.
/// Pressing Esc five times in a row ends it, and it ends by itself after five minutes so nobody is
/// ever stuck. It only starts if the input lock can be made (it needs Accessibility).
@Observable
final class CleaningMode {
    static let shared = CleaningMode()
    static let limit: TimeInterval = 5 * 60

    private(set) var isOn = false
    /// Esc presses so far (for the dots on the screen).
    private(set) var presses = 0
    private(set) var endsAt: Date?

    @ObservationIgnored private var counter = UnlockCounter()
    @ObservationIgnored private var tap: EventTap?
    @ObservationIgnored private var windows: [NSWindow] = []
    @ObservationIgnored private var timeout: Task<Void, Never>?

    /// Every kind of input event: keys (including the volume, brightness and media keys, which come
    /// as "system defined" events), clicks, movement, scrolling and trackpad gestures.
    private static let locked: [CGEventType] = [
        .keyDown, .keyUp, .flagsChanged,
        .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp,
        .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .scrollWheel,
    ] + [14, 29, 30, 31, 32, 33, 34].compactMap { CGEventType(rawValue: $0) }   // system defined, gestures

    func start() {
        guard !isOn else { return }
        guard Permissions.shared.isGranted(.accessibility) else {
            Permissions.shared.request(.accessibility)
            return
        }
        let tap = EventTap(Self.locked, location: .cghidEventTap) { [weak self] type, event in
            self?.handle(type, event)
        }
        // No lock without a way out: if the tap can't be made, nothing is locked.
        guard tap.start() else {
            CaptureToast.show("Cleaning mode couldn't start", symbol: "exclamationmark.triangle.fill",
                              detail: "Check Zephydian's Accessibility permission.")
            return
        }
        self.tap = tap
        counter = UnlockCounter()
        presses = 0
        isOn = true
        endsAt = Date().addingTimeInterval(Self.limit)
        timeout = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.limit))
            guard !Task.isCancelled else { return }
            self?.stop()
        }
        showOverlay()
    }

    func stop() {
        guard isOn else { return }
        isOn = false
        tap?.stop()
        tap = nil
        timeout?.cancel()
        timeout = nil
        endsAt = nil
        for window in windows { window.orderOut(nil) }
        windows = []
        CaptureToast.show("Cleaning mode is off", symbol: "keyboard")
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> CGEvent? {
        if type == .keyDown {
            let isEscape = event.getIntegerValueField(.keyboardEventKeycode) == 53
            let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            if counter.press(isEscape: isEscape, isRepeat: isRepeat, at: ProcessInfo.processInfo.systemUptime) {
                // After this event is swallowed, so the last Esc doesn't reach the app underneath.
                Task { @MainActor in self.stop() }
            }
            if presses != counter.count { presses = counter.count }
        }
        return nil
    }

    /// A calm full-screen card on every display, above everything.
    private func showOverlay() {
        let settings = Features.shared.appSettings ?? SettingsStore()
        windows = NSScreen.screens.map { screen in
            let window = NSWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.level = .screenSaver
            window.isOpaque = false
            window.backgroundColor = .clear
            window.ignoresMouseEvents = true
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: CleaningOverlay(mode: self).environment(settings))
            window.setFrame(screen.frame, display: false)
            window.orderFrontRegardless()
            return window
        }
    }
}

private struct CleaningOverlay: View {
    let mode: CleaningMode
    @Environment(SettingsStore.self) private var settings
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        ZStack {
            Rectangle().fill(.black.opacity(reduceTransparency ? 0.92 : 0.72))
            VStack(spacing: 18) {
                Image(systemName: "sparkles")
                    .font(.system(size: 54, weight: .light))
                    .foregroundStyle(settings.accentColor)
                Text("Cleaning Mode").font(.system(size: 34, weight: .semibold))
                Text("The keyboard and trackpad are locked. Wipe away.")
                    .font(.title3).foregroundStyle(.white.opacity(0.75))
                HStack(spacing: 10) {
                    ForEach(0..<UnlockCounter.needed, id: \.self) { i in
                        Circle()
                            .fill(i < mode.presses ? AnyShapeStyle(settings.accentColor) : AnyShapeStyle(.white.opacity(0.25)))
                            .frame(width: 12, height: 12)
                    }
                }
                .padding(.top, 8)
                .accessibilityLabel("\(mode.presses) of \(UnlockCounter.needed) presses")
                Text("Press Esc five times to unlock")
                    .font(.headline).foregroundStyle(.white.opacity(0.9))
                if let end = mode.endsAt {
                    Text("Unlocks by itself \(end, style: .relative)")
                        .font(.callout).monospacedDigit().foregroundStyle(.white.opacity(0.55))
                }
            }
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
        }
        .ignoresSafeArea()
    }
}

/// The feature: its shortcut, and the Start button on its page. Nothing runs until it's started.
final class CleaningModeEngine: FeatureEngine {
    private let settings = CleaningModeSettings.shared
    private let hotKey = GlobalHotKey(id: 704)
    private var running = false

    func start() {
        running = true
        hotKey.onPress = { CleaningMode.shared.start() }
        follow()
    }

    func stop() {
        running = false
        hotKey.unregister()
        CleaningMode.shared.stop()
    }

    private func follow() {
        guard running else { return }
        withObservationTracking { _ = settings.shortcut } onChange: { [weak self] in
            Task { @MainActor in self?.follow() }
        }
        settings.registered = hotKey.register(settings.shortcut)
    }
}

struct CleaningModeSettingsView: View {
    @State private var settings = CleaningModeSettings.shared
    @Environment(SettingsStore.self) private var appSettings

    var body: some View {
        Section {
            LabeledContent("Lock the keyboard and trackpad now") {
                Button("Start Cleaning Mode") { CleaningMode.shared.start() }
                    .prominentButtonStyle()
            }
            LabeledContent("Start cleaning mode") {
                ShortcutRecorder(shortcut: settings.shortcut) { settings.shortcut = $0 }
            }
            ShortcutWarning(text: ShortcutConflicts.warning(for: settings.shortcut, registered: settings.registered,
                                                            owner: "cleaning", panel: appSettings.panelShortcut))
        } footer: {
            Text("Every key, click, scroll and gesture is ignored, including the volume and brightness keys. Press Esc five times in a row to unlock. It also unlocks by itself after five minutes. It's on the Quick Panel and in the Command Bar too.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }
}
