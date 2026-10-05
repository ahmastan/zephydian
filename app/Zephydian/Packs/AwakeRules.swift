import AppKit
import IOKit.ps
import IOKit.pwr_mgt

/// Keep-awake rules (SDK 8, `power.awake`): the Mac stays awake by itself while chosen apps are
/// open, while it's on power, or while an external display is connected. Saved per utility and
/// watched natively (app launches and quits, power source changes, display changes), so they work
/// with the panel closed. Nothing is watched while no rule is set.
final class AwakeRules {
    struct Rules: Codable, Equatable {
        var apps: [String] = []          // bundle ids
        var onPower = false
        var externalDisplay = false
        /// Keep the display on too while a rule holds.
        var display = false

        var isEmpty: Bool { apps.isEmpty && !onPower && !externalDisplay }
    }

    private unowned let services: PackServices
    private var rules: [String: Rules] = [:]                         // pack id → rules
    private var held: [String: (assertion: IOPMAssertionID, reason: String)] = [:]
    private var observers: [NSObjectProtocol] = []
    private var powerSource: CFRunLoopSource?

    init(services: PackServices) { self.services = services }

    private func key(_ packID: String) -> String { "awake.rules.\(packID)" }

    func rules(for packID: String) -> Rules {
        if let r = rules[packID] { return r }
        return services.defaults.data(forKey: key(packID)).flatMap { try? JSONDecoder().decode(Rules.self, from: $0) } ?? Rules()
    }

    func set(_ new: Rules, for packID: String, packName: String) {
        rules[packID] = new
        services.defaults.set(try? JSONEncoder().encode(new), forKey: key(packID))
        names[packID] = packName
        watch()
        evaluate()
    }

    /// Why a rule is keeping the Mac awake right now ("Safari is open"), or nil.
    func activeReason(for packID: String) -> String? { held[packID]?.reason }

    /// At launch.
    func restore(packID: String, packName: String) {
        let r = rules(for: packID)
        guard !r.isEmpty else { return }
        rules[packID] = r
        names[packID] = packName
        watch()
        evaluate()
    }

    func remove(packID: String) {
        release(packID)
        rules[packID] = nil
        names[packID] = nil
        services.defaults.removeObject(forKey: key(packID))
        watch()
    }

    private var names: [String: String] = [:]

    // MARK: Watching

    /// Watches only what the current rules need.
    private func watch() {
        let all = rules.values
        let needsApps = all.contains { !$0.apps.isEmpty }
        let needsPower = all.contains(where: \.onPower)
        let needsDisplays = all.contains(where: \.externalDisplay)

        for observer in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            NotificationCenter.default.removeObserver(observer)
        }
        observers = []
        if needsApps {
            let center = NSWorkspace.shared.notificationCenter
            for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
                observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.evaluate() }
                })
            }
        }
        if needsDisplays {
            observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.evaluate() }
            })
        }
        if needsPower, powerSource == nil {
            let context = Unmanaged.passUnretained(self).toOpaque()
            if let source = IOPSNotificationCreateRunLoopSource({ context in
                guard let context else { return }
                let rules = Unmanaged<AwakeRules>.fromOpaque(context).takeUnretainedValue()
                MainActor.assumeIsolated { rules.evaluate() }
            }, context)?.takeRetainedValue() {
                CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
                powerSource = source
            }
        } else if !needsPower, let source = powerSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            powerSource = nil
        }
    }

    // MARK: Deciding

    private func evaluate() {
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        let onPower = (IOPSGetProvidingPowerSourceType(IOPSCopyPowerSourcesInfo()?.takeRetainedValue())?.takeUnretainedValue() as String?)
            == kIOPMACPowerKey
        let external = NSScreen.screens.contains { screen in
            guard let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value else { return false }
            return CGDisplayIsBuiltin(id) == 0
        }
        for (packID, r) in rules {
            var reason: String?
            if let app = r.apps.first(where: running.contains) {
                reason = "\(AppNames.name(app)) is open"
            } else if r.onPower, onPower {
                reason = "The Mac is on power"
            } else if r.externalDisplay, external {
                reason = "An external display is connected"
            }
            if let reason { hold(packID, reason: reason, display: r.display) } else { release(packID) }
        }
        services.changed()
    }

    private func hold(_ packID: String, reason: String, display: Bool) {
        if let current = held[packID] {
            guard current.reason != reason else { return }
            held[packID]?.reason = reason
            services.update(packID: packID, kind: "awakeRule", detail: "On while \(reason.prefix(1).lowercased() + reason.dropFirst())")
            return
        }
        var assertion = IOPMAssertionID(0)
        let type = (display ? kIOPMAssertionTypePreventUserIdleDisplaySleep : kIOPMAssertionTypePreventUserIdleSystemSleep) as CFString
        guard IOPMAssertionCreateWithName(type, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                          "\(names[packID] ?? "Awake") (Zephydian): \(reason)" as CFString, &assertion) == kIOReturnSuccess else { return }
        held[packID] = (assertion, reason)
        services.started(PackServices.Running(packID: packID, packName: names[packID] ?? "Awake", kind: "awakeRule",
                                              detail: "On while \(reason.prefix(1).lowercased() + reason.dropFirst())")) { [weak self] in
            self?.release(packID, fromServices: true)
        }
    }

    private func release(_ packID: String, fromServices: Bool = false) {
        guard let state = held.removeValue(forKey: packID) else { return }
        IOPMAssertionRelease(state.assertion)
        if !fromServices { services.ended(packID: packID, kind: "awakeRule") }
    }
}
