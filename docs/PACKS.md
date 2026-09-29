# Making a pack

New games and utilities come to Zephydian as **packs**. People install them from the **Library** inside the panel, and can remove them again. A pack is a small JavaScript program plus its data. Zephydian runs it with Apple's built-in JavaScriptCore and draws it natively, so a pack looks and feels like the rest of the app, Liquid Glass included.

This guide covers **SDK version 1**, which supports games. Utilities, and the extra abilities they need (clipboard, notifications and so on), come in a later SDK version.

- [What a pack can and can't do](#what-a-pack-can-and-cant-do)
- [Folder layout](#folder-layout)
- [manifest.json](#manifestjson)
- [The game object](#the-game-object)
- [The `z` API](#the-z-api)
- [Drawing](#drawing)
- [Colors](#colors)
- [A complete example](#a-complete-example)
- [Testing your pack](#testing-your-pack)
- [Submitting a pack](#submitting-a-pack)
- [How packs are published and verified](#how-packs-are-published-and-verified)

## What a pack can and can't do

A pack can draw on its game area, react to keys and clicks, run a game loop while it's on screen, show the standard pause/win/lose cards and message bubbles, add one menu to the header, and save a little data of its own.

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
└── utilities/             (later SDK versions)
```

`swift scripts/packs.swift check packs` checks every pack: the file list, the manifest, the icon size, the limits and the JavaScript syntax. Run it before opening a pull request.

`swift scripts/packs.swift build packs/games/lights` turns the folder into `dist/packs/lights-1.0.0.zpack`, the single file people download (a zip with a different extension). You don't need to build it yourself: the release workflow builds and publishes every pack.

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
| `name` | Shown on the tile and in the Library. **Games use a single original word** that isn't a trademarked title. |
| `kind` | `"game"` (`"utility"` arrives with a later SDK version). |
| `version` | `major.minor.patch`. Raise it with every change, or the update won't be published. |
| `sdkVersion` | The SDK version the pack needs. An app with an older SDK shows the pack as "Update Zephydian to install this". |
| `description` | One line for the Library. |
| `hint` | The controls line shown under the game. It can also be changed at runtime with `z.hint()`. |
| `pauseButton` | `true` for real-time games, to show the header's pause button. |
| `tileStat` | What the tile shows under the name: `"bestScore"`, `"bestTime"` or `"none"`. |
| `whatsNew` | A short line shown in the Library after an update. |

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
g.line(x1, y1, x2, y2, { stroke, lineWidth, cap });      // cap: "butt" | "round"
g.path([[x, y], [x, y], …], { fill, stroke, lineWidth, closed });
g.text("2048", x, y, { size, weight, color, align, font }); // align: "left" | "center" | "right"
                                                          // weight: "regular" | "medium" | "semibold" | "bold"
                                                          // font: "system" | "rounded" | "mono"
g.image("ship.png", x, y, w, h, { opacity });
g.save(); g.translate(dx, dy); g.rotate(radians); g.scale(s); g.alpha(a); g.restore();
```

`text` is positioned by the middle of its line, so `y` is the vertical center of the text. A rect, circle or path with neither `fill` nor `stroke` is filled with `"text"`. The game area has rounded corners, and nothing is drawn outside it.

## Colors

Anywhere a color is expected, you can use:
- **A theme name:** `"accent"`, `"text"`, `"secondary"`, `"fill"` or `"background"`. These follow light/dark mode and the player's accent color, so prefer them.
- **A hex color:** `"#ff9f0a"`, or `"#ff9f0a80"` with alpha.
- **An `rgba()` color:** `"rgba(255, 159, 10, 0.5)"`.

Keep text contrast at least 4.5:1, and don't use color alone to show state (for example, add a mark or a pattern too).

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
3. Open the panel. The pack appears in the Games grid with a "DEV" badge. It's read from disk again every time you open it, so after editing, go back and open it again. If the pack can't be loaded, the Xcode console says why.

Release builds never load anything from this folder. They install only signed packs from the Library.

Before opening a pull request:
- Test in light and dark mode, in both panel styles (Liquid Glass and Frosted), and with a few accent colors.
- Check the pack pauses when you hide the panel, and resumes correctly.
- Check that saved games survive closing and reopening the panel.
- Check it's playable with the keyboard where that makes sense.

## Submitting a pack

1. Add your folder under `packs/games/`, and run `swift scripts/packs.swift check packs`.
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

  A pack that was changed anywhere along the way is refused.
- Zephydian goes online only when you open the Library or install something, plus at most one quiet update check a day. You can turn that check off in Settings. No information about you is sent.
