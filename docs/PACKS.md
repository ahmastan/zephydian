# Making a pack

New games and utilities come to Zephydian as **packs**. People install them from the **Library** inside the panel, and can remove them again. A pack is a small JavaScript program plus its data. Zephydian runs it with Apple's built-in JavaScriptCore and draws it natively, so a pack looks and feels like the rest of the app, Liquid Glass included.

This guide covers **SDK version 3**. Version 1 brought games. Version 2 added **utilities**, whose screens are built from native controls, and **capabilities** for the few things a utility needs beyond its own screen (the clipboard, keeping the Mac awake and so on). Version 3 lets a utility open **its own window** and **edit images**, with a canvas that takes the pointer.

- [What a pack can and can't do](#what-a-pack-can-and-cant-do)
- [Folder layout](#folder-layout)
- [manifest.json](#manifestjson)
- [The game object](#the-game-object)
- [The `z` API](#the-z-api)
- [Drawing](#drawing)
- [Colors](#colors)
- [Utilities (SDK 2)](#utilities-sdk-2)
- [Capabilities](#capabilities)
- [Windows and image editing (SDK 3)](#windows-and-image-editing-sdk-3)
- [Words and copied text (SDK 4)](#words-and-copied-text-sdk-4)
- [A complete example](#a-complete-example)
- [Testing your pack](#testing-your-pack)
- [Submitting a pack](#submitting-a-pack)
- [How packs are published and verified](#how-packs-are-published-and-verified)

## What a pack can and can't do

A pack can draw on its game area, react to keys and clicks, run a game loop while it's on screen, show the standard pause/win/lose cards and message bubbles, add one menu to the header, and save a little data of its own.

A utility builds its screen from native controls (text, fields, buttons, switches, lists) instead of drawing it, and may use the **capabilities** it declares in its manifest, which people see before they install it.

A pack **can't** do anything else. It has no network, no files, no access to notes, to other packs or to the rest of the Mac, and no `setTimeout`, `fetch` or `require`. That isn't a policy the app enforces afterwards: JavaScriptCore simply has none of these, and the SDK never adds them. That's what makes a pack safe to install.

Resource rules match the built-in games:
- The game loop only runs while the pack is on screen and not paused. When the panel hides, the pack is paused automatically.
- A pack that isn't open uses no CPU.
- Keep drawing lists reasonable (a few thousand shapes per frame at most).

## Folder layout

Pack sources live in this repository:

```
packs/
├── games/
│   └── lights/            the folder name is the pack id
│       ├── manifest.json
│       ├── main.js
│       ├── icon.png       64×64, black on transparent (drawn in the user's accent color)
│       └── assets/        optional images (PNG) and data files (JSON, TXT)
└── utilities/
    └── notepad/           the same layout; a utility may use an SF Symbol instead of icon.png
```

`swift scripts/packs.swift check packs` checks every pack: the file list, the manifest, the icon size, the limits and the JavaScript syntax. Run it before opening a pull request.

`swift scripts/packs.swift build packs/games/lights` turns the folder into `dist/packs/lights-1.0.0.zpack`, the single file people download (a zip with a different extension). You don't need to build it yourself: the release workflow builds and publishes every pack.

A utility can name an SF Symbol with `symbol` in its manifest instead of drawing an `icon.png`; the build draws the icon from the symbol.

Only these files are allowed: `manifest.json`, `main.js`, `icon.png`, and PNG, JSON or TXT files under `assets/`. Symbolic links aren't allowed.

**Size limits:** 5 MB per pack, 512 KB for `main.js`.

## manifest.json

```json
{
  "id": "lights",
  "name": "Lights",
  "kind": "game",
  "version": "1.0.0",
  "sdkVersion": 1,
  "description": "Turn every light off in as few moves as you can.",
  "hint": "Click a light to flip it and its neighbours · R restart",
  "pauseButton": false,
  "tileStat": "bestScore",
  "whatsNew": "First release."
}
```

| Field | Meaning |
| --- | --- |
| `id` | Lowercase letters, digits and `-`, and the same as the folder name. It never changes: saved data is kept under it. |
| `name` | Shown on the tile and in the Library. **Games use a single original word** that isn't a trademarked title. Utilities use a plain name that says what they do ("Calculator", "QR Code"). |
| `kind` | `"game"` or `"utility"`. Utilities need `sdkVersion` 2 or newer. |
| `version` | `major.minor.patch`. Raise it with every change, or the update won't be published. |
| `sdkVersion` | The SDK version the pack needs. An app with an older SDK shows the pack as "Update Zephydian to install this". |
| `description` | One line for the Library. |
| `hint` | The controls line shown under the game. It can also be changed at runtime with `z.hint()`. |
| `pauseButton` | `true` for real-time games, to show the header's pause button. |
| `tileStat` | What the tile shows under the name: `"bestScore"`, `"bestTime"` or `"none"`. |
| `whatsNew` | A short line shown in the Library after an update. |
| `symbol` | Optional. An SF Symbol name (for example `"doc.on.clipboard"`) used as the icon instead of `icon.png`. Meant for utilities. |
| `capabilities` | Optional (SDK 2). What the pack uses beyond its own screen and storage, such as `["clipboard.write"]`. See [Capabilities](#capabilities). |
| `handles` | Optional (SDK 3, utilities). `["image"]` makes the utility the editor behind a screenshot's Edit button. It needs the `windows` and `images.edit` capabilities. |

## The game object

`main.js` hands the SDK one object with the functions it wants to use. All of them are optional.

```js
zephydian.game({
  start()      { },   // once, when the game screen opens
  draw(g)      { },   // draw the game area (see Drawing); called after z.redraw()
  tick(dt)     { },   // every loop step while the loop runs; dt = milliseconds since the last one
  key(e)       { },   // a key was pressed; return true if you used it
  keyUp(e)     { },   // a key was released (for held keys in real-time games)
  click(e)     { },   // a click on the game area
  pause()      { },   // the game is being paused (the panel hid, or the pause button / Space)
  resume()     { },   // the game carries on
  undo()       { },   // ⌘Z; return true if a move was undone
});
```

**Key events** (`e`) have:
- `key`: `"ArrowLeft"`, `"ArrowRight"`, `"ArrowUp"`, `"ArrowDown"`, `"Enter"`, `" "` (Space), `"Backspace"`, or the typed letter or digit in lowercase (`"r"`, `"5"`).
- `shift`, `option`: booleans.
- `repeat`: true when the key is held down.

Esc, ⌘W, ⌘Q, the panel's ⌘ shortcuts and Control-key combinations belong to the app and never reach a pack.

**Pausing works in one of two ways, set by `pauseButton` in the manifest:**
- **`true` (real-time games):**
  - The header gets a pause button, and Space pauses and resumes. Space isn't sent to `key()`.
  - While paused, Zephydian shows a standard "Paused" card with a Resume button. Enter or Space resumes.
- **`false` (turn-based games and puzzles):** there's no pause button or card. When the panel hides, the pack still gets `pause()`, and the next key or click resumes it before that key or click is delivered.

When a card from `z.overlay()` is showing, Enter presses its prominent button.

**Click events** have `x` and `y` in points from the top-left of the game area, and `button` (`"left"` or `"right"`).

## The `z` API

`z` is a global object available everywhere in `main.js`.

**Screen**
- `z.width`, `z.height`: the size of the game area in points. It can differ between Macs, so always draw from these.
- `z.redraw()`: ask for `draw(g)` to be called again before the next frame. Calling it several times in a row still draws once.
- `z.theme`: `{ dark, accent, text, secondary, fill, background }`. `dark` is true in dark mode, and the rest are color strings for the current appearance and accent (see Colors).

**Game loop**
- `z.loop.start(ms)`: call `tick(dt)` every `ms` milliseconds (at least 8). Calling it again changes the speed.
- `z.loop.stop()`
- The loop stops by itself while the game is paused, and starts again by itself on resume (unless you stopped it).
- `z.after(ms, fn)`: run `fn` once after `ms` milliseconds. It returns an id for `z.cancel(id)`. Pending calls are dropped when the game pauses, so re-arm them in `resume()` if you need them.

**Header and hint**
- `z.score("12 · best 42")`: the text at the top right of the game screen.
- `z.hint("…")`: replaces the manifest's hint.
- `z.menu({ title, items, selected, onSelect })`: one header menu (for example a difficulty). `items` is an array of strings, `selected` is the index of the ticked item (its name shows in the header), and `onSelect(index)` is called when the player picks one. The tick moves to the picked item by itself. Call `z.menu(null)` to remove it.

**Cards and messages**
- `z.overlay({ title, subtitle, buttons })`: shows the standard card over the game (ready, paused, game over). `buttons` is an array of `{ label, action, prominent }`, where `action` is a function. At most one button should be `prominent`, and Enter presses it.
- `z.overlay(null)`: hides the card.
- `z.toast("Not in word list")`: a short message bubble at the top.

**Best score and time**
- `z.best.score()`: the saved best score (0 if none).
- `z.best.submitScore(n)`: saves `n` if it's higher. Returns true for a new best.
- `z.best.time()`: the saved best time in seconds (0 if none).
- `z.best.submitTime(seconds)`: saves it if it's lower. Returns true for a new best.

These feed the tile stat chosen by `tileStat`.

**Storage**
- `z.storage.get(key)`: the saved value, or `null`.
- `z.storage.set(key, value)`: saves any JSON value.
- `z.storage.remove(key)`
- `z.storage.clear()`

Each pack has its own storage, up to 1 MB in total. It's kept when the player removes the pack, unless they choose "Remove and delete progress". Save as you go (for example after each move), because the game can be closed at any time.

**Pack files**
- `z.data(name)`: the contents of `assets/<name>`, as an object for `.json` files and a string for `.txt` files.
- Images in `assets/` are drawn with `g.image(name, …)`.

**Errors**
- `z.log(...)`: writes to the Xcode console in debug builds, and does nothing otherwise.
- If a pack throws an error, it stops. The player sees "This game stopped working" with a Back button, and Zephydian keeps running. In debug builds the card shows the error and its line in `main.js`.
- A single call into the pack (`start`, `draw`, `tick`, a key…) may run for at most 1 second. Anything longer, such as an endless loop, is stopped the same way.
- A frame can hold at most 20,000 shapes.

## Drawing

`draw(g)` receives a drawing list. You describe shapes, and Zephydian draws them with SwiftUI's Canvas. Coordinates are in points, with (0, 0) at the top-left of the game area.

```js
g.clear("fill");                                          // fill the whole area (default "background")
g.rect(x, y, w, h, { fill, stroke, lineWidth, radius }); // rounded when radius > 0
g.circle(cx, cy, r, { fill, stroke, lineWidth });
g.ellipse(x, y, w, h, { fill, stroke, lineWidth });       // SDK 3
g.line(x1, y1, x2, y2, { stroke, lineWidth, cap });      // cap: "butt" | "round"
g.path([[x, y], [x, y], …], { fill, stroke, lineWidth, closed, cap }); // cap: "round" also rounds the joins (SDK 3)
g.text("2048", x, y, { size, weight, color, align, font }); // align: "left" | "center" | "right"
                                                          // weight: "regular" | "medium" | "semibold" | "bold"
                                                          // font: "system" | "rounded" | "mono"
g.image("ship.png", x, y, w, h, { opacity, pixelate });  // pixelate: block size, to hide what's there (SDK 3)
g.save(); g.translate(dx, dy); g.rotate(radians); g.scale(s); g.alpha(a); g.restore();
g.clip(x, y, w, h, { radius });                          // only draw inside this area until restore() (SDK 3)
g.shadow(color, { radius, x, y });                       // a soft shadow under what follows, until restore() (SDK 3)
g.symbol("star.fill", cx, cy, size, { color });          // an SF Symbol centered on the point (SDK 3)
g.gradient(x, y, w, h, [color1, color2], { radius });    // a gradient from top-left to bottom-right (SDK 3)
```

`text` is positioned by the middle of its line, so `y` is the vertical center of the text. A rect, circle or path with neither `fill` nor `stroke` is filled with `"text"`. The game area has rounded corners, and nothing is drawn outside it.

## Colors

Anywhere a color is expected, you can use:
- **A theme name:** `"accent"`, `"text"`, `"secondary"`, `"fill"` or `"background"`. These follow light/dark mode and the player's accent color, so prefer them.
- **A hex color:** `"#ff9f0a"`, or `"#ff9f0a80"` with alpha.
- **An `rgba()` color:** `"rgba(255, 159, 10, 0.5)"`.

Keep text contrast at least 4.5:1, and don't use color alone to show state (for example, add a mark or a pattern too).

## Utilities (SDK 2)

A utility hands the SDK an object with a `view()` function. Instead of drawing, `view()` **returns the screen** as `z.ui` controls, and Zephydian draws them with native Mac controls (Liquid Glass buttons, real text fields, switches and so on). Whenever the utility handles an event, its timer fires or a control is used, Zephydian calls `view()` again and updates only what changed. Keep your state in variables and describe the screen from them.

```js
zephydian.utility({
  start()  { },          // once, when the utility opens
  view()   { return z.ui.text("Hello"); },   // required: the screen, from z.ui controls
  key(e)   { },          // a key pressed while no text field has the cursor; return true if used
  pause()  { },          // the panel hid
  resume() { },          // it's back on screen
  shortcut() { },        // SDK 4: opened with its own keyboard shortcut (the `shortcut` capability)
});
```

Utilities have no pause button or cards; `z.menu()`, `z.toast()`, `z.hint()`, `z.storage`, `z.after()` and `z.loop` work as they do for games. The header shows the utility's name, and the hint line only when you set one.

### Controls

| Control | What it is |
| --- | --- |
| `z.ui.text(text, { style, align, selectable, color, italic })` | A line or paragraph. `style`: `"body"` (default), `"title"`, `"large"` (a big number, like a result), `"display"` (a big serif heading, SDK 4), `"secondary"`, `"caption"`, `"mono"`. `align`: `"left"`, `"center"`, `"right"`. `selectable: true` lets people select and copy it. `italic: true` (SDK 4) for examples and labels. |
| `z.ui.field({ value, placeholder, onChange(text), onSubmit(text), multiline, lines, mono })` | A text field. `onChange` gets every edit; `onSubmit` gets Enter. Set `value` from your state: the field keeps the cursor where it is while you type. `multiline: true` with `lines` (1–30) for bigger text. |
| `z.ui.button(label, onPress, { symbol, style, disabled, selected })` | A button. `style`: `"plain"` (default), `"prominent"` (the main action) or `"destructive"`. `symbol` adds an SF Symbol. SDK 4 adds `"icon"` (just the symbol; `label` becomes its tooltip and what VoiceOver reads) and `"chip"` (a small rounded word or tag, for a `flow`; `selected: true` makes it stand out in the accent color). |
| `z.ui.toggle(label, value, onChange(on))` | A switch. |
| `z.ui.slider({ value, min, max, step, onChange(value) })` | A slider. With `step`, values snap to it. |
| `z.ui.segmented(options, selected, onChange(index))` | A few choices side by side. |
| `z.ui.picker(label, options, selected, onChange(index))` | A pop-up menu for longer lists of choices. |
| `z.ui.copy(text, { label, concealed })` | A Copy button. Copying from a button someone clicks needs no capability. `concealed: true` marks the text so clipboard histories skip it (for passwords). |
| `z.ui.row(children, { spacing, align })`, `z.ui.column(children, { spacing, align })` | Lay controls out side by side or top to bottom. |
| `z.ui.flow(children, { spacing })` | SDK 4. Side by side, wrapping onto more lines when they don't fit, like tags. |
| `z.ui.section(title, children)` | A group on a rounded card, like the sections in Settings. `title` can be `null`. |
| `z.ui.list(items, { selected, onSelect(id), onAction(id, index), empty })` | Rows. Each item is `{ id, title, subtitle, detail, symbol, image, actions: [{ symbol, label }] }`; `image` (a clipboard history picture) shows a small thumbnail instead of the symbol. `onAction` gets the row id and which action button was clicked. `empty` is shown when there are no items. |
| `z.ui.canvas({ width, height, draw(g, width, height) })` | A small drawing area using the same drawing API as games (a QR code, a chart, a color wheel). |
| `z.ui.swatch(color, { size, selected, onPress, accessibilityLabel })` | A color square. With `onPress` it's clickable; `selected: true` rings it in the accent color. Give clickable swatches an `accessibilityLabel` (for example the hex value) for VoiceOver. |
| `z.ui.disclosure(label, expanded, onToggle(open), children)` | A row with a chevron that shows or hides `children`. The pack keeps `expanded`, so start it `false` to hide the contents by default. |
| `z.ui.divider()`, `z.ui.spacer()` | A thin line; flexible space in a row or column. |

Every control also accepts an `id`. Give ids to controls in lists that change (for example rows you add and remove), so events always reach the right control. A screen can have up to 2,000 controls, nested at most 16 deep.

### Utility helpers

- `z.tile(text)`: a short line under the utility's tile in the Utilities tab ("3 saved"). An empty string clears it. While one of the utility's background services runs, the tile shows the service's own line instead ("On until 3:00 PM").
- `z.random.int(max)`: a whole number from 0 up to (not including) `max`, from the Mac's cryptographically secure random source. Use it (and `z.random.pick(array)`) instead of `Math.random()` for anything like passwords. `z.random.uuid()` makes a UUID.
- `z.text.base64Encode(text)`, `z.text.base64Decode(text)` (`null` if it isn't Base64 of text) and `z.text.sha256(text)` (hex). They work on UTF-8, so any language and emoji are fine.
- `z.qr(text, { level })`: the QR code for `text` as rows of `true`/`false` modules, without the white border (draw at least 4 modules of it yourself). `level` is `"L"`, `"M"` (default), `"Q"` or `"H"`. `null` if the text is too long. Made by macOS, offline.

### A small utility

```js
// Counts the words and characters of what you type.
let text = "";

zephydian.utility({
  start() { text = z.storage.get("text") || ""; },
  view() {
    const words = text.trim() ? text.trim().split(/\s+/).length : 0;
    return z.ui.column([
      z.ui.field({ value: text, placeholder: "Type or paste text", multiline: true, lines: 8,
                   onChange: t => { text = t; z.storage.set("text", t); } }),
      z.ui.row([
        z.ui.text(words + (words === 1 ? " word" : " words"), { style: "title" }),
        z.ui.text(text.length + " characters", { style: "secondary" }),
      ]),
      z.ui.row([z.ui.copy(text), z.ui.button("Clear", () => { text = ""; z.storage.remove("text"); })]),
    ], { spacing: 12 });
  },
});
```

## Capabilities

A capability is something a pack may do beyond its own screen and storage. Each one is written in Swift inside Zephydian; a pack can only ask for it through the SDK. A pack lists what it uses in its manifest:

```json
"capabilities": ["clipboard.write", "power.awake"]
```

- The Library shows them on the pack's row ("Uses: clipboard, keep awake"), and **asks before installing** a pack that has any, listing each one in plain words.
- Calling something the manifest doesn't declare throws an error ("add \"clipboard.write\" to \"capabilities\" in manifest.json").
- Some capabilities keep working after the panel closes (a **background service**). A service runs only while the utility has switched it on, stops when it's switched off or the utility is removed, turns the menu bar icon the accent color (except clipboard recording, which is meant to stay on), and is listed in Settings → Packs, where people can stop it.
- Where macOS has its own permission (notifications, screen recording), macOS still asks the first time it's used.

| Capability | What people see | API |
| --- | --- | --- |
| `clipboard.write` | Copy text to your clipboard | `z.clipboard.write(text, { concealed })`; `z.clipboard.writeImage(drawing)` copies a drawing as an image (returns `true` if it worked) |
| `power.awake` | Keep your Mac awake, in the background while it's switched on | `z.awake.start({ minutes, display })` (no `minutes` = until stopped; `display: true` keeps the screen on too), `z.awake.stop()`, `z.awake.status()` → `{ on, until }` (`until` in milliseconds since 1970, or `null`) |
| `files.save` | Save files to a place you choose | `z.files.save({ name, text }, done)` or `z.files.save({ name, image: drawing }, done)`. macOS's save dialog asks where; `done(saved)` gets `true` or `false`. The pack never learns where the file went. |
| `color.sample` | Read the color of a spot on the screen you pick | `z.color.sample(done)` shows macOS's color loupe; `done(color)` gets `{ hex, r, g, b, a }` (sRGB, 0–255), or `null` if the person pressed Esc. |

| `timers` | Run timers in the background and play a sound when they end | `z.timers.start({ label, seconds, sound, chain })` → id. `chain` is a list of `{ label, seconds }` phases that start one after another (a focus cycle). `z.timers.list()` → `[{ id, label, seconds, paused, endsAt, remaining, phase, phases, sound }]` (times in ms), `z.timers.pause(id)`, `resume(id)`, `cancel(id)`, `z.timers.finished()` → the last day's `{ label, at }`, `z.timers.sounds()` and `z.timers.preview(sound)`. Timers are kept if Zephydian quits. |
| `notifications` | Show notifications (macOS asks you first) | With `timers`: a notification when each timer ends. |
| `clipboard.read` | Read what you copy, in the background while it's switched on | `z.history.record(on)`, `z.history.recording()`, `z.history.items({ query })` → `[{ id, kind, text, image, width, height, appName, at, pinned }]`, `z.history.copy(id)`, `pin(id, on)`, `remove(id)`, `clear()` (keeps pinned), `apps()` and `ignore(appID, on)`. Zephydian records text and images (never files, and never what password managers mark private), keeps the last 200 plus pinned items on this Mac, and deletes them when the pack is removed. Show an item's picture with a list row's `image`. |
| `shortcut` | Open itself with a keyboard shortcut you choose | Put `z.ui.shortcut(label)` in your view: a field where the person records any key combination, with a warning under it if macOS, most apps' menus, another Zephydian shortcut or another app already uses it. `z.shortcut.get()` → the label (like "⌥⇧4") or `null`, `z.shortcut.clear()`. Pressing it opens the panel on the pack, then (SDK 4) calls its `shortcut()`. |
| `system.stats` | Read CPU, memory, disk, battery and network use | `z.system.stats()` → `{ cpu: { user, system, cores }, memory: { used, total, pressure }, disk: { free, total }, battery: { present, level, charging, pluggedIn, minutesLeft, minutesToFull }, network: { in, out }, uptime }`. CPU and network (bytes per second) are measured since the previous call, so call it on a steady loop, only while on screen. There are no per-app figures. |

A **drawing** for images is `{ width, height, scale, draw(g, width, height) }`, using the same drawing API as games. `scale` (1–4, default 2) is pixels per point. Theme colors aren't meaningful outside the panel, so exported drawings should use fixed colors like `"#000000"`.

| `dictionary` | Look up words in the dictionary and thesaurus that come with macOS, and say them aloud | See [Words and copied text](#words-and-copied-text-sdk-4). SDK 4. |
| `clipboard.text` | Read the text you've copied, only while it's on screen | `z.clipboard.readText()` → the text on the clipboard (up to 2,000 characters), or `null`. It gives `null` while the utility is off screen. SDK 4. |
| `windows` | Open its own window (Zephydian shows in the Dock while it's open) | See [Windows and image editing](#windows-and-image-editing-sdk-3). SDK 3. |
| `images.edit` | Open your screenshots, an image you pick or one you paste, and save the edited copy where you choose | `z.images`, see [Windows and image editing](#windows-and-image-editing-sdk-3). SDK 3. |
| `screen.capture` | Take pictures of your screen (macOS asks you first) and save them in Pictures/Screenshots or a folder you choose | `z.screen.capture(mode, done)` with `"area"`, `"window"` or `"screen"`: Zephydian hides the panel, shows its own selection (Esc cancels), waits the delay, captures (leaving its own windows out) and shows a preview card with Copy, Save, Edit and Close; left alone, the shot is copied. `done({ id })` or `done({ error })`. `z.screen.permission()`, `requestPermission()`, `prefs()` / `setPrefs({ delay, pointer, sound, format, autoCopy })` (delay 0, 3, 5 or 10; format `"png"` or `"jpeg"`; `autoCopy` copies every shot as soon as it's taken), `folder()` → `{ label, custom }`, `chooseFolder(done)`, `resetFolder()`, `openFolder()`, `shots()` → this session's `[{ id, width, height, at, saved, image }]`, `copy(id)`, `save(id)` → file name, `saveAs(id, done)`, `delete(id)` (a saved file goes to the Trash), `canEdit()` and `edit(id)` (opens the installed image editor, such as Markup, in its own window). A pack with `shortcut` and `screen.capture` takes an Area screenshot when its shortcut is pressed. |

`windows` and `images.edit` (SDK 3) are described in the next section.

## Windows and image editing (SDK 3)

A utility with the `windows` capability can open **its own window**: a normal, resizable Mac window, outside the panel. While any such window is open, Zephydian shows in the Dock and in ⌘-Tab, and it goes back to being a menu bar app when the last one closes.

Each window runs a **separate copy** of your `main.js`. Instead of the utility object, that copy uses the object you put under `window`:

```js
zephydian.utility({
  view() { … },                       // the panel, as before
  window: {
    start(input) { },                 // once, with what z.window.open() was given
    view() { },                       // required: the window's screen, from z.ui controls
    key(e) { },                       // keys, including Esc and ⌘ combinations (e.command)
    undo() { }, redo() { },           // ⌘Z and ⇧⌘Z; return true if something changed
    shouldClose() { },                // return false to keep the window open (ask first, then z.window.close())
  },
});
```

- `z.window.open(input)` (from the panel): opens a new window. `input` is a small JSON object, such as `{ image: id }`. The panel hides.
- In the window: `z.window.isWindow`, `z.window.input`, `z.window.title(text)`, `z.window.edited(on)` (the dot in the close button), `z.window.close()` and `z.window.confirm({ title, message, button, destructive }, done)`, a standard alert with your button and Cancel, where `done(ok)` gets `true` for your button.
- Keys: letters, digits, arrows, Enter, Backspace and Esc go to `key(e)`, and so do ⌘ combinations with `e.command` true. The exceptions are ⌘W (close), ⌘Q, ⌘H, ⌘M and ⌘, (the app's own), and ⌘Z/⇧⌘Z (`undo()`/`redo()`). While a text field has the cursor, it gets its keys as usual.
- Closing the window stops that copy of the pack completely.

### Controls for windows

- `z.ui.toolbar(children, { vertical })`: a floating bar of controls on Liquid Glass (a frosted bar in Frosted mode). `vertical: true` makes a tool rail. Buttons inside it can take `selected: true` (the current tool), `badge: "A"` (its key, in the corner), `bar: 3.4` (a line-weight glyph of that thickness instead of a symbol) and `style: "prominent"` (the main action).
- `z.ui.menu(label, items, selected, onSelect(index), { symbol, onPress })`: a button with a menu of choices, ticked at `selected`. With `onPress`, clicking the button does that and its arrow opens the menu (Save, with Save As… in the menu).
- `z.ui.logo({ size })`: Zephydian's jet logo, `size` points tall (12–96), in the text color.
- `z.ui.band(left, center, right)`: a row whose middle is centered on the whole row, whatever the sides hold. Any slot can be `null`.
- `z.ui.row(children, { fill: true })`: a row that takes all the height it's given, aligned to the top (a tool rail next to a fit canvas).
- `z.ui.swatch(color, { shape: "circle" })`: a color dot, ringed when `selected`.
- `z.window.appearance("dark")` keeps the window dark in light mode too (a photo editor's artboard); `"auto"` follows the app.
- `z.window.choose({ title, message, buttons: [{ label, destructive }] }, done)`: an alert with up to three buttons and Cancel. `done(index)` gets the button's index, or `-1` for Cancel.
- `z.ui.canvas({ fit: { width, height }, draw(g), … })`: with `fit`, the canvas takes all the space left in the window and draws in its own units (for an image, its pixels). It's scaled to fit, never enlarged past one point per unit, and centered. Its extra options:
  - `onPointer(e)` gets `{ type: "down" | "move" | "up", x, y, shift, option, command, clicks, scale }` in canvas units while the button is held. `scale` is screen points per canvas unit, so handles can be grabbed at the same size on screen at any zoom.
  - `onHover(e)` (the same object, `type: "hover"`) comes as the pointer moves with no button held. Use it only while it matters, such as for changing `cursor` over handles, because every move calls into the pack.
  - `onLayout({ scale })` comes whenever the canvas's scale changes, so you can draw handles and lines at a fixed size on screen.
  - `ink: { color, width, opacity }` draws a freehand line natively while the pointer is down (so it keeps up with the hand), then calls `onStroke({ points: [[x, y], …], shift })` with the line already simplified.
  - `textEdit: { id, x, y, text, size, color }` puts a text field on the canvas at `x, y` (the middle of the line). It calls `onTextChange(text)` as you type and `onTextEnd(text)` when you press Enter or Esc, or click elsewhere.
  - `cursor`: `"crosshair"`, `"text"`, `"move"`, `"pointer"`, `"resize-nwse"`, `"resize-nesw"`, `"resize-ns"`, `"resize-ew"`, or the arrow if you leave it out.

### Images (`images.edit`)

The picture's pixels never reach JavaScript. A pack gets an **id** (`"image:…"`), draws it with `g.image(id, …)`, and hands a **drawing** back to Zephydian, which turns it into the finished image, one pixel per unit (`scale: 1`).

| Call | What it does |
| --- | --- |
| `z.images.screenshots()` | This session's screenshots: `[{ id, width, height, at, saved, image }]`. `image` is a thumbnail for a list row. |
| `z.images.fromScreenshot(id)` | A copy of a screenshot to edit → `{ id, name, width, height, source, saved }`, or `null`. |
| `z.images.open(done)` | The open dialog for one image file. `done(info)` gets the same object, or `null`. |
| `z.images.paste()` | The image on the clipboard (read when the person clicks), or `null`. |
| `z.images.info(id)` | The object above. `source` is `"screenshot"`, `"file"` or `"clipboard"`, and `saved` is the file's name or `null`. |
| `z.images.copy(drawing)` | Copies the finished image (also needs `clipboard.write`). |
| `z.images.save(id, drawing)` | Saves over where the image came from. For a screenshot, that's its file, or a new file in Screenshot's folder. For an opened file, it's that file (PNG, JPEG or TIFF). Returns the file's name, or `null` (a pasted image has nowhere to go: use `saveAs`). |
| `z.images.saveAs(id, drawing, done)` | The save dialog (also needs `files.save`). |
| `z.images.update(id, drawing)` | Gives a screenshot its edited picture without saving, so Screenshot's list and Copy use the edit. |
| `z.images.discard(id)` | Deletes a screenshot, and moves its saved file to the Trash. Opened files are never deleted. |

A utility with `"handles": ["image"]` in its manifest is the one a screenshot's Edit button opens: its window starts with `{ image: id }`.

## Words and copied text (SDK 4)

With the `dictionary` capability, a utility reads the **New Oxford American Dictionary** and the **Oxford American Writer's Thesaurus** that come with macOS. Nothing is downloaded, and lookups work offline.

| Call | What it returns |
| --- | --- |
| `z.dictionary.define(word)` | `{ word, found, entries }`. Each entry is `{ headword, homograph, syllables, pronunciation, groups, phrases, derivatives, origin }`. A group is one part of speech, `{ pos, forms, senses }`. A sense is `{ label, text, examples, subsenses }`, where `label` is something like `"informal"` or `"with object"`. A phrase is `{ phrase, senses }`, and a derivative is `{ word, pos }`. When `found` is `false`, `suggestions` lists words it might be. `headword` can differ from what was typed ("went" gives "go"). |
| `z.dictionary.synonyms(word)` | `{ word, found, entries }`. Each entry is `{ headword, groups: [{ pos, senses }] }`, and a sense is `{ example, synonyms: [{ word, core }], labeled: [{ label, words }], antonyms }`. `core` marks the closest synonyms, and `labeled` holds groups such as "informal" or "British English". |
| `z.dictionary.suggest(word)` | Words `word` could be the start of, then spelling guesses. |
| `z.dictionary.status()` | `{ dictionary, thesaurus }`: whether each one is on this Mac. |
| `z.dictionary.speak(word)` | Says the word with the Mac's voice. |
| `z.dictionary.open(word)` | Shows the word in Apple's Dictionary app. |

If a book isn't on the Mac, a lookup returns `available: false`. People can turn it on in the Dictionary app's Settings, and macOS downloads it.

`clipboard.text` (above) lets a utility read the copied text when it's on screen, for example to look up the word someone just copied. Together with `shortcut`, the utility's `shortcut()` can do that as soon as the shortcut opens it.

## A complete example

`packs/games/lights/main.js`, a 5×5 Lights Out:

```js
const N = 5;
let board, moves;

function newGame() {
  board = Array.from({ length: N * N }, () => false);
  for (let i = 0; i < 12; i++) flip(Math.floor(Math.random() * N * N), false);
  moves = 0;
  update();
}

function flip(i, counts = true) {
  const r = Math.floor(i / N), c = i % N;
  for (const [dr, dc] of [[0, 0], [1, 0], [-1, 0], [0, 1], [0, -1]]) {
    const rr = r + dr, cc = c + dc;
    if (rr >= 0 && rr < N && cc >= 0 && cc < N) board[rr * N + cc] = !board[rr * N + cc];
  }
  if (counts) moves++;
}

function update() {
  const best = z.best.score();
  z.score(`${moves} moves`);
  z.storage.set("game", { board, moves });
  if (board.every(on => !on)) {
    z.best.submitScore(Math.max(1, 100 - moves));
    z.overlay({ title: "Lights out!", subtitle: `${moves} moves`,
                buttons: [{ label: "Play again", prominent: true, action: () => { z.overlay(null); newGame(); } }] });
  }
  z.redraw();
}

function cell() {
  const size = Math.min(z.width, z.height) - 24;
  return { size: size / N, x0: (z.width - size) / 2, y0: (z.height - size) / 2 };
}

zephydian.game({
  start() {
    const saved = z.storage.get("game");
    if (saved) { board = saved.board; moves = saved.moves; update(); } else newGame();
  },
  draw(g) {
    const { size, x0, y0 } = cell();
    board.forEach((on, i) => {
      const x = x0 + (i % N) * size, y = y0 + Math.floor(i / N) * size;
      g.rect(x + 3, y + 3, size - 6, size - 6, { radius: 8, fill: on ? "accent" : "fill" });
    });
  },
  click(e) {
    const { size, x0, y0 } = cell();
    const c = Math.floor((e.x - x0) / size), r = Math.floor((e.y - y0) / size);
    if (r < 0 || r >= N || c < 0 || c >= N) return;
    flip(r * N + c);
    update();
  },
  key(e) {
    if (e.key !== "r") return false;
    newGame();
    return true;
  },
});
```

## Testing your pack

**Debug builds** of Zephydian (built from Xcode, not releases) also load unsigned packs from a developer folder:

```
~/Library/Containers/com.ahmastan.zephydian/Data/Library/Application Support/Zephydian/Packs/dev/
```

1. Build and run Zephydian from Xcode (see `CONTRIBUTING.md`).
2. Copy your pack folder (for example `packs/games/lights`) into the `dev` folder above.
3. Open the panel. The pack appears in the Games grid (or, for a utility, the Utilities tab) with a "DEV" badge. It's read from disk again every time you open it, so after editing, go back and open it again. If the pack can't be loaded, the Xcode console says why.

Release builds never load anything from this folder. They install only signed packs from the Library.

Before opening a pull request:
- Test in light and dark mode, in both panel styles (Liquid Glass and Frosted), and with a few accent colors.
- Check the pack pauses when you hide the panel, and resumes correctly.
- Check that saved games survive closing and reopening the panel.
- Check it's playable with the keyboard where that makes sense.

## Submitting a pack

1. Add your folder under `packs/games/` or `packs/utilities/`, and run `swift scripts/packs.swift check packs`.
2. Open a pull request that says what the pack does and what you tested.
3. A maintainer reviews the code. Every line is read before merging, because the pack will run on other people's Macs.
4. After merging, the release workflow builds, signs and publishes it, and it appears in everyone's Library.

For a change to an existing pack, raise its `version` in the manifest and add a `whatsNew` line. The workflow refuses a changed pack whose version is still the same.

## How packs are published and verified

- When pack sources change on `main`, a GitHub Actions workflow checks every manifest and builds each `.zpack`.
- It writes `catalog.json`, which lists every pack with its version, size, SDK version and **SHA-256** fingerprint, and signs the catalog with an **Ed25519** key.
- Everything goes to one GitHub Release named `packs`, separate from the app releases.
- Zephydian contains only the matching public key. Before installing anything, it:
  1. checks the catalog's signature,
  2. checks that the downloaded file's SHA-256 matches the catalog,
  3. unpacks it only after both checks pass.
- The catalog also lists each pack's capabilities, so the Library can show them, and ask, before anything is downloaded.

  A pack that was changed anywhere along the way is refused.
- Zephydian goes online only when you open the Library or install something, plus at most one quiet update check a day. You can turn that check off in Settings. No information about you is sent.
