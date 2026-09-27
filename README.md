<div align="center">

# Zephydian

**A breeze of a Mac app.** Hover over a screen corner and a tiny panel appears, holding a quick scratchpad and a handful of lightweight games.

![macOS 14+](https://img.shields.io/badge/macOS-14%2B-blue)
![License: MIT](https://img.shields.io/badge/license-MIT-green)
![Status: in development](https://img.shields.io/badge/status-in%20development-orange)

<!-- TODO: screenshot / GIF of the panel opening from a corner -->

</div>

---

## Features

- **Corner hover to open.** Pick any of the four screen corners. The panel appears when you hover and disappears when you're done.
- **Quick Notes.** A tabbed scratchpad that autosaves as plain Markdown files you can open anywhere.
- **Tiny games.** Snake, Stackr (block stacking), Five (5-letter word guess), Spokes (letter-wheel crosswords), Fleet (sea battle), and Airship (top-down shooter). More are on the way.
- **Make it yours.** Light, dark, or system appearance, accent color themes, Liquid Glass or frosted panel (macOS 26+), and a choice of menu bar icon (or none at all).
- **Optional keyboard shortcut** to open the panel from anywhere.
- **Featherweight.** Native Swift and SwiftUI. ~8 MB app, ~25 MB memory, and ~0.1% CPU when idle. Games pause the moment the panel hides.
- **Private.** No accounts, no tracking, no network access.

## Install

> Zephydian is still in development. These instructions will work once the first release is published.

### Homebrew (recommended)

```sh
brew install --cask ahmastan/tap/zephydian
```

Update with `brew upgrade --cask zephydian`. Uninstall with `brew uninstall --cask --zap zephydian`.

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

## Tip: Hot Corners

If you've assigned an action to the same corner in **System Settings → Desktop & Dock → Hot Corners**, it will clash with Zephydian. Pick a different corner in one of the two.

## Building from source

1. Install **Xcode** (16 or later) from the Mac App Store, and [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`.
2. Clone this repo, then generate the Xcode project: `cd app && xcodegen`.
3. Open `app/Zephydian.xcodeproj` and press **⌘R**. Zephydian appears in the menu bar.

See [CONTRIBUTING.md](CONTRIBUTING.md) for details.

## Contributing

Bug reports, game ideas, and pull requests are welcome. Please read [CONTRIBUTING.md](CONTRIBUTING.md) and our [Code of Conduct](CODE_OF_CONDUCT.md) first.

## License

[MIT](LICENSE) © 2026 ahmastan

Word lists are derived from [SCOWL](http://wordlist.aspell.net/) by Kevin Atkinson. See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

Game names in Zephydian are original. Games inspired by classic titles recreate their general mechanics only and are not affiliated with or endorsed by those titles' trademark owners.
