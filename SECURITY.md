# Security Policy

## Supported versions

Only the **latest release** of Zephydian receives security fixes.

## Reporting a vulnerability

**Please don't open a public issue for security problems.**

Instead, report it privately through GitHub:

1. Go to the repository's **Security** tab.
2. Click **Report a vulnerability**.
3. Describe the issue, how to reproduce it, and its potential impact.

You'll get an acknowledgment within a few days. Once a fix is released, you'll be credited in the release notes (unless you'd rather stay anonymous).

## Scope

Zephydian stores only local data (settings, your notes, game progress and what your utilities keep, such as Clipboard's history). It connects to the internet only to download and update games and utilities (**packs**) from this repository's `packs` release: when you open the Library, when you install or update something, and at most once a day to check installed packs (which you can turn off).

### How packs are verified

- The pack list (`catalog.json`) is signed with an **Ed25519** key when the release workflow publishes it. The private key exists only as a GitHub Actions secret, and the app contains only the public key.
- The app refuses a catalog whose signature doesn't match, or one older than a catalog it has already seen, so an old list can't be replayed.
- Each download must match the size and **SHA-256** fingerprint in the signed catalog before it's unpacked. The unpacker allows no links, no paths outside the pack's folder and no oversized files.
- A pack runs in its own JavaScriptCore context with no network or file access. On its own it can only draw, handle input and store up to 1 MB of its own data. A call that runs for more than a second is stopped.
- A utility can also use **capabilities** (the clipboard, screenshots, notifications, keeping the Mac awake, a global shortcut, system figures and so on), but only the ones its manifest declares. The Library shows them and asks before installing, and the app refuses any it didn't declare. A utility never gets a file path: it can save only where the person picks in a save dialog (Screenshot saves to Pictures/Screenshots or a folder the person chose), and screenshots also need macOS's Screen Recording permission.
- Work that continues with the panel closed (keeping the Mac awake, timers, recording the clipboard) is shown in **Settings → Packs** with a Stop button, and removing a utility stops it and deletes its data.
- Debug builds can load unsigned packs from a developer folder for testing. Release builds never do.

### Of particular interest

- Anything that lets another app or website read or modify your notes
- A way for a pack to reach the network, files, other packs or anything outside its sandbox, or to use a capability it didn't declare
- A way to install a pack that isn't in the signed catalog, or doesn't match its fingerprint
- Issues with the app's sandbox entitlements or code signing
- Tampering with release artifacts, the `packs` release or the Homebrew cask
