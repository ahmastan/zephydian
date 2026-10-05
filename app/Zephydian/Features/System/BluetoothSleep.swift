import AppKit
import SwiftUI

/// Bluetooth's power switch, through IOBluetooth's preference functions (what the Bluetooth menu uses).
nonisolated enum BluetoothPower {
    private typealias Get = @convention(c) () -> Int32
    private typealias Set = @convention(c) (Int32) -> Void

    private struct Calls: @unchecked Sendable {
        let get: Get
        let set: Set
    }

    private static let calls: Calls? = {
        guard let handle = dlopen("/System/Library/Frameworks/IOBluetooth.framework/IOBluetooth", RTLD_LAZY),
              let get = dlsym(handle, "IOBluetoothPreferenceGetControllerPowerState"),
              let set = dlsym(handle, "IOBluetoothPreferenceSetControllerPowerState") else { return nil }
        return Calls(get: unsafeBitCast(get, to: Get.self), set: unsafeBitCast(set, to: Set.self))
    }()

    static var isAvailable: Bool { calls != nil }
    static var isOn: Bool { (calls?.get() ?? 0) != 0 }
    static func set(_ on: Bool) { calls?.set(on ? 1 : 0) }
}

/// Bluetooth Off in Sleep: switches Bluetooth off as the Mac goes to sleep and back on when it
/// wakes, so headphones and speakers connect to your phone instead of a sleeping Mac. Only turns
/// Bluetooth back on if it was this feature that turned it off.
final class BluetoothSleepEngine: FeatureEngine {
    private var observers: [NSObjectProtocol] = []
    private static let key = "bluetoothSleep.turnedOff"

    func start() {
        let center = NSWorkspace.shared.notificationCenter
        observers = [
            center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated {
                    guard BluetoothPower.isOn else { return }
                    UserDefaults.standard.set(true, forKey: Self.key)
                    BluetoothPower.set(false)
                }
            },
            center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { Self.restore() }
            },
        ]
        Self.restore()   // in case Zephydian quit while the Mac slept
    }

    func stop() {
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observers = []
        Self.restore()
    }

    private static func restore() {
        guard UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.removeObject(forKey: key)
        BluetoothPower.set(true)
    }
}

struct BluetoothSleepSettingsView: View {
    var body: some View {
        Section {
            Text(BluetoothPower.isAvailable
                 ? "Bluetooth switches off when the Mac sleeps and back on when it wakes, so your headphones connect to your phone instead. If Bluetooth was already off, it's left off. A Bluetooth keyboard, mouse or trackpad can't wake the Mac while this is on; use the Mac's own keyboard or power button."
                 : "This Mac's Bluetooth can't be switched from here.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }
}
