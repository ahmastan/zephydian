# Contributing to Zephydian

Thanks for your interest! Zephydian is a free, open-source utility and gaming corner for the Mac. Contributions of any size are welcome, from typo fixes to new utilities and games. More utilities are coming soon, so ideas for them are especially welcome.

## Ground rules

- Be kind. See the [Code of Conduct](CODE_OF_CONDUCT.md).
- **Keep it light.** Zephydian's main promise is very low resource usage. New features must not add idle CPU usage, background timers, or network access.
- **Liquid Glass for new UI.** New screens and controls follow Apple's Liquid Glass guidelines. Put glass only on floating controls (buttons, tab bars, overlays, toasts), never on content such as game boards or text. Use the helpers in `app/Zephydian/UI/GlassControls.swift` (`glassSurface`, `GlassGroup`, `glassIconButtonStyle`, `headerMenuStyle`, `glassIconMenuStyle`, `SegmentedControl`, `panelButtonStyle`), which also handle the Frosted style on macOS 14–15. Check your UI with Reduce Transparency and Increase Contrast turned on.
- **No third-party trademarks.** Don't use names, logos, or artwork from existing games. Recreating general gameplay mechanics is fine, but give the game an original name.
- Open an issue before starting a large change, so we can agree on the approach first.

## Development setup

1. macOS 14 Sonoma or later, **Xcode 16+** (free on the Mac App Store), and **XcodeGen** (`brew install xcodegen`).
2. Fork the repo and clone your fork.
3. Generate the project with `cd app && xcodegen`, then open `app/Zephydian.xcodeproj` in Xcode.
   - The Xcode project is **generated from `app/project.yml`** and isn't committed. Change build settings in `project.yml`, never in Xcode's settings screens (those edits get overwritten). New `.swift` files inside `app/Zephydian/` are picked up automatically.
4. Select the **Zephydian** scheme and press **⌘R** to build and run.
   - Zephydian is a menu bar app, so it has **no Dock icon**. Look for its icon in the menu bar, or hover over your configured corner.
   - Signing is set to "Sign to Run Locally", so no Apple Developer account is needed.

## Project layout

```
app/
├── project.yml   Xcode project spec (XcodeGen), the source of truth for build settings
├── Config/       Info.plist and entitlements (generated from project.yml)
└── Zephydian/    All app source code (synced folder)
    ├── App/          App entry point and AppDelegate
    ├── Core/         Corner trigger, floating panel, settings, themes
    ├── UI/           Shared views (root tabs, settings)
    ├── Features/
    │   ├── Notes/    Quick Notes, the first utility
    │   └── Games/    Game protocol, registry, and one folder per game
    └── Resources/    Assets and word lists
```

## Regenerating assets

- **App icon:** made in Apple's Icon Composer (`assets/brand/AppIcon.icon`). Edit it there, then copy it to `app/Zephydian/Resources/AppIcon.icon`.
- **Word lists:** `python3 scripts/build-wordlists.py path/to/scowl` (see the script's header for details).

## Adding a new game

1. Create a folder `app/Zephydian/Features/Games/<YourGame>/`.
2. Create an `@Observable` class that conforms to `GameSession` (in `Features/Games/Game.swift`): score text, hint line, pause/resume, `handleKey(_:)` and `makeView()`. `SnakeGame.swift` is a compact example to copy from.
3. Register it with one line in `GameRegistry.all` (same file): id, name, SF Symbol and a "best score" label.
4. Performance rules:
   - Real-time games must use the shared `GameLoop` and stop it in `pause()`. The app calls `pause()` whenever the panel hides or you leave the game. **Never** start your own always-running `Timer`.
   - Turn-based and grid games shouldn't use a loop at all. A game clock (like in Mines and Nines) is fine: run it with `GameLoop` only while the game is being played.
   - Prefer SwiftUI `Canvas`, shapes, and SF Symbols over large image assets.
5. Make sure the game is fully playable with the keyboard, and add VoiceOver labels to its controls.
6. Optional extras: `makeHeaderAccessory()` puts a menu in the header (difficulty, new game; style it with `.headerMenuStyle()`), and `undo()` handles ⌘Z. `MinesGame` and `NinesGame` show both.

## Pull requests

1. Create a branch from `main` (`feature/letter-hive`, `fix/snake-wrap`, …).
2. Keep PRs focused, with one feature or fix each.
3. Make sure the app builds with **no warnings**.
4. Add a line under **Unreleased** in [CHANGELOG.md](CHANGELOG.md).
5. Fill out the PR template, and include a screenshot or GIF for UI changes.

## Reporting bugs and suggesting ideas

Use the issue templates: **Bug report**, **Feature request**, **Utility idea**, or **Game idea**. For security issues, follow [SECURITY.md](SECURITY.md) instead of opening a public issue.
