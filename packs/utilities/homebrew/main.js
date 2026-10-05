// Homebrew: search and install formulae and casks, see and remove what's installed, and run
// update, upgrade everything and cleanup, with Homebrew's output shown live. Needs Homebrew
// (brew.sh); installers that ask for your password still need the Terminal.

const TABS = ["Installed", "Search", "Maintenance"];
let tab = 0;
let installed = null;
let outdated = {};
let query = "";
let results = null;
let searching = false;
let note = null;

function loadInstalled() {
  z.brew.installed(r => { installed = (r && r.items) || []; });
  z.brew.outdated(r => {
    outdated = {};
    for (const o of (r && r.items) || []) outdated[o.name] = o.latest;
  });
}

function search() {
  if (!query.trim()) return;
  searching = true;
  z.brew.search(query.trim(), r => { searching = false; results = r || { formulae: [], casks: [] }; });
}

function after(r, done) {
  if (r && r.error) note = r.error;
  else note = r && r.ok ? done : "Homebrew reported a problem; see its output below.";
  loadInstalled();
}

function jobView() {
  const job = z.brew.status().job;
  if (!job) return null;
  return z.ui.section(job.label + (job.running ? "…" : job.ok ? " · done" : " · failed"), [
    z.ui.text(job.lines.slice(-14).join("\n") || "Starting…", { style: "mono", selectable: true, id: "log" }),
    job.running ? z.ui.button("Stop", () => z.brew.cancel(), { symbol: "stop.circle" }) : null,
  ]);
}

function installedView() {
  if (!installed) return [z.ui.text("Reading what's installed…", { style: "secondary" })];
  const rows = installed.map(p => ({
    id: (p.cask ? "c:" : "f:") + p.name,
    title: p.name,
    subtitle: (p.cask ? "App (cask)" : "Formula") + " · " + p.version + (outdated[p.name] ? " · " + outdated[p.name] + " available" : ""),
    symbol: p.cask ? "app.badge" : "terminal",
    actions: (outdated[p.name] ? [{ symbol: "arrow.down.circle", label: "Upgrade" }] : []).concat([{ symbol: "trash", label: "Uninstall" }]),
  }));
  return [z.ui.list(rows, {
    empty: "Nothing installed yet.",
    onAction: (id, i) => {
      const cask = id.startsWith("c:"), name = id.slice(2);
      const label = rows.find(r => r.id === id).actions[i].label;
      if (label === "Upgrade") z.brew.upgrade(name, cask, r => after(r, name + " upgraded."));
      else z.brew.uninstall(name, cask, r => after(r, name + " removed."));
    },
  })];
}

function searchView() {
  const list = [];
  if (results) {
    for (const name of results.formulae) list.push({ id: "f:" + name, title: name, subtitle: "Formula", symbol: "terminal", actions: [{ symbol: "plus.circle", label: "Install" }] });
    for (const name of results.casks) list.push({ id: "c:" + name, title: name, subtitle: "App (cask)", symbol: "app.badge", actions: [{ symbol: "plus.circle", label: "Install" }] });
  }
  return [
    z.ui.row([
      z.ui.field({ value: query, placeholder: "Search formulae and casks", onChange: t => { query = t; }, onSubmit: search, id: "q" }),
      z.ui.button("Search", search, { symbol: "magnifyingglass", disabled: searching }),
    ]),
    searching ? z.ui.text("Searching…", { style: "secondary" }) : null,
    results ? z.ui.list(list, { empty: "Nothing found.", onAction: id => {
      const cask = id.startsWith("c:"), name = id.slice(2);
      z.brew.install(name, cask, r => after(r, name + " installed."));
    } }) : null,
  ];
}

function maintenanceView() {
  return [
    z.ui.section(null, [
      z.ui.row([z.ui.text("Update Homebrew"), z.ui.spacer(), z.ui.button("Update", () => z.brew.update(r => after(r, "Homebrew is up to date.")), { symbol: "arrow.clockwise" })]),
      z.ui.text("Gets the latest list of packages and versions.", { style: "caption" }),
      z.ui.row([z.ui.text("Upgrade everything"), z.ui.spacer(), z.ui.button("Upgrade All", () => z.brew.upgradeAll(r => after(r, "Everything is upgraded.")), { symbol: "arrow.down.circle" })]),
      z.ui.text("Installs every newer version. Run Update first.", { style: "caption" }),
      z.ui.row([z.ui.text("Clean up"), z.ui.spacer(), z.ui.button("Clean Up", () => z.brew.cleanup(r => after(r, "Old versions and downloads removed.")), { symbol: "sparkles" })]),
      z.ui.text("Removes old versions and downloaded installers.", { style: "caption" }),
    ]),
  ];
}

zephydian.utility({
  start() { if (z.brew.status().installed) loadInstalled(); z.loop.start(1000); },
  resume() { if (z.brew.status().installed) loadInstalled(); },
  tick() {},
  view() {
    const status = z.brew.status();
    if (!status.installed) {
      return z.ui.column([
        z.ui.text("Homebrew isn't installed", { style: "title" }),
        z.ui.text("Homebrew is a free package manager for macOS. Install it from brew.sh (one command in the Terminal), then open this again.", { style: "secondary" }),
      ], { spacing: 8 });
    }
    const busy = status.job && status.job.running;
    const content = [installedView, searchView, maintenanceView][tab]();
    return z.ui.column([
      z.ui.segmented(TABS, tab, i => { tab = i; }),
      busy ? z.ui.text("Working… other actions wait until this finishes.", { style: "caption" }) : null,
      note ? z.ui.text(note, { style: "caption", id: "note" }) : null,
      ...content,
      jobView(),
    ], { spacing: 10 });
  },
});
