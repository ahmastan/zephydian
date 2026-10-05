// Cleaner: scans caches, logs, data left by removed apps, old downloads and Xcode build files,
// shows what each holds, and moves what you tick to the Trash. Its settings page can set a weekly
// or monthly reminder (a notification only; nothing moves until you review).

let categories = null;    // [{ id, title, note, selected, size, count, items }]
let picked = {};          // category id → on
let open = {};            // category id → showing its items
let skip = {};            // item id → unticked
let result = null;
let scanning = false;

function bytes(n) {
  const units = ["B", "KB", "MB", "GB", "TB"];
  let i = 0;
  while (n >= 1000 && i < units.length - 1) { n /= 1000; i++; }
  return (n >= 100 || i === 0 ? Math.round(n) : n.toFixed(1)) + " " + units[i];
}

function scan() {
  scanning = true;
  result = null;
  z.clean.scan(list => {
    scanning = false;
    categories = Array.isArray(list) ? list : [];
    picked = {};
    skip = {};
    for (const c of categories) picked[c.id] = c.selected && c.count > 0;
  });
}

function chosenIDs() {
  return (categories || []).filter(c => picked[c.id]).flatMap(c => c.items.map(i => i.id).filter(id => !skip[id]));
}

function chosenSize() {
  return (categories || []).filter(c => picked[c.id]).reduce((s, c) => s + c.items.filter(i => !skip[i.id]).reduce((t, i) => t + i.size, 0), 0);
}

function clean() {
  const ids = chosenIDs();
  z.clean.trash(ids, r => {
    result = (r.moved || 0) + " item" + (r.moved === 1 ? "" : "s") + " moved to the Trash." + (r.failed && r.failed.length ? " Some were in use and stayed." : " Empty the Trash to free the space.");
    categories = null;
  });
}

function categoryView(c) {
  const lines = [
    z.ui.row([
      z.ui.toggle(c.title, !!picked[c.id], on => { picked[c.id] = on; }, { id: "c" + c.id }),
      z.ui.spacer(),
      z.ui.text(c.count ? bytes(c.size) : "Nothing", { style: "mono" }),
    ]),
    z.ui.text(c.note, { style: "caption" }),
  ];
  if (c.count) {
    lines.push(z.ui.disclosure("Show " + c.count + " item" + (c.count === 1 ? "" : "s"), !!open[c.id], v => { open[c.id] = v; },
      c.items.slice(0, 60).map(i => z.ui.toggle(i.label + "  (" + bytes(i.size) + ")", !skip[i.id], on => { skip[i.id] = !on; }, { id: "i" + i.id }))));
  }
  return z.ui.section(null, lines);
}

zephydian.utility({
  start() {},
  view() {
    if (scanning) return z.ui.column([z.ui.text("Looking through your Library… this can take a minute.", { style: "secondary", align: "center" })], { center: true, align: "center" });
    if (!categories) {
      return z.ui.column([
        result ? z.ui.text(result, { style: "body", align: "center", id: "result" }) : null,
        z.ui.button("Scan", scan, { symbol: "magnifyingglass", style: "prominent" }),
        z.ui.text("Nothing is moved until you review it, and everything goes to the Trash. macOS's own caches are left alone.", { style: "caption", align: "center" }),
      ], { spacing: 12, center: true, align: "center" });
    }
    const size = chosenSize();
    return z.ui.column([
      ...categories.map(categoryView),
      z.ui.row([
        z.ui.button("Scan Again", scan, { symbol: "arrow.clockwise" }),
        z.ui.spacer(),
        z.ui.button("Move " + bytes(size) + " to the Trash", clean, { symbol: "trash", style: "destructive", disabled: size === 0 }),
      ]),
    ], { spacing: 10 });
  },

  settings: {
    view() {
      const current = z.clean.reminder();
      const options = ["off", "weekly", "monthly"];
      return z.ui.section("Reminder", [
        z.ui.picker("Remind me to clean", ["Never", "Every week", "Every month"], Math.max(0, options.indexOf(current)), i => z.clean.reminder(options[i])),
        z.ui.text("A notification says how much could be cleaned (only when it's more than 200 MB). Nothing is moved until you open Cleaner and review.", { style: "caption" }),
      ]);
    },
  },
});
