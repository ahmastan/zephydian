<div align="center">

# Zephydian

**Utility and gaming corner.** A free, open-source Mac app: hover over a screen corner and a panel appears with handy utilities and games. Quick Notes is the first utility, and more utilities are coming soon.

**[zephydian.com](https://zephydian.com)**: try it right in your browser.

![macOS 14+](https://img.shields.io/badge/macOS-14%2B-blue)
![License: MIT](https://img.shields.io/badge/license-MIT-green)
![Status: in development](https://img.shields.io/badge/status-in%20development-orange)

[![The Zephydian panel open over a Mac desktop, showing its games](assets/brand/preview.jpg)](https://zephydian.com)

</div>

---

## Features

- **Corner hover to open.** Pick any of the four screen corners. The panel appears when you hover and disappears when you're done.
- **Quick Notes.** The first utility: tabbed notes that autosave as plain Markdown files you can open anywhere.
- **More utilities coming soon.** Notes is just the start. More everyday tools are on the way, free and open source like the rest.
- **Games you choose.** Snake, Stackr (block stacking) and Five (5-letter word guess) come installed. Spokes (letter-wheel crosswords), Fleet (sea battle), Airship (top-down shooter), 2048 (slide and merge numbers), Mines (clear the minefield), Nines (number-placement puzzles) and Switch (turn every light off) are a click away in the **Library**, with more games on the way. Remove any game you don't play.
- **Make it yours.** Light, dark, or system appearance, accent color themes, Liquid Glass or frosted panel (macOS 26+), and a choice of menu bar icon (or none at all).
- **Optional keyboard shortcut** to open the panel from anywhere.
- **Featherweight.** Native Swift and SwiftUI. ~13 MB app, ~25 MB memory, and ~0.1% CPU when idle. Games pause the moment the panel hides.
- **Private.** No accounts and no tracking. Zephydian goes online only to download games you pick from the Library, and about once a day to update them (you can turn that off). Nothing about you is sent.

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

Open **Get more** at the end of the Games grid to add or remove games. Built-in games install instantly. New games arrive as small **packs**: JavaScript programs that Zephydian runs in a locked-down sandbox and draws natively, so they look and feel like the rest of the app.

- **Safe by design.** A pack can only draw on its game area, react to keys and clicks, and save its own progress. It has no internet, file or system access.
- **Verified.** The list of packs is signed, and every download must match its SHA-256 fingerprint before it's installed. Anything altered is refused.
- **Your choice.** Nothing is installed without you. Removing a game keeps its progress in case you come back, unless you choose to delete that too.
- **Updates** install quietly, never while you're playing. Turn off the daily check in **Settings → Packs**.

Want to make a game? See [docs/PACKS.md](docs/PACKS.md).

## Tip: Hot Corners

If you've assigned an action to the same corner in **System Settings → Desktop & Dock → Hot Corners**, it will clash with Zephydian. Pick a different corner in one of the two.

## Building from source

1. Install **Xcode** (16 or later) from the Mac App Store, and [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`.
2. Clone this repo, then generate the Xcode project: `cd app && xcodegen`.
3. Open `app/Zephydian.xcodeproj` and press **⌘R**. Zephydian appears in the menu bar.

See [CONTRIBUTING.md](CONTRIBUTING.md) for details.

## Contributing

Bug reports, game ideas, and pull requests are welcome. New games are made as packs: see [docs/PACKS.md](docs/PACKS.md). Please read [CONTRIBUTING.md](CONTRIBUTING.md) and our [Code of Conduct](CODE_OF_CONDUCT.md) first.

## License

[MIT](LICENSE) © 2026 ahmastan

Word lists are derived from [SCOWL](http://wordlist.aspell.net/) by Kevin Atkinson. See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

Game names in Zephydian are original. Games inspired by classic titles recreate their general mechanics only and are not affiliated with or endorsed by those titles' trademark owners.
