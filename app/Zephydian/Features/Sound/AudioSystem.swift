import AppKit
import AudioToolbox
import CoreAudio

/// A sound output: speakers, headphones, a display, AirPlay.
nonisolated struct AudioOutput: Identifiable, Hashable, Sendable {
    let id: AudioObjectID
    let uid: String
    let name: String
    let transport: UInt32

    var isBluetooth: Bool { transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE }
    var isBuiltIn: Bool { transport == kAudioDeviceTransportTypeBuiltIn }

    var symbol: String {
        if isBluetooth { return "headphones" }
        if isBuiltIn { return AudioSystem.builtInHeadphonesPlugged(id) ? "headphones" : "laptopcomputer" }
        switch transport {
        case kAudioDeviceTransportTypeAirPlay: return "airplayaudio"
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: return "display"
        case kAudioDeviceTransportTypeUSB: return "hifispeaker"
        default: return "speaker.wave.2"
        }
    }
}

/// An app that's playing sound, with every audio process that belongs to it (browsers play from
/// helper processes; those count toward the app that's responsible for them).
nonisolated struct AudioApp: Identifiable, Hashable, Sendable {
    var id: String { bundleID }
    let bundleID: String
    let name: String
    let pid: pid_t
    var processes: [AudioObjectID]
}

