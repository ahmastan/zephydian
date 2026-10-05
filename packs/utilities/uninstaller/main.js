// Uninstaller: pick an app, see it with the files it keeps in your Library (caches, preferences,
// containers, saved state…), untick anything to keep, and move the rest to the Trash. Nothing is
// deleted outright, so it can all be put back from the Trash.

let apps = null;          // [{ id, name, version, apple, running, size }]
let search = "";
let chosen = null;        // { id, name }
let items = null;         // [{ id, label, size, kind }] for the chosen app
let keep = {};            // item id → true when unticked
let result = null;        // a line after removing

function bytes(n) {
  if (n == null) return "";
  const units = ["B", "KB", "MB", "GB", "TB"];
  let i = 0;
  while (n >= 1000 && i < units.length - 1) { n /= 1000; i++; }
  return (n >= 100 || i === 0 ? Math.round(n) : n.toFixed(1)) + " " + units[i];
}

function loadApps() { z.apps.list(list => { apps = list || []; }); }

function choose(app) {
  chosen = app;
  items = null;
  keep = {};
  result = null;
  z.apps.leftovers(app.id, list => { items = Array.isArray(list) ? list : []; });
}

function remove() {
  const ids = items.filter(i => !keep[i.id]).map(i => i.id);
  z.apps.uninstall(chosen.id, ids, r => {
    if (r && r.error) { result = r.error; return; }
    result = r.moved + " item" + (r.moved === 1 ? "" : "s") + " moved to the Trash" + (r.failed && r.failed.length ? ". Couldn't move: " + r.failed.join(", ") : ".");
    chosen = null;
    items = null;
    loadApps();
  });
}

function listView() {
  const q = search.trim().toLowerCase();
  const shown = (apps || []).filter(a => !q || a.name.toLowerCase().includes(q));
  return z.ui.column([
    z.ui.row([
      z.ui.field({ value: search, placeholder: "Search apps", onChange: t => { search = t; }, id: "search" }),
      z.ui.button("Choose…", () => z.apps.choose(app => { if (app) choose(app); }), { symbol: "folder" }),
    ]),
    result ? z.ui.text(result, { style: "caption", id: "result" }) : null,
    apps == null
      ? z.ui.text("Finding your apps…", { style: "secondary" })
      : z.ui.list(shown.map(a => ({
          id: a.id, title: a.name, image: "app:" + a.id,
          subtitle: (a.version ? "Version " + a.version : "") + (a.apple ? " · part of macOS" : "") + (a.running ? " · open" : ""),
          detail: bytes(a.size),
        })), { empty: q ? "No app matches." : "No apps found.", onSelect: id => {
          const app = shown.find(a => a.id === id);
          if (app && !app.apple) choose(app);
          else if (app) result = app.name + " comes with macOS and can't be removed here.";
        } }),
  ], { spacing: 10 });
}

function reviewView() {
  const total = (items || []).filter(i => !keep[i.id]).reduce((s, i) => s + (i.size || 0), 0);
  return z.ui.column([
    z.ui.row([
      z.ui.button("Back", () => { chosen = null; items = null; }, { symbol: "chevron.left" }),
      z.ui.spacer(),
    ]),
    z.ui.text(chosen.name, { style: "title" }),
    items == null
      ? z.ui.text("Looking for its files…", { style: "secondary" })
      : z.ui.section("Untick anything you want to keep", items.map(i =>
          z.ui.toggle((i.kind === "app" ? "The app: " : "") + i.label + "  (" + bytes(i.size) + ")", !keep[i.id], on => { keep[i.id] = !on; }, { id: "t" + i.id }))),
    items && items.length
      ? z.ui.button("Move " + bytes(total) + " to the Trash", remove, { symbol: "trash", style: "destructive", disabled: total === 0 && items.every(i => keep[i.id]) })
      : null,
    z.ui.text("If the app is open, it's asked to quit first. Everything goes to the Trash, so you can put it back.", { style: "caption" }),
  ], { spacing: 10 });
}

zephydian.utility({
  start() { loadApps(); z.loop.start(3000); },
  resume() { loadApps(); },
  tick() { if (apps && apps.some(a => a.size == null)) loadApps(); },   // sizes arrive in the background
  view() { return chosen ? reviewView() : listView(); },
});
