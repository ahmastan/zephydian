# Changelog

All notable changes to Zephydian are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.8.0] - 2026-10-06

### Added
- **Radial Menu** (Settings → Features): a wheel of slices around the pointer, opened by a shortcut or a mouse button. Hold, point and let go, or click; arrow keys, number keys and Esc work too. Slices can open apps, files, folders and links, run your utilities and Zephydian features, flip quick toggles, arrange windows, press media keys or any key combination, paste a snippet, run a shortcut from the Shortcuts app, or show what's playing. Folders hold more slices. Build each wheel in Settings with a live preview: add slices by kind, drag them into order, rename them and pick their icons. Make several wheels (from scratch or from ready-made sets), each with its own color, shortcut and button; choose the size, the highlight's strength and where the wheel appears. A Notes slice opens Notes in its own window.
- **Choose the panel's tabs**: in Settings → Panel & Corner → Tabs, add your favorite games, utilities and Mac features (Sound, Brightness, Quick Toggles, Window Layout, Snippets, Shelf, Camera Mirror and more) as tabs of their own (up to 8 tabs; past 4 they show as icons), hide any of Games, Utilities, Notes and Settings, and drag them into your own order. ⌘1, ⌘2… follow the tabs that show, and with a single tab left the panel shows just that page.

### Changed
- **Screenshots go to the clipboard at once.** Every shot Capture takes is copied as soon as it's taken, ready to paste. "Copy automatically" in Capture's settings is now on for everyone (switch it off there if you'd rather not).

## [0.7.0] - 2026-10-05

### Added
- **Mac features you switch on**, on a new **Features** page in Settings (Essentials, Everything or None to start, or one by one). A feature that's off costs nothing:
  - **Windows and Dock:** **Dock Preview** (hover an app in the Dock to see, pick, minimize or close its windows), an **App Switcher** for ⌘Tab and ⌘` with live window previews, search, and W to close or Q to quit, **Window Layout** (halves, thirds, quarters and displays with ⌃⌥ shortcuts, ⌥-drag to move and ⌥⌘-drag to resize), **Maximize with the Green Button**, **Quit Protection** (press ⌘Q twice), **Quit on Close** and **Focus Follows Mouse**.
  - **Keyboard and mouse:** **Text Snippets** (type `;addr` and it becomes your address, or pick from a menu), a **Super Key** on Caps Lock, smooth **Scrolling** with its own direction, **Mouse Buttons**, **Three-Finger Middle Click**, **No Mouse Acceleration**, an **Extra Click Filter** and **Key Debounce** for worn hardware.
  - **Clipboard and files:** **Clean URLs**, **Paste as Plain Text**, **Auto-Clear Clipboard**, a **Shelf** that appears when you shake a dragged file (or in the corner panel), **Finder Shortcuts** (cut and paste files with ⌘X and ⌘V with a floating panel, a rename shortcut, and paste an image as a file) and a **Disk Image Installer**.
  - **Everyday tools:** a **Command Bar** (⌥Space: apps, windows, files, menus, clipboard, snippets, math, units and settings), a **Quick Panel** of favorite tools, **Quick Toggles** (dark mode, hidden files, desktop icons, eject, empty the Trash, lock, keyboard light, mute the mic), **Cleaning Mode** and a **Camera Mirror**.
  - **System and sound:** a **Sound Mixer** in the menu bar with each app's own volume (up to 200%) and output, **Headphones Safety**, **Music Blocker**, **Display Brightness** for every display, **Bluetooth Off in Sleep**, **Menu Bar Stats** and **System Alerts**.
- **A Settings window** (⌘, or All Settings… in the panel) in the style of System Settings, with a page for every feature, a **Permissions** page with Repair, a **Shortcuts** page, and a page for each utility with options. The panel keeps a short Settings tab.
- **New utilities in the Library:** **Media** (shrink videos, convert and watermark images, make GIFs), **Uninstaller**, **Cleaner**, **Chat Files**, **Ports**, **App Updates** and **Homebrew**. Everything they remove goes to the Trash after you review it.
- **Capture** (was Screenshot): screen recordings with an editor (trim, cut, blur, zoom on clicks, MP4 or GIF), copy text and QR codes from the screen, pick colors, scrolling screenshots and pinned screenshots, all from a capture bar (⇧⌘6). A **Freeze the screen** option holds everything still (videos too) while you pick, and the shortcut can take a screenshot straight away instead of showing the bar.
- **Clipboard** pastes an item straight into the app you were in and keeps copied files; **System** shows GPU, temperatures, fans, battery health, busy apps, history graphs, your public IP and a speed test; **Awake** can keep the Mac awake by itself while chosen apps run, on power or with a display.
- **Pack SDK 5 to 9**: settings pages, pasting, screen recording and media, system figures and the network test, and app management capabilities, plus a `center` option for a utility's start page. See `docs/PACKS.md`.

### Changed
- **Zephydian is now licensed under the GNU General Public License v3.0 or later** (it was MIT). The new app switcher and Finder cut and paste come from Vorssaint, which is GPL-licensed, and the GPL asks that the whole app use it. Zephydian stays free and open source; earlier releases keep the MIT License. See `THIRD_PARTY_NOTICES.md`.
- **Zephydian now runs outside the App Sandbox**, because its Mac features read and arrange other apps' windows. Your notes, packs and settings move to `~/Library/Application Support/Zephydian` on first launch (the old copy is kept as a backup). Packs are still locked down by Zephydian itself.
- Each feature asks for a macOS permission only when you switch it on, and **Settings → Permissions** shows what uses each one.
- App Updates, Cleaner and Chat Files show their start button in the middle of the page.

### Fixed
- A long note no longer jumps to the top for a moment when you type a space.
- Allowing a permission opens only macOS's own prompt, not System Settings as well.
- Selecting an area for a screenshot no longer shows the pixel magnifier (the color picker still does).

## [0.6.0] - 2026-09-30

### Added
- **Dictionary**, a new utility in the Library: definitions from the dictionary that comes with your Mac (senses, examples, phrases and origins), and a **Synonyms** tab with synonyms and opposites from its thesaurus. Click a synonym to look it up, go back, hear a word said aloud, and see a word of the day and your recent searches. Everything works offline, and nothing is downloaded.
- Copy a word anywhere and press Dictionary's own keyboard shortcut (or its clipboard button) to look it up.
- **Panel size**: choose Small, Medium or Large in Settings → Appearance. Game boards grow or shrink with the panel, and text stays the same size.
- **Notes**:
  - **Open Notes in their own window** with the new button in the Notes tab: move and resize it anywhere, and pin it on top of other apps. Put it back in the panel any time.
  - **Pin a single note to your screen**: in the Notes window, drag its tab out and let go anywhere. It floats above your other apps on every desktop, and you can move it, resize it, rename it and use all the note options from it. Pin as many as you like; they come back where you left them. Its pin unpins it.
  - A **Markdown preview** (the eye button or ⌘E) with checkboxes you can tick.
  - **Search** across every note (⌘F), and **export** a note as a `.md` file or all notes as a zip.
  - Make a line bigger or smaller with ⌘+ / ⌘− (it becomes a Markdown heading, so the note stays plain Markdown).
  - Up to 20 notes (was 5).
- **System accent color**: a new first choice in Settings → Appearance → Accent that follows your Mac's accent color and changes as soon as you change it in System Settings.
- **Stats**: a new Stats button above the Games grid shows games played, wins, best scores and times, average scores and a days-in-a-row streak for each built-in game, with Reset for one game or all.
- **Pack SDK 4**: the `dictionary` and `clipboard.text` capabilities, a `shortcut()` hook for utilities opened by their shortcut, wrapping rows, chip and icon buttons, and serif and italic text. See `docs/PACKS.md`.

### Changed
- **Get more** is now a button above the Games and Utilities grids (next to the new Stats button) instead of the last tile.

### Fixed
- With Smart auto-hide, the panel now hides when the pointer leaves it while a utility is open, as it does everywhere except in games. It still stays open while you're typing in a utility's field, as it does for notes.
- A utility or game that reloads while it's still open (for example one that stopped working, opened again) now starts properly instead of showing an empty screen.

## [0.5.1] - 2026-09-29

### Added
- **Markup**, a new utility in the Library, in its own window with a dark artboard, a tool rail and a style bar (Zephydian shows in the Dock while it's open). It opens on cropping, with a box you resize by its corners and edges like editing a photo on iPhone (Freeform, Original, Square, 4:3, 16:9). Then select, move and resize marks, draw arrows (filled, outline, open or double), lines, rectangles, ellipses and freehand lines, highlight, pixelate (five strengths), redact, add text (12 to 64 pt), number steps and add stickers, in eight colors and three line weights, with shadows on marks, gradient backdrops, layers, and undo and redo. Open a screenshot from this session, an image file or a pasted image, then Copy, Save or Save As.
- Markup shows the Zephydian jet at the top, and credits Vorssaint, whose screenshot editor inspired its design, at the bottom.
- Click a screenshot's preview to open it in Markup. Closing Markup asks whether to save or delete the screenshot (or cancel); for a file, whether to save your changes.
- **Pack SDK 3**: utilities can open their own window, edit images, and use a canvas that follows the pointer. See `docs/PACKS.md`.

### Changed
- Selecting an area for a screenshot shows a rounded, glowing border in your accent color and the size in pixels under it. The crosshair shows as soon as the selection starts, not only once you press.
- The screenshot preview has no Edit button anymore: click the picture instead.
- Saving a screenshot that was already saved (after editing it) replaces its file instead of making a second one.

### Fixed
- Removing a utility no longer clears this session's screenshots (only removing Screenshot does).

## [0.5.0] - 2026-09-29

### Added
- A **Utilities** tab, between Games and Notes. Utilities are installed from the Library, like games; none come preinstalled. The Library now has a Games / Utilities filter.
- **Pack SDK 2** for utilities: screens built from native controls (text fields, buttons, switches, sliders, lists), and capabilities such as copying to the clipboard or keeping the Mac awake. The Library shows what a pack uses and asks before installing it. See `docs/PACKS.md`.
- Utilities that keep working in the background (Awake, running timers) turn the menu bar icon your accent color, and can be stopped from **Settings → Packs**. Clipboard recording shows there too, but doesn't change the icon.
- The first utilities, each installed from the Library:
  - **Passwords**: random passwords and passphrases from the Mac's secure random source; copies stay out of clipboard histories.
  - **Text**: counts, case changes, line tools, JSON formatting, Base64 and URL encoding, SHA-256, UUIDs and placeholder text.
  - **Calculator**: type whole calculations and unit conversions ("5 km in mi") with a live answer and history.
  - **QR Code**: make a QR code offline, then copy it or save a PNG.
  - **Awake**: keep your Mac awake for a while or until you turn it off.
  - **Colors**: pick any color on screen and copy it as HEX, RGB, HSL, CSS or SwiftUI.
- Zephydian can save a file where you choose in a save dialog (used by QR Code), and nowhere else.
- More utilities:
  - **Timer**: countdowns that keep running with the panel closed, a stopwatch with laps, and a focus mode, with a notification and sound when time's up.
  - **System**: CPU, memory, disk, battery and network at a glance, measured only while you look.
  - **Screenshot**: capture an area, a window or the whole screen, with a delay option, its own shortcut, the camera sound, the pointer if you want, and automatic copying. Zephydian's own selection shows a crosshair in your accent color. A preview card lets you copy, save, delete or close; screenshots save to Pictures/Screenshots or any folder you choose, as PNG or JPEG.
  - **Clipboard**: a private history of the text and images you copy, with search, pins, ignored apps and its own shortcut. It skips passwords from password managers and is deleted when you remove it.

### Changed
- The app download is much smaller: release builds no longer include debug symbols.
- Keyboard shortcuts are recorded: press any combination you like (the panel shortcut in Settings, and utilities' shortcuts). If macOS, most apps or another app already use it, a note under the field says so.
- Tab shortcuts: ⌘1 Games, ⌘2 Utilities, ⌘3 Notes, ⌘4 Settings (⌘, still opens Settings).

### Fixed
- In the Frosted panel style (the only style on macOS 14 and 15), buttons such as Start, Play again and Install could freeze the panel.

## [0.4.0] - 2026-09-28

### Added
- **The Library.** Open **Get more** at the end of the Games grid to install or remove games. New games arrive as **packs**: small JavaScript programs that Zephydian runs in a locked-down sandbox and draws natively.
- **Switch**, the first pack: flip a light and its neighbours until the board is dark, in three difficulties.
- **Settings → Packs**: a switch for the daily update check, and **Check now**.
- A guide for making packs: `docs/PACKS.md`.

### Changed
- New installs start with Snake, Stackr and Five. The other built-in games install instantly from the Library. Updating keeps every game you've already played.
- Any game can be removed, keeping its progress for a reinstall or deleting it too.
- Zephydian now connects to the internet, but only to download games you choose from the Library and, about once a day, to update them. Downloads are signed and verified. See `SECURITY.md`.

## [0.3.0] - 2026-09-28

### Changed
- **Liquid Glass redesign** (macOS 26), following Apple's design guidelines. Glass is used for the controls that float above the content, while the content itself stays calm and readable:
  - The top tab bar is a glass bar, with the selection bubble sliding on top.
  - Games have round glass back and pause buttons and glass header menus, and the pause, win and lose screens are glass cards.
  - In Notes, the active tab is glass tinted with your accent color, and the + and ⋯ buttons are round glass buttons.
  - In Settings, the selected accent color, menu bar icon and corner sit on glass.
  - The Frosted style (macOS 14–15, or when chosen in Settings) keeps its classic look.
- Every game now has its own drawn icon, and game tiles lift slightly when you hover over them.
- Better support for Reduce Motion and Increase Contrast.
- Zephydian is now described as a **utility and gaming corner**: the welcome screen says so, and notes that more utilities are coming soon.

## [0.2.0] - 2026-09-27

### Added
- Three new games:
  - **2048:** slide and merge numbers. Your board is saved between launches.
  - **Mines:** clear the field without hitting a mine, in 3 difficulties with best times. The first click is always safe.
  - **Nines:** 9×9 number-placement puzzles, freshly generated with exactly one solution, in 3 difficulties. Includes pencil marks, undo (⌘Z) and best times, and your puzzle is saved between launches.

## [0.1.0] - 2026-09-27

First public release.

### Added
- Menu bar app that opens a floating panel when you hover a chosen screen corner (or press an optional global shortcut).
- Quick Notes: a Markdown scratchpad with tabs you can rename and drag to reorder, saved automatically.
- Six games: Snake, Stackr, Five, Spokes, Fleet and Airship.
- Settings for the corner, display, trigger delay, auto-hide, accent color, appearance, and the panel style (Liquid Glass on macOS 26, or Frosted).
