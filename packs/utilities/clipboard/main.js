// Clipboard: a history of the text and images you copy. The recording itself is done by Zephydian
// (z.history) while this utility has it switched on, so it works with the panel closed. The history
// stays on this Mac, skips what password managers mark private, and is deleted when Clipboard is removed.

let query = "";

function ago(ms) {
  const s = Math.max(0, (Date.now() - ms) / 1000);
  if (s < 60) return "just now";
  if (s < 3600) return Math.floor(s / 60) + " min ago";
  if (s < 86400) return Math.floor(s / 3600) + " h ago";
  const d = Math.floor(s / 86400);
  return d === 1 ? "yesterday" : d + " days ago";
}

function title(item) {
  if (item.kind === "image") return "Image · " + item.width + " × " + item.height;
  const line = item.text.trim().split("\n")[0].replace(/\s+/g, " ");
  return line.length > 90 ? line.slice(0, 90) + "…" : line;
}

function subtitle(item) {
  const extra = item.kind === "text" && item.text.includes("\n") ? " · " + item.text.split("\n").length + " lines" : "";
  return [item.appName, ago(item.at)].filter(Boolean).join(" · ") + extra;
}

function copy(id) {
  if (z.history.copy(id)) z.toast("Copied");
  else z.toast("Those files aren't there any more");
}

// Puts the item into the app you were in (the panel closes). Without Accessibility it's only copied.
function paste(id) {
  if (!z.history.paste(id)) z.toast("Those files aren't there any more");
}

function history() {
  const items = z.history.items({ query });
  return z.ui.list(items.map(item => ({
    id: item.id,
    title: title(item),
    subtitle: subtitle(item),
    image: item.image,
    symbol: item.pinned ? "pin.fill" : item.kind === "image" ? "photo" : item.kind === "file" ? "doc" : "text.alignleft",
    actions: [
      { symbol: "doc.on.doc", label: "Copy" },
      { symbol: item.pinned ? "pin.slash" : "pin", label: item.pinned ? "Unpin" : "Pin" },
      { symbol: "trash", label: "Delete" },
    ],
  })), {
    empty: query ? "Nothing matches “" + query + "”." : z.history.recording()
      ? "Copy something and it appears here. Click an item to paste it; press 1–9 for the first nine."
      : "Turn on Record to keep what you copy.",
    onSelect: paste,
    onAction: (id, i) => {
      if (i === 0) copy(id);
      else if (i === 1) z.history.pin(id, !items.find(x => x.id === id).pinned);
      else z.history.remove(id);
    },
  });
}

// Clipboard's page in Zephydian's Settings window.
function settings() {
  const apps = z.history.apps();
  return z.ui.column([
    z.ui.section(null, [
      z.ui.shortcut("Shortcut"),
      z.ui.text("The shortcut opens the panel straight on Clipboard, from any app.", { style: "caption" }),
    ]),
    z.ui.section("Don't record copies from", apps.length
      ? apps.map(a => z.ui.toggle(a.name, a.ignored, on => z.history.ignore(a.id, on), { id: "app-" + a.id }))
      : [z.ui.text("Apps you copy from appear here, so you can leave them out.", { style: "caption" })]),
  ]);
}

zephydian.utility({
  start() {
    z.storage.remove("showSettings");   // the old in-panel settings switch (before 1.1)
    z.loop.start(30000);      // keeps "2 min ago" current while it's on screen
  },

  tick() {},

  // 1–9 paste the first nine items (while the search field isn't being typed in).
  key(e) {
    const n = Number(e.key);
    if (!(n >= 1 && n <= 9)) return false;
    const item = z.history.items({ query })[n - 1];
    if (item) paste(item.id);
    return !!item;
  },

  view() {
    const recording = z.history.recording();
    return z.ui.column([
      z.ui.section(null, [
        z.ui.toggle("Record what I copy", recording, on => z.history.record(on), { id: "record" }),
        z.ui.text(recording
          ? "Recording. Passwords from password managers are never saved."
          : "Paused. Nothing you copy is kept.", { style: "caption" }),
      ]),
      z.ui.row([
        z.ui.field({ value: query, placeholder: "Search", id: "search", onChange: t => { query = t; } }),
        z.ui.button("Clear", () => z.history.clear(), { symbol: "trash", disabled: !z.history.items({}).some(i => !i.pinned) }),
      ]),
      history(),
      z.ui.text("Kept only on this Mac, the last 200 items plus pinned ones. Clear keeps pinned items; removing Clipboard deletes everything.", { style: "caption" }),
    ], { spacing: 10 });
  },

  settings: { view: settings },
});
