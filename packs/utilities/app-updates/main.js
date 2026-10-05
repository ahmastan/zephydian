// App Updates: checks your apps for newer versions (App Store apps through Apple's lookup,
// Homebrew packages, and apps that publish a Sparkle update feed). Homebrew ones update right
// here; App Store ones open their page; others open so their own updater can run.

const SOURCES = { appstore: "App Store", brew: "Homebrew", app: "Its own updater" };
let updates = null;
let checking = false;
let checkedAt = null;
let note = null;

function check() {
  checking = true;
  note = null;
  z.updates.check(list => {
    checking = false;
    updates = Array.isArray(list) ? list : [];
    checkedAt = Date.now();
    z.tile(updates.length ? updates.length + " update" + (updates.length === 1 ? "" : "s") : "Up to date");
  });
}

function update(u) {
  z.updates.update(u.id, r => {
    if (r && r.error) note = r.error;
    else if (r && r.opened) note = "Opened " + r.opened + ".";
    else if (r && r.ok === true) { note = u.name + " is updated."; updates = updates.filter(x => x.id !== u.id); }
    else if (r && r.ok === false) note = "Homebrew couldn't update " + u.name + ". The output is below.";
  });
}

function jobView() {
  const status = z.updates.status();
  const job = status && status.job;
  if (!job) return null;
  return z.ui.section(job.label + (job.running ? "…" : job.ok ? " · done" : " · failed"), [
    z.ui.text(job.lines.slice(-12).join("\n") || "Starting…", { style: "mono", selectable: true, id: "log" }),
    job.running ? z.ui.button("Stop", () => z.updates.cancel(), { symbol: "stop.circle" }) : null,
  ]);
}

zephydian.utility({
  start() { z.loop.start(1000); },
  tick() {},
  view() {
    if (checking) return z.ui.column([z.ui.text("Checking your apps… this takes a few seconds.", { style: "secondary", align: "center" })], { center: true, align: "center" });
    if (!updates) {
      return z.ui.column([
        z.ui.button("Check for Updates", check, { symbol: "arrow.clockwise", style: "prominent" }),
        z.ui.text("Asks the App Store, Homebrew and each app's update feed. Nothing is sent about you; only which versions exist.", { style: "caption", align: "center" }),
      ], { spacing: 12, center: true, align: "center" });
    }
    return z.ui.column([
      z.ui.row([
        z.ui.text(updates.length ? updates.length + " update" + (updates.length === 1 ? "" : "s") : "Everything is up to date.", { style: "title" }),
        z.ui.spacer(),
        z.ui.button("Check Again", check, { symbol: "arrow.clockwise" }),
      ]),
      note ? z.ui.text(note, { style: "caption", id: "note" }) : null,
      z.ui.list(updates.map(u => ({
        id: u.id, title: u.name,
        subtitle: u.installed + " → " + u.latest + " · " + SOURCES[u.source],
        image: u.source === "brew" ? undefined : "app:" + u.id,
        symbol: u.source === "brew" ? "shippingbox" : undefined,
        actions: [{ symbol: u.source === "brew" ? "arrow.down.circle" : "arrow.up.forward.app", label: u.source === "brew" ? "Update" : "Open" }],
      })), { empty: "", onAction: id => { const u = updates.find(x => x.id === id); if (u) update(u); } }),
      jobView(),
      checkedAt ? z.ui.text("Checked at " + new Date(checkedAt).toLocaleTimeString([], { hour: "numeric", minute: "2-digit" }) + ".", { style: "caption" }) : null,
    ], { spacing: 10 });
  },
});
