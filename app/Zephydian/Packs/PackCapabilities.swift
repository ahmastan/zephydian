import Foundation

/// Something a pack may use beyond drawing and its own storage. A pack lists these in its
/// manifest's `capabilities`, the Library shows them before install, and the SDK refuses any
/// call that needs one the pack didn't declare. Each one is written in Swift inside the app.
nonisolated struct PackCapability: Equatable {
    let id: String
    /// For the Library row: "Uses: clipboard, keep awake".
    let short: String
    /// For the install confirmation: "Clipboard can: …".
    let sentence: String
    /// Keeps working after the panel closes, while the utility is switched on.
    var runsInBackground = false

    static let all: [PackCapability] = [
        .init(id: "clipboard.write", short: "clipboard", sentence: "Copy text to your clipboard"),
        .init(id: "clipboard.text", short: "copied text", sentence: "Read the text you've copied, only while it's on screen"),
        .init(id: "clipboard.read", short: "clipboard history",
              sentence: "Read what you copy, in the background while it's switched on", runsInBackground: true),
        .init(id: "power.awake", short: "keep awake",
              sentence: "Keep your Mac awake, in the background while it's switched on", runsInBackground: true),
        .init(id: "notifications", short: "notifications", sentence: "Show notifications (macOS asks you first)"),
        .init(id: "screen.capture", short: "screenshots", sentence: "Take pictures of your screen (macOS asks you first) and save them in Pictures/Screenshots or a folder you choose"),
        .init(id: "color.sample", short: "screen colors", sentence: "Read the color of a spot on the screen you pick"),
        .init(id: "files.save", short: "saving files", sentence: "Save files to a place you choose"),
        .init(id: "windows", short: "windows", sentence: "Open its own window (Zephydian shows in the Dock while it's open)"),
        .init(id: "images.edit", short: "image editing",
              sentence: "Open your screenshots, an image you pick or one you paste, and save the edited copy where you choose"),
        .init(id: "system.stats", short: "system stats", sentence: "Read CPU, memory, disk, battery and network use"),
        .init(id: "timers", short: "timers", sentence: "Run timers in the background and play a sound when they end", runsInBackground: true),
        .init(id: "dictionary", short: "your Mac's dictionary",
              sentence: "Look up words in the dictionary and thesaurus that come with macOS, and say them aloud"),
        .init(id: "shortcut", short: "a shortcut", sentence: "Open itself with a keyboard shortcut you choose"),
    ]

    static func named(_ id: String) -> PackCapability? { all.first { $0.id == id } }

    /// Known capabilities from a manifest or catalog entry, in the order above. Unknown ids are dropped.
    static func list(_ ids: [String]?) -> [PackCapability] {
        let set = Set(ids ?? [])
        return all.filter { set.contains($0.id) }
    }
}
