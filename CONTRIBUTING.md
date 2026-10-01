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
    │   ├── Notes/    Quick Notes
    │   └── Games/    Game protocol, registry, and the built-in games
    ├── Packs/        The pack runtime (JavaScriptCore), native controls and services for utilities, installer and Library data
    └── Resources/    Assets and word lists
packs/            Pack sources (games/ and utilities/), one folder per pack (published by .github/workflows/packs.yml)
docs/PACKS.md     How to make a pack
scripts/packs.swift  Checks, builds and signs packs
```

## Regenerating assets

- **App icon:** made in Apple's Icon Composer (`assets/brand/AppIcon.icon`). Edit it there, then copy it to `app/Zephydian/Resources/AppIcon.icon`.
- **Word lists:** `python3 scripts/build-wordlists.py path/to/scowl` (see the script's header for details).

## Making a new game or utility (a pack)

New games and utilities are **packs**: small JavaScript programs that people install from the in-app Library. They aren't compiled into the app. Everything you need is in **[docs/PACKS.md](docs/PACKS.md)**:

1. Create `packs/games/<id>/` with `manifest.json`, `main.js` and a 64×64 `icon.png`, or `packs/utilities/<id>/` with `manifest.json`, `main.js` and an SF Symbol name in the manifest. Switch (`packs/games/switch/`) and the utilities in `packs/utilities/` are complete examples.
2. Test it in a debug build by copying the folder into the developer folder described in the guide.
3. Run `swift scripts/packs.swift check packs`, then open a pull request.

Packs follow the same rules as the rest of the app: an original single-word name for games, only the capabilities a utility really needs, keyboard support where it makes sense, readable in light and dark mode, and no work while the game isn't on screen (the SDK's loop already stops when the panel hides).

**If your pack needs something the SDK can't do yet** (a new capability, control or native helper), that part goes into the app in Swift. Add it in `app/Zephydian/Packs/`, raise the SDK version in `PackBundle.swift` and `scripts/packs.swift`, document it in `docs/PACKS.md` under its SDK version, and set your pack's `sdkVersion` to match. Older apps then show the pack as "Update Zephydian to install this" instead of installing something they can't run. A new capability must be listed in `PackCapabilities.swift` with a plain sentence that the Library shows before install, and it must be refused when the manifest doesn't declare it. The windows and image editing in SDK 3 (Markup), and the dictionary and copied-text capabilities in SDK 4 (Dictionary), are examples.

## Working on the built-in games

The built-in games (Snake, Stackr, Five and the others) live in `app/Zephydian/Features/Games/`. Each is an `@Observable` class conforming to `GameSession` in `Game.swift`, registered in `GameRegistry.builtIn`.

- Real-time games must use the shared `GameLoop` and stop it in `pause()`. The app calls `pause()` whenever the panel hides or you leave the game. **Never** start your own always-running `Timer`.
- Turn-based games shouldn't use a loop at all. A game clock (like in Mines and Nines) is fine: run it with `GameLoop` only while the game is being played.
- Keep every registry `id` and saved key unchanged, so players keep their progress.
- The panel comes in three sizes. Boards scale with it: multiply fixed sizes (cells, keys) by the `boardScale` environment value, and keep text at its normal size.
- Record stats where a game starts, is won and (for scored games) ends, with `GameStats.started`, `won` and `finished`, so the Stats screen counts it.

## Pull requests

1. Create a branch from `main` (`feature/letter-hive`, `fix/snake-wrap`, …).
2. Keep PRs focused, with one feature or fix each.
3. Make sure the app builds with **no warnings**.
4. Add a line under **Unreleased** in [CHANGELOG.md](CHANGELOG.md).
5. Fill out the PR template, and include a screenshot or GIF for UI changes.

## Reporting bugs and suggesting ideas

Use the issue templates: **Bug report**, **Feature request**, **Utility idea**, or **Game idea**. For security issues, follow [SECURITY.md](SECURITY.md) instead of opening a public issue.
