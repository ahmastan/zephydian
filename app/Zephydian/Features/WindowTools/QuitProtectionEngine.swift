import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Quit and close protection: ⌘Q (and, if chosen, ⌘W) needs a second press within a second, a
/// hold, or an added ⌥, so a slip doesn't close an app. A small note on screen says what to do.
/// A keyboard tap watches for those two shortcuts only and lets everything else through.
final class QuitProtectionEngine: FeatureEngine {
    private let settings = WindowToolsSettings.shared
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private let note = ProtectionNote()
    /// The last first press, for "press twice".
    private var lastPress: (key: UInt16, pid: pid_t, at: Date)?
    /// A hold in progress.
    private var holding: (key: UInt16, task: Task<Void, Never>)?

    /// Marks the ⌘Q / ⌘W Zephydian sends itself, so the tap lets it through.
    private static let marker: Int64 = 0x7A657068   // "zeph"

    func start() {
        let types: [CGEventType] = [.keyDown, .keyUp]
        let mask = types.reduce(CGEventMask(0)) { $0 | CGEventMask(1 << $1.rawValue) }
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let engine = Unmanaged<QuitProtectionEngine>.fromOpaque(refcon).takeUnretainedValue()
            let swallow = MainActor.assumeIsolated { engine.handle(type, event) }
            return swallow ? nil : Unmanaged.passUnretained(event)
        }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: mask, callback: callback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return }
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = source
    }

    func stop() {
        holding?.task.cancel()
        holding = nil
        note.hide()
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            EventTap.noteDisabled(type)
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        }
        if event.getIntegerValueField(.eventSourceUserData) == Self.marker { return false }
        if ShortcutRecording.isActive { return false }
        let key = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        guard key == UInt16(kVK_ANSI_Q) || (key == UInt16(kVK_ANSI_W) && settings.protectClose) else { return false }

        if type == .keyUp {
            // Let go before the hold finished: nothing happens.
            if let holding, holding.key == key {
                holding.task.cancel()
                self.holding = nil
                note.hide()
                return true
            }
            return false
        }

        let flags = NSEvent.ModifierFlags(rawValue: UInt(event.flags.rawValue)).intersection(KeyShortcut.relevant)
        guard flags == .command || (settings.protection == .extraKey && flags == [.command, .option]),
              let app = NSWorkspace.shared.frontmostApplication, app.bundleIdentifier != "com.apple.finder",
              !(app.bundleIdentifier.map(settings.protectionIgnoredApps.contains) ?? false) else { return false }
        let repeated = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        let action = key == UInt16(kVK_ANSI_Q) ? "quit" : "close the window"
        let label = key == UInt16(kVK_ANSI_Q) ? "⌘Q" : "⌘W"

        switch settings.protection {
        case .twice:
            if repeated { return true }
            if let last = lastPress, last.key == key, last.pid == app.processIdentifier, Date().timeIntervalSince(last.at) < 1 {
                lastPress = nil
                note.hide()
                return false   // the second press goes through
            }
            lastPress = (key, app.processIdentifier, Date())
            note.show(app: app, text: "Press \(label) again to \(action)", progress: nil)
            note.hide(after: 1)
            return true
        case .hold:
            if repeated || holding != nil { return true }
            let started = Date()
            let task = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    let progress = min(1, Date().timeIntervalSince(started) / 0.6)
                    self?.note.show(app: app, text: "Keep holding \(label) to \(action)", progress: progress)
                    if progress >= 1 { break }
                    try? await Task.sleep(for: .milliseconds(30))
                }
                guard let self, !Task.isCancelled else { return }
                self.holding = nil
                self.note.hide()
                self.send(key, to: app)
            }
            holding = (key, task)
            return true
        case .extraKey:
            if flags == [.command, .option] {
                if !repeated { send(key, to: app) }
                return true
            }
            if !repeated {
                note.show(app: app, text: "Press ⌥\(label) to \(action)", progress: nil)
                note.hide(after: 1.2)
            }
            return true
        }
    }

    /// Does what the shortcut would have done: quits the app, or sends ⌘W to it.
    private func send(_ key: UInt16, to app: NSRunningApplication) {
        if key == UInt16(kVK_ANSI_Q) {
            app.terminate()
            return
        }
        let source = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(key), keyDown: down) else { continue }
            event.flags = .maskCommand
            event.setIntegerValueField(.eventSourceUserData, value: Self.marker)
            event.postToPid(app.processIdentifier)
        }
    }
}

/// The little note in the lower middle of the screen ("Press ⌘Q again to quit"), with a ring that
/// fills while a hold is in progress.
private final class ProtectionNote {
    @Observable final class Model {
        var app: NSRunningApplication?
        var text = ""
        var progress: Double?
    }

    private let model = Model()
    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?

    func show(app: NSRunningApplication, text: String, progress: Double?) {
        hideTask?.cancel()
        model.app = app
        model.text = text
        model.progress = progress
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let size = NSSize(width: 360, height: 56)
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main ?? NSScreen.screens[0]
        panel.setFrame(CGRect(x: screen.visibleFrame.midX - size.width / 2, y: screen.visibleFrame.minY + 80,
                              width: size.width, height: size.height), display: true)
        panel.orderFrontRegardless()
    }

    func hide(after seconds: Double) {
        hideTask?.cancel()
        hideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }

    func hide() {
        hideTask?.cancel()
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: NoteView(model: model)
            .environment(Features.shared.appSettings ?? SettingsStore()))
        return panel
    }

    private struct NoteView: View {
        let model: Model
        @Environment(SettingsStore.self) private var settings

        var body: some View {
            HStack(spacing: 10) {
                if let icon = model.app?.icon {
                    Image(nsImage: icon).resizable().frame(width: 26, height: 26).accessibilityHidden(true)
                }
                Text(model.text).font(.system(size: 13, weight: .medium)).lineLimit(1)
                if let progress = model.progress {
                    ZStack {
                        Circle().stroke(.secondary.opacity(0.3), lineWidth: 3)
                        Circle().trim(from: 0, to: progress).stroke(settings.accentColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                    }
                    .frame(width: 18, height: 18)
                    .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 44)
            .glassSurface(in: Capsule(), fallback: .regularMaterial)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
