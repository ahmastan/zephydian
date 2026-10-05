import AppKit
import ApplicationServices

/// Quit on close: apps quit when their last window closes, except the ones kept open in Settings
/// (and Finder, which never quits). Each open app is watched through Accessibility's "window created"
/// and "closed" notifications (no polling).
final class QuitOnCloseEngine: FeatureEngine {
    private let settings = WindowToolsSettings.shared
    private var observers: [pid_t: AXObserver] = [:]
    private var launchObserver: NSObjectProtocol?
    private var quitObserver: NSObjectProtocol?
    private var running = false

    func start() {
        running = true
        launchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            // A moment later, so the new app's windows can be read.
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1))
                self?.sync()
            }
        }
        quitObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            MainActor.assumeIsolated { if let pid { self?.detach(pid) } }
        }
        follow()
    }

    func stop() {
        running = false
        if let launchObserver { NSWorkspace.shared.notificationCenter.removeObserver(launchObserver) }
        launchObserver = nil
        if let quitObserver { NSWorkspace.shared.notificationCenter.removeObserver(quitObserver) }
        quitObserver = nil
        for pid in observers.keys { detach(pid) }
    }

    /// Watches the chosen apps that are running, and follows changes to the list.
    private func follow() {
        guard running else { return }
        withObservationTracking {
            _ = settings.keepOpenApps
        } onChange: { [weak self] in
            Task { @MainActor in self?.follow() }
        }
        sync()
    }

    private func sync() {
        guard running else { return }
        let apps = NSWorkspace.shared.runningApplications.filter(applies)
        let wanted = Set(apps.map(\.processIdentifier))
        for pid in observers.keys where !wanted.contains(pid) { detach(pid) }
        for app in apps where observers[app.processIdentifier] == nil { attach(app) }
    }

    private func attach(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        var created: AXObserver?
        let callback: AXObserverCallback = { observer, element, notification, refcon in
            guard let refcon else { return }
            let engine = Unmanaged<QuitOnCloseEngine>.fromOpaque(refcon).takeUnretainedValue()
            let name = notification as String
            MainActor.assumeIsolated {
                var pid: pid_t = 0
                AXUIElementGetPid(element, &pid)
                if name == kAXWindowCreatedNotification {
                    // Watch the new window for its closing too.
                    AXObserverAddNotification(observer, element, kAXUIElementDestroyedNotification as CFString, refcon)
                } else {
                    engine.windowClosed(pid)
                }
            }
        }
        guard AXObserverCreate(pid, callback, &created) == .success, let observer = created else { return }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let appElement = AXUIElementCreateApplication(pid)
        AXObserverAddNotification(observer, appElement, kAXWindowCreatedNotification as CFString, refcon)
        for window in (SystemWindows.copy(appElement, kAXWindowsAttribute) as? [AXUIElement]) ?? [] {
            AXObserverAddNotification(observer, window, kAXUIElementDestroyedNotification as CFString, refcon)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        observers[pid] = observer
    }

    private func detach(_ pid: pid_t) {
        guard let observer = observers.removeValue(forKey: pid) else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
    }

    /// Every ordinary app, except Finder, Zephydian and the ones kept open.
    private func applies(_ app: NSRunningApplication) -> Bool {
        guard app.activationPolicy == .regular, !app.isTerminated,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let id = app.bundleIdentifier, id != "com.apple.finder" else { return false }
        return !settings.keepOpenApps.contains(id)
    }

    /// A window closed: if that was the app's last one (minimized ones count), it quits.
    private func windowClosed(_ pid: pid_t) {
        Task { @MainActor [weak self] in
            // Give the app a moment (a save sheet, the next window opening).
            try? await Task.sleep(for: .milliseconds(500))
            guard let self, self.running, let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated,
                  self.applies(app) else { return }
            if SystemWindows.windows(of: app, allSpaces: true).isEmpty {
                app.terminate()
                self.detach(pid)
            }
        }
    }
}