/// Small readers and writers for Core Audio. All of them are quick, but some (switching outputs)
/// can take a moment, so call those off the main thread when it matters.
nonisolated enum AudioSystem {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    static func address(_ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                        _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    static func get<T: BitwiseCopyable>(_ id: AudioObjectID, _ where_: AudioObjectPropertyAddress, _ initial: T) -> T? {
        var a = where_, value = initial
        var size = UInt32(MemoryLayout<T>.size)
        guard AudioObjectHasProperty(id, &a), AudioObjectGetPropertyData(id, &a, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    @discardableResult
    static func set<T: BitwiseCopyable>(_ id: AudioObjectID, _ where_: AudioObjectPropertyAddress, _ value: T) -> Bool {
        var a = where_, v = value
        var settable: DarwinBoolean = false
        guard AudioObjectHasProperty(id, &a), AudioObjectIsPropertySettable(id, &a, &settable) == noErr, settable.boolValue else { return false }
        return AudioObjectSetPropertyData(id, &a, 0, nil, UInt32(MemoryLayout<T>.size), &v) == noErr
    }

    static func list(_ id: AudioObjectID, _ where_: AudioObjectPropertyAddress) -> [AudioObjectID] {
        var a = where_
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &a, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var a = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectHasProperty(id, &a), AudioObjectGetPropertyData(id, &a, 0, nil, &size, &value) == noErr,
              let text = value?.takeRetainedValue() else { return nil }
        return text as String
    }

    // MARK: Outputs

    /// Every device that can play sound (Zephydian's own private routing devices aren't listed by macOS).
    static func outputs() -> [AudioOutput] {
        list(system, address(kAudioHardwarePropertyDevices)).compactMap { id in
            guard !list(id, address(kAudioDevicePropertyStreams, kAudioDevicePropertyScopeOutput)).isEmpty,
                  let uid = string(id, kAudioDevicePropertyDeviceUID), let name = string(id, kAudioObjectPropertyName) else { return nil }
            let transport = get(id, address(kAudioDevicePropertyTransportType), UInt32(0)) ?? 0
            guard transport != kAudioDeviceTransportTypeAggregate || !name.hasPrefix("Zephydian") else { return nil }
            return AudioOutput(id: id, uid: uid, name: name, transport: transport)
        }
    }

    static var defaultOutput: AudioObjectID? {
        Self.get(system, address(kAudioHardwarePropertyDefaultOutputDevice), AudioObjectID(0)).flatMap { $0 == 0 ? nil : $0 }
    }

    static func setDefaultOutput(_ id: AudioObjectID) {
        set(system, address(kAudioHardwarePropertyDefaultOutputDevice), id)
        set(system, address(kAudioHardwarePropertyDefaultSystemOutputDevice), id)   // alerts follow too
    }

    static func output(uid: String) -> AudioOutput? { outputs().first { $0.uid == uid } }

    /// Whether something is plugged into the Mac's own headphone jack.
    static func builtInHeadphonesPlugged(_ id: AudioObjectID) -> Bool {
        get(id, address(kAudioDevicePropertyDataSource, kAudioDevicePropertyScopeOutput), UInt32(0)) == 0x6864_706E   // 'hdpn'
    }

    // MARK: Volume

    private static let mainVolume = AudioObjectPropertySelector(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)

    /// The output's volume, 0…1 (the same as the Mac's volume keys change).
    static func volume(_ id: AudioObjectID) -> Float? {
        get(id, address(mainVolume, kAudioDevicePropertyScopeOutput), Float32(0))
    }

    static func setVolume(_ id: AudioObjectID, _ value: Float) {
        if !set(id, address(mainVolume, kAudioDevicePropertyScopeOutput), Float32(min(max(value, 0), 1))) {
            for element: AudioObjectPropertyElement in [1, 2] {
                set(id, address(kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyScopeOutput, element), Float32(min(max(value, 0), 1)))
            }
        }
        if value > 0 { setMuted(id, false) }
    }

    static func isMuted(_ id: AudioObjectID) -> Bool {
        (get(id, address(kAudioDevicePropertyMute, kAudioDevicePropertyScopeOutput), UInt32(0)) ?? 0) != 0
    }

    static func setMuted(_ id: AudioObjectID, _ muted: Bool) {
        if !set(id, address(kAudioDevicePropertyMute, kAudioDevicePropertyScopeOutput), UInt32(muted ? 1 : 0)), muted {
            set(id, address(mainVolume, kAudioDevicePropertyScopeOutput), Float32(0))
        }
    }

    // MARK: Apps

    private typealias Responsible = @convention(c) (pid_t) -> pid_t
    private static let responsible: Responsible? = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid")
        .map { unsafeBitCast($0, to: Responsible.self) }

    /// Apps with audio processes; `playingOnly`: only those making sound right now.
    static func apps(playingOnly: Bool) -> [AudioApp] {
        var byApp: [String: AudioApp] = [:]
        var playing: Set<String> = []
        let own = ProcessInfo.processInfo.processIdentifier
        for process in list(system, address(kAudioHardwarePropertyProcessObjectList)) {
            guard let pid = get(process, address(kAudioProcessPropertyPID), pid_t(0)), pid > 0, pid != own else { continue }
            let owner = responsible?(pid) ?? pid
            guard let app = NSRunningApplication(processIdentifier: owner > 0 ? owner : pid) ?? NSRunningApplication(processIdentifier: pid),
                  let bundleID = app.bundleIdentifier, app.processIdentifier != own,
                  bundleID != "com.ahmastan.zephydian" else { continue }   // any copy of Zephydian (its own sounds)
            if (get(process, address(kAudioProcessPropertyIsRunningOutput), UInt32(0)) ?? 0) != 0 { playing.insert(bundleID) }
            byApp[bundleID, default: AudioApp(bundleID: bundleID, name: app.localizedName ?? bundleID, pid: app.processIdentifier, processes: [])]
                .processes.append(process)
        }
        return byApp.values.filter { !playingOnly || playing.contains($0.bundleID) }.sorted { $0.name < $1.name }
    }
}

/// Calls `handler` on the main thread whenever a Core Audio property changes, until it's released.
nonisolated final class AudioListener: @unchecked Sendable {
    private let object: AudioObjectID
    private var address: AudioObjectPropertyAddress
    private let block: AudioObjectPropertyListenerBlock

    init(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress, handler: @escaping @MainActor @Sendable () -> Void) {
        self.object = object
        self.address = address
        block = { _, _ in Task { @MainActor in handler() } }
        AudioObjectAddPropertyListenerBlock(object, &self.address, DispatchQueue.main, block)
    }

    deinit {
        AudioObjectRemovePropertyListenerBlock(object, &address, DispatchQueue.main, block)
    }
}
