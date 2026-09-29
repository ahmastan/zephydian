// Clipboard: a history of the text and images you copy. The recording itself is done by Zephydian
// (z.history) while this utility has it switched on, so it works with the panel closed. The history
// stays on this Mac, skips what password managers mark private, and is deleted when Clipboard is removed.

let query = "";
let showSettings = false;

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
}

function history() {
  const items = z.history.items({ query });
  return z.ui.list(items.map(item => ({
    id: item.id,
    title: title(item),
    subtitle: subtitle(item),
    image: item.image,
    symbol: item.pinned ? "pin.fill" : item.kind === "image" ? "photo" : "text.alignleft",
    actions: [
      { symbol: "doc.on.doc", label: "Copy" },
      { symbol: item.pinned ? "pin.slash" : "pin", label: item.pinned ? "Unpin" : "Pin" },
      { symbol: "trash", label: "Delete" },
    ],
  })), {
    empty: query ? "Nothing matches “" + query + "”." : z.history.recording()
      ? "Copy something and it appears here. Click an item to copy it again."
      : "Turn on Record to keep what you copy.",
    onSelect: copy,
    onAction: (id, i) => {
      if (i === 0) copy(id);
      else if (i === 1) z.history.pin(id, !items.find(x => x.id === id).pinned);
      else z.history.remove(id);
    },
  });
}

function settings() {
  const apps = z.history.apps();
  return z.ui.section("Settings", [
    z.ui.shortcut("Shortcut"),
    z.ui.text("The shortcut opens the panel straight on Clipboard, from any app.", { style: "caption" }),
    z.ui.divider(),
    z.ui.text("Don't record copies from", { style: "body" }),
    apps.length
      ? z.ui.column(apps.map(a => z.ui.toggle(a.name, a.ignored, on => z.history.ignore(a.id, on), { id: "app-" + a.id })), { spacing: 6 })
      : z.ui.text("Apps you copy from appear here, so you can leave them out.", { style: "caption" }),
  ]);
}

zephydian.utility({
  start() {
    showSettings = !!z.storage.get("showSettings");
    z.loop.start(30000);      // keeps "2 min ago" current while it's on screen
  },

  tick() {},

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
        z.ui.button(showSettings ? "Done" : "Settings", () => { showSettings = !showSettings; z.storage.set("showSettings", showSettings); },
                    { symbol: showSettings ? "checkmark" : "gearshape" }),
      ]),
      showSettings ? settings() : history(),
      z.ui.text("Kept only on this Mac, the last 200 items plus pinned ones. Clear keeps pinned items; removing Clipboard deletes everything.", { style: "caption" }),
    ], { spacing: 10 });
  },
});
