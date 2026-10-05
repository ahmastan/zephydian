import AppKit
import CoreAudio
import SwiftUI

/// Headphones Safety: when headphones disconnect (Bluetooth, or unplugged from the headphone
/// jack) and sound falls back to the speakers, the speakers are muted, so whatever was playing
/// doesn't suddenly fill the room. Listens to macOS's output changes; nothing polls.
final class HeadphonesSafetyEngine: FeatureEngine {
    private var listeners: [AudioListener] = []
    private var wasHeadphones = false

    func start() {
        wasHeadphones = Self.headphonesInUse()
        listeners = [AudioListener(AudioSystem.system, AudioSystem.address(kAudioHardwarePropertyDefaultOutputDevice)) { [weak self] in
            self?.changed()
        }]
        watchJack()
    }

    func stop() { listeners = [] }

    /// The built-in output's data source changes when something is plugged into the jack.
    private func watchJack() {
        for output in AudioSystem.outputs() where output.isBuiltIn {
            listeners.append(AudioListener(output.id, AudioSystem.address(kAudioDevicePropertyDataSource, kAudioDevicePropertyScopeOutput)) { [weak self] in
                self?.changed()
            })
        }
    }

    private func changed() {
        let now = Self.headphonesInUse()
        defer { wasHeadphones = now }
        guard wasHeadphones, !now, let speakers = AudioSystem.defaultOutput else { return }
        AudioSystem.setMuted(speakers, true)
        CaptureToast.show("Speakers muted", symbol: "speaker.slash.fill", detail: "Your headphones disconnected. Turn the volume up to unmute.")
    }

    /// Whether sound is going to headphones: a Bluetooth output, the headphone jack, or a USB headset.
    static func headphonesInUse() -> Bool {
        guard let id = AudioSystem.defaultOutput, let output = AudioSystem.outputs().first(where: { $0.id == id }) else { return false }
        if output.isBluetooth { return true }
        if output.isBuiltIn { return AudioSystem.builtInHeadphonesPlugged(id) }
        let name = output.name.lowercased()
        return output.transport == kAudioDeviceTransportTypeUSB && (name.contains("headphone") || name.contains("headset"))
    }
}

struct HeadphonesSafetySettingsView: View {
    var body: some View {
        Section {
            Text("When headphones or AirPods disconnect and sound moves to the speakers, the speakers are muted. Turn the volume up (or press a volume key) to unmute.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }
}

/// Music Blocker: stops the Music app from opening by itself (pressing play with nothing playing,
/// connecting headphones). Holding ⌥ while opening Music lets it open.
final class MusicBlockerEngine: FeatureEngine {
    private var observer: NSObjectProtocol?
    static let musicID = "com.apple.Music"

    func start() {
        observer = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let pid = app?.processIdentifier
            let bundleID = app?.bundleIdentifier
            MainActor.assumeIsolated {
                guard bundleID == Self.musicID, let pid, !NSEvent.modifierFlags.contains(.option),
                      let music = NSRunningApplication(processIdentifier: pid) else { return }
                music.forceTerminate()
                CaptureToast.show("Music was kept from opening", symbol: "music.note", detail: "Hold ⌥ while opening Music to use it.")
            }
        }
    }

    func stop() {
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observer = nil
    }
}

struct MusicBlockerSettingsView: View {
    var body: some View {
        Section {
            Text("Music no longer opens by itself when you press play or connect headphones. To open it on purpose, hold ⌥ while you open it, or switch this off.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }
}
