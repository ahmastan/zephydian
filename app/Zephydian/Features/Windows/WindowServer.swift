import AppKit
import ApplicationServices

/// macOS functions Apple doesn't document, which window tools (Dock previews, app switchers) rely
/// on because there's no public way to do these things. Each is looked up at runtime: if a future
/// macOS removes one, that one ability quietly stops (the caller falls back), and the app still runs.
nonisolated enum WindowServer {
    nonisolated(unsafe) private static let handle: UnsafeMutableRawPointer? = {
        _ = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
        return dlopen(nil, RTLD_NOW)
    }()

    private static func symbol<T>(_ name: String, as type: T.Type) -> T? {
        guard let handle, let pointer = dlsym(handle, name) else { return nil }
        return unsafeBitCast(pointer, to: type)
    }

    // MARK: Window ids

    private typealias AXGetWindow = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
    private static let axGetWindow = symbol("_AXUIElementGetWindow", as: AXGetWindow.self)

    /// The window server's id for an Accessibility window (what thumbnails and Spaces use).
    static func windowID(of element: AXUIElement) -> CGWindowID? {
        var id: CGWindowID = 0
        guard let axGetWindow, axGetWindow(element, &id) == .success, id != 0 else { return nil }
        return id
    }

    // MARK: Spaces

    private typealias MainConnection = @convention(c) () -> Int32
    private typealias CopySpacesForWindows = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?
    private typealias GetActiveSpace = @convention(c) (Int32) -> UInt64
    private static let mainConnection = symbol("CGSMainConnectionID", as: MainConnection.self)
    private static let copySpaces = symbol("CGSCopySpacesForWindows", as: CopySpacesForWindows.self)
    private static let getActiveSpace = symbol("CGSGetActiveSpace", as: GetActiveSpace.self)

    /// The Spaces (desktops) a window belongs to; empty for a leftover surface that isn't a real window.
    /// nil if macOS no longer offers this.
    static func spaces(of window: CGWindowID) -> [UInt64]? {
        guard let mainConnection, let copySpaces else { return nil }
        let ids = [NSNumber(value: window)] as CFArray
        // 7: every kind of Space (the user's desktops, full-screen apps, system ones).
        guard let result = copySpaces(mainConnection(), 7, ids)?.takeRetainedValue() as? [NSNumber] else { return nil }
        return result.map(\.uint64Value)
    }

    /// The desktop the person is looking at (on the main display).
    static var activeSpace: UInt64? {
        guard let mainConnection, let getActiveSpace else { return nil }
        let space = getActiveSpace(mainConnection())
        return space == 0 ? nil : space
    }

    // MARK: Bringing one exact window forward

    private typealias GetProcessForPID = @convention(c) (pid_t, UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus
    private typealias SetFrontProcess = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, CGWindowID, UInt32) -> CGError
    private typealias PostEventRecord = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UnsafeMutablePointer<UInt8>) -> CGError
    private static let getProcessForPID = symbol("GetProcessForPID", as: GetProcessForPID.self)
    private static let setFrontProcess = symbol("_SLPSSetFrontProcessWithOptions", as: SetFrontProcess.self)
    private static let postEventRecord = symbol("SLPSPostEventRecordTo", as: PostEventRecord.self)

    /// Makes `window` the front window of its app and the app frontmost, travelling to the window's
    /// desktop if it's on another one. With window 0, just brings the app to the front.
    /// False if macOS no longer offers this (use Accessibility then).
    @discardableResult
    static func bringForward(pid: pid_t, window: CGWindowID) -> Bool {
        guard let getProcessForPID, let setFrontProcess, let postEventRecord else { return false }
        var psn = ProcessSerialNumber()
        guard getProcessForPID(pid, &psn) == noErr else { return false }
        // 0x200: "user generated", so macOS switches Spaces like a click in the Dock would.
        guard setFrontProcess(&psn, window, 0x200) == .success else { return false }
        guard window != 0 else { return true }
        // Then tell the window server this window is key: the same event record that window
        // managers such as yabai post (a 0xf8-byte record holding the window id).
        var record = [UInt8](repeating: 0, count: 0xf8)
        record[0x04] = 0xf8
        record[0x3a] = 0x10
        withUnsafeBytes(of: window) { bytes in
            for (i, byte) in bytes.enumerated() { record[0x3c + i] = byte }
        }
        for i in 0x20..<0x30 { record[i] = 0xff }
        record[0x08] = 0x01
        _ = postEventRecord(&psn, &record)
        record[0x08] = 0x02
        _ = postEventRecord(&psn, &record)
        return true
    }

    // MARK: The Dock's auto-hide

    private typealias GetAutoHide = @convention(c) () -> Bool
    private typealias SetAutoHide = @convention(c) (Bool) -> Void
    private static let getAutoHide = symbol("CoreDockGetAutoHideEnabled", as: GetAutoHide.self)
    private static let setAutoHide = symbol("CoreDockSetAutoHideEnabled", as: SetAutoHide.self)

    /// Whether the Dock hides itself; nil if it can't be read.
    static var dockAutoHides: Bool? { getAutoHide?() }

    /// Turns the Dock's auto-hide on or off, as the Dock's own setting does. False if unavailable.
    @discardableResult
    static func setDockAutoHides(_ on: Bool) -> Bool {
        guard let setAutoHide else { return false }
        setAutoHide(on)
        return true
    }
}
