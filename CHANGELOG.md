# Changelog

All notable changes to Zephydian are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
