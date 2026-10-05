import AppKit
import ApplicationServices
import AVFoundation
import CoreGraphics
import SwitcherKit

/// A macOS privacy permission that Zephydian's features can use. Each is asked for only when a
/// feature that needs it is used or switched on, never up front.
enum Permission: String, CaseIterable, Identifiable {
    case accessibility, screenRecording, microphone, camera

    var id: String { rawValue }

    var title: String {
        switch self {
        case .accessibility: "Accessibility"
        case .screenRecording: "Screen Recording"
        case .microphone: "Microphone"
        case .camera: "Camera"
        }
    }

    /// What it allows, in plain words.
    var explanation: String {
        switch self {
        case .accessibility: "See and arrange other apps' windows, and react to shortcuts like ⌘Tab."
        case .screenRecording: "Take screenshots, record the screen and show live window previews."
        case .microphone: "Record your voice with a screen recording, when you switch it on."
        case .camera: "Show your camera in the Camera Mirror."
        }
    }

    var symbol: String {
        switch self {
        case .accessibility: "accessibility"
        case .screenRecording: "rectangle.dashed.badge.record"
        case .microphone: "mic.fill"
        case .camera: "camera.fill"
        }
    }

    /// The service name `tccutil` uses.
    fileprivate var tccService: String {
        switch self {
        case .accessibility: "Accessibility"
        case .screenRecording: "ScreenCapture"
        case .microphone: "Microphone"
        case .camera: "Camera"
        }
    }

    fileprivate var settingsURL: URL? {
        switch self {
        case .accessibility: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        case .screenRecording: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
        case .microphone: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
        case .camera: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")
        }
    }
}

/// Which permissions Zephydian has, kept current without polling: macOS announces Accessibility
/// changes, and everything is re-read when Zephydian becomes active or its panel opens.
@Observable
final class Permissions {
    static let shared = Permissions()

    private(set) var granted: Set<Permission> = []
    /// Set while a repair runs, so its button can show progress.
    private(set) var repairing: Permission?

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        refresh()
        // Posted by macOS whenever the Accessibility list changes; the new state can lag a moment.
        observers.append(DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.accessibility.api"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(400))
                self?.refresh()
            }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        })
    }

    func isGranted(_ permission: Permission) -> Bool { granted.contains(permission) }

    /// Re-reads every permission. Cheap: two quick system calls.
    func refresh() {
        var now: Set<Permission> = []
        if AXIsProcessTrusted() { now.insert(.accessibility) }
        if CGPreflightScreenCaptureAccess() { now.insert(.screenRecording) }
        if AVCaptureDevice.authorizationStatus(for: .audio) == .authorized { now.insert(.microphone) }
        if AVCaptureDevice.authorizationStatus(for: .video) == .authorized { now.insert(.camera) }
        for permission in now { defaults.set(true, forKey: everKey(permission)) }
        if now != granted { granted = now }
        SwitcherKit.setPermissions(accessibility: now.contains(.accessibility), screenRecording: now.contains(.screenRecording))
    }

    /// Granted before but not now. Usually macOS still lists Zephydian as allowed, but for an
    /// earlier build: its permissions belong to one exact build until the app is signed.
    func looksStuck(_ permission: Permission) -> Bool {
        !isGranted(permission) && defaults.bool(forKey: everKey(permission))
    }

    /// Shows macOS's own prompt (which has its own Open System Settings button). Only when macOS
    /// won't show it any more does this open the right pane of System Settings itself.
    func request(_ permission: Permission) {
        let prompted: Bool
        switch permission {
        case .accessibility:
            // macOS shows its prompt every time it's asked while Zephydian isn't allowed.
            // (The return value is "already allowed", not "a prompt was shown".)
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            prompted = !AXIsProcessTrustedWithOptions(options)
        case .screenRecording:
            // macOS shows this prompt only once per build; after that it stays quiet.
            prompted = !defaults.bool(forKey: askedKey(permission))
            defaults.set(true, forKey: askedKey(permission))
            _ = CGRequestScreenCaptureAccess()
        case .microphone, .camera:
            let media: AVMediaType = permission == .camera ? .video : .audio
            // macOS asks once; after that (allowed or not) System Settings is where it's changed.
            prompted = AVCaptureDevice.authorizationStatus(for: media) == .notDetermined
            if prompted {
                AVCaptureDevice.requestAccess(for: media) { _ in
                    Task { @MainActor in Permissions.shared.refresh() }
                }
            }
        }
        if !prompted { openSettings(permission) }
        refresh()
    }

    func openSettings(_ permission: Permission) {
        if let url = permission.settingsURL { NSWorkspace.shared.open(url) }
    }

    /// Clears Zephydian's entry in macOS's privacy list (the stale one), then asks again.
    func repair(_ permission: Permission) {
        guard repairing == nil else { return }
        repairing = permission
        let bundleID = Bundle.main.bundleIdentifier ?? "com.ahmastan.zephydian"
        let service = permission.tccService
        Task.detached {
            let process = Process()
            process.executableURL = URL(filePath: "/usr/bin/tccutil")
            process.arguments = ["reset", service, bundleID]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try? process.run()
            process.waitUntilExit()
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.repairing = nil
                self.defaults.removeObject(forKey: self.everKey(permission))
                self.defaults.removeObject(forKey: self.askedKey(permission))
                self.request(permission)
            }
        }
    }

    private func everKey(_ permission: Permission) -> String { "permissions.\(permission.rawValue).everGranted" }
    /// Per build: until the app is signed, every new build is a new app to macOS and gets asked again.
    private func askedKey(_ permission: Permission) -> String {
        let built = Bundle.main.executableURL
            .flatMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
            .map { Int($0.timeIntervalSince1970) } ?? 0
        return "permissions.\(permission.rawValue).asked.\(built)"
    }
}
