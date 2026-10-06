<div align="center">

# Zephydian

**Utility and gaming corner.** A free, open-source Mac app: hover over a screen corner and a panel appears with handy utilities and games. Add the utilities you want from the Library, and more utilities are coming soon.

**[zephydian.com](https://zephydian.com)**: try it right in your browser.

![macOS 14+](https://img.shields.io/badge/macOS-14%2B-blue)
![License: GPL-3.0-or-later](https://img.shields.io/badge/license-GPL--3.0--or--later-green)
![Status: in development](https://img.shields.io/badge/status-in%20development-orange)

[![The Zephydian panel open over a Mac desktop, showing its games](assets/brand/preview.jpg)](https://zephydian.com)

</div>

---

## Features

- **Corner hover to open.** Pick any of the four screen corners. The panel appears when you hover and disappears when you're done.
- **Quick Notes.** Tabbed notes that autosave as plain Markdown files you can open anywhere. Open them in their own window that stays on top of other apps, drag a single note out of it to pin it anywhere on screen, preview notes formatted (tick checkboxes right in them), search every note, and export them.
- **Utilities you choose.** Add the ones you want from the **Library**: Clipboard (a private history of what you copy, pasted straight back), Capture (screenshots, screen recordings with an editor, text and colors from your screen), Markup (crop, annotate and pixelate screenshots or any image), Media (shrink videos, convert images, make GIFs), Dictionary (definitions and synonyms from your Mac's own dictionary, offline), Passwords, Colors, Timer, Calculator, Text tools, QR Code, Awake (keep your Mac awake, also by rules), System (CPU, GPU, memory, temperatures, battery and network), and for tidying your Mac: Uninstaller, Cleaner, Chat Files, Ports, App Updates and Homebrew. None come preinstalled, and more utilities are coming soon.
- **Mac features you switch on.** A **Features** page in Settings turns on only what you want; anything off costs nothing:
  - **Windows and Dock:** Dock Preview (hover an app in the Dock to see its windows), an App Switcher for ⌘Tab with live previews, Window Layout (snap windows with shortcuts, ⌥-drag to move), Maximize with the Green Button, Quit Protection, Quit on Close and Focus Follows Mouse.
  - **Keyboard and mouse:** Text Snippets, a Super Key on Caps Lock, smooth Scrolling, Mouse Buttons, Three-Finger Middle Click, No Mouse Acceleration, and filters for a worn mouse or keyboard.
  - **Clipboard and files:** Clean URLs, Paste as Plain Text, Auto-Clear Clipboard, a Shelf for dragged files, Finder Shortcuts (cut and paste files with ⌘X and ⌘V, rename with F2) and a Disk Image Installer.
  - **Everyday tools:** a Command Bar (⌥Space), a Radial Menu (a wheel of your apps, folders, links, utilities and actions around the pointer, from a shortcut or a mouse button), a Quick Panel, Quick Toggles, Cleaning Mode and a Camera Mirror.
  - **System and sound:** a Sound Mixer with per-app volume, Headphones Safety, Music Blocker, Display Brightness for every display, Bluetooth Off in Sleep, Menu Bar Stats and System Alerts.
- **Games you choose.** Snake, Stackr (block stacking) and Five (5-letter word guess) come installed. Spokes (letter-wheel crosswords), Fleet (sea battle), Airship (top-down shooter), 2048 (slide and merge numbers), Mines (clear the minefield), Nines (number-placement puzzles) and Switch (turn every light off) are a click away in the **Library**, with more games on the way. Remove any game you don't play. A **Stats** screen shows your games played, wins, best scores and streaks.
- **Make it yours.** Light, dark, or system appearance, accent color themes (or your Mac's own accent color, followed live), a small, medium or large panel, the panel's tabs in your order (add your favorite games, utilities and features like Sound or Quick Toggles as tabs, hide the ones you don't use), Liquid Glass or frosted panel (macOS 26+), and a choice of menu bar icon (or none at all).
- **Keyboard shortcuts you pick.** Record any key combination for the panel, the utilities and every feature. Zephydian tells you right under the field if something else on your Mac already uses it.
- **Featherweight.** Native Swift and SwiftUI. A small app, ~30 MB memory, and ~0.1% CPU when idle with features off. Each feature runs only while it's switched on, and games pause the moment the panel hides.
- **Private.** No accounts and no tracking. Zephydian goes online only to download games and utilities you pick from the Library and about once a day to update them (you can turn that off), and when you ask a utility to: System's public IP and speed test, App Updates checking versions, and Homebrew. Nothing about you is sent. Everything else stays on your Mac.

## Permissions

Zephydian asks for a macOS permission only when you switch on something that needs it, and **Settings → Permissions** shows what uses each one (with a **Repair** button if macOS loses track of it).

| Permission | Used by |
| --- | --- |
| Accessibility | Most Mac features: Dock Preview, the App Switcher, window tools, keyboard and mouse features, Paste as Plain Text, Finder Shortcuts, Cleaning Mode, the Command Bar's menu search, and the Radial Menu's mouse buttons and the slices that press keys or move windows |
| Screen Recording | Capture, and window previews in Dock Preview and the App Switcher |
| Microphone | Capture's recordings, when you include the microphone |
| Camera | Camera Mirror |
| System Audio Recording | Sound Mixer's per-app volume, and Capture recording your Mac's sound |
| Automation (Finder) | Finder Shortcuts, and emptying the Trash from Quick Toggles |
| Notifications | Timer, System Alerts and Cleaner's reminder |
| Full Disk Access (optional) | Chat Files, to reach some chat apps' downloads |

Since 0.7, Zephydian runs outside the App Sandbox, because these features read and arrange other apps' windows, which the sandbox doesn't allow. Your notes and settings moved to `~/Library/Application Support/Zephydian` (the old copy is kept as a backup). Packs are still locked down by Zephydian itself.

## Install

### Homebrew (recommended)

```sh
brew install ahmastan/tap/zephydian
```

After that first install, plain `zephydian` works: update with `brew upgrade zephydian`, and uninstall with `brew uninstall --zap zephydian` (`--zap` also deletes your notes and settings).

### Download

Grab the latest `.zip` (and later, a `.dmg`) from the [Releases](https://github.com/ahmastan/zephydian/releases) page and drag **Zephydian.app** into **Applications**.

### "Apple could not verify Zephydian…"

Early builds aren't signed with an Apple Developer certificate yet, so macOS blocks the first launch. To open it anyway, do **one** of these:

- Open **System Settings → Privacy & Security**, scroll down, and click **Open Anyway** next to Zephydian, **or**
- Run this in Terminal:
  ```sh
  xattr -dr com.apple.quarantine /Applications/Zephydian.app
  ```

You only need to do this once per version.

## Requirements

- macOS 14 Sonoma or later
- Apple Silicon or Intel Mac

## The Library

Click **Get more** above the Games or Utilities grid to add or remove games and utilities. Built-in games install instantly. Everything else arrives as small **packs**: JavaScript programs that Zephydian runs in a locked-down sandbox and draws natively, so they look and feel like the rest of the app.

- **Safe by design.** A game can only draw on its game area, react to keys and clicks, and save its own progress. No pack has internet access.
- **You see what a utility uses.** A utility that needs more (the clipboard, screenshots, notifications, keeping the Mac awake, a keyboard shortcut) lists it under **Uses** in the Library, and Zephydian asks you before installing it. It can't use anything it didn't list. Screenshots also need macOS's own Screen Recording permission, a utility can save a file only where you choose, Markup opens only images you pick, paste or capture, and Dictionary reads what you copied only while it's on screen.
- **Background work is visible.** When a utility keeps working with the panel closed (Awake, a running timer), the menu bar icon turns your accent color, and **Settings → Packs** lets you stop it.
- **Settings for each utility.** Utilities with options get their own page under **Utilities** in the Settings window (the gear in a utility's header opens it).
- **Verified.** The list of packs is signed, and every download must match its SHA-256 fingerprint before it's installed. Anything altered is refused.
- **Your choice.** Nothing is installed without you. Removing a game keeps its progress in case you come back, unless you choose to delete that too.
- **Updates** install quietly, never while you're playing. Turn off the daily check in **Settings → Packs**.

### What each utility can use

Only App Updates, Homebrew and System's network test use the internet, and only when you ask. Copy buttons you click work in every utility and aren't listed. Anything a utility removes goes to the Trash.

| Utility | What it can use |
| --- | --- |
| App Updates | Checks your apps' versions online (the App Store, Homebrew, apps' own update feeds), updates Homebrew apps, and opens the others |
| Awake | Keeps your Mac awake while it's switched on (in the background), also by your rules (while chosen apps run, on power, with a display) |
| Calculator | Nothing extra |
| Capture | Pictures and recordings of your screen (macOS asks for Screen Recording first), your microphone and Mac's sound if you include them, reading text on screen (on your Mac), saving to Pictures/Screenshots or a folder you pick, and its own keyboard shortcut |
| Chat Files | Lists and moves to the Trash old downloads from chat apps, after you review them |
| Cleaner | Lists and moves to the Trash caches, logs and leftovers, after you review them, and an optional reminder notification |
| Clipboard | Reads what you copy while recording is on (in the background, never what password managers mark private), pastes an item back into the app you were in, and its own keyboard shortcut |
| Colors | The color of a spot on your screen that you pick |
| Dictionary | The dictionary and thesaurus built into macOS, the text you copied (only while it's on screen), copying, and its own keyboard shortcut |
| Homebrew | Runs Homebrew (which goes online) to search, install, upgrade and remove packages |
| Markup | Its own window, the screenshots you took, images you open or paste, copying, and saving where you choose |
| Media | Converts the videos and images you pick, on your Mac |
| Passwords | Nothing extra |
| Ports | Lists programs listening on network ports, and stops the one you choose |
| QR Code | Copying, and saving where you choose |
| System | CPU, GPU, memory, temperatures, battery, busy apps and network for the whole Mac, read only while it's on screen; your public IP and a speed test when you ask (online) |
| Text | Nothing extra |
| Timer | Running timers in the background, and notifications (macOS asks first) |
| Uninstaller | Lists your apps and an app's leftover files, and moves the ones you approve to the Trash |

Want to make a game or a utility? See [docs/PACKS.md](docs/PACKS.md).

## Tip: Hot Corners

If you've assigned an action to the same corner in **System Settings → Desktop & Dock → Hot Corners**, it will clash with Zephydian. Pick a different corner in one of the two.

## Building from source

1. Install **Xcode** (16 or later) from the Mac App Store, and [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`.
2. Clone this repo, then generate the Xcode project: `cd app && xcodegen`.
3. Open `app/Zephydian.xcodeproj` and press **⌘R**. Zephydian appears in the menu bar.

See [CONTRIBUTING.md](CONTRIBUTING.md) for details.

## Contributing

Bug reports, utility and game ideas, and pull requests are welcome. New games and utilities are made as packs: see [docs/PACKS.md](docs/PACKS.md). Please read [CONTRIBUTING.md](CONTRIBUTING.md) and our [Code of Conduct](CODE_OF_CONDUCT.md) first.

## License

Zephydian is free software under the [GNU General Public License v3.0 or later](LICENSE) © 2026 ahmastan. You may use, share and change it; if you share a changed version, it must stay under the same license with its source code available. Versions up to 0.6.0 were released under the MIT License, which still applies to those releases.

The app switcher and Finder cut and paste (`app/SwitcherKit/`), the Radial Menu's slice geometry, and the Now Playing reader (`app/NowPlaying/`) come from [Vorssaint](https://github.com/vorssaint/vorssaint-utils) by Vorssaint, under the GPL-3.0-or-later. Zephydian is not affiliated with or endorsed by Vorssaint.

Word lists are derived from [SCOWL](http://wordlist.aspell.net/) by Kevin Atkinson, and Passwords uses the [EFF Large Wordlist](https://www.eff.org/dice) (CC BY 3.0). See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

Game names in Zephydian are original. Games inspired by classic titles recreate their general mechanics only and are not affiliated with or endorsed by those titles' trademark owners.
