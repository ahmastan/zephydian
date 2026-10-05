// Chat Files: the photos, videos and files that Messages, WhatsApp, Telegram, Signal, Discord,
// Slack and Teams keep, older than an age you choose. Tick apps, review the sizes, and move them
// to the Trash. Messages' files are protected by macOS until Zephydian has Full Disk Access.

const AGES = [{ label: "1 month", days: 30 }, { label: "3 months", days: 90 }, { label: "6 months", days: 180 }, { label: "1 year", days: 365 }];
let age = 1;
let apps = null;          // [{ app, size, count, blocked, ids }]
let picked = {};
let scanning = false;
let result = null;

function bytes(n) {
  const units = ["B", "KB", "MB", "GB", "TB"];
  let i = 0;
  while (n >= 1000 && i < units.length - 1) { n /= 1000; i++; }
  return (n >= 100 || i === 0 ? Math.round(n) : n.toFixed(1)) + " " + units[i];
}

function scan() {
  scanning = true;
  result = null;
  z.clean.chats(AGES[age].days, list => {
    scanning = false;
    apps = Array.isArray(list) ? list : [];
    picked = {};
    for (const a of apps) picked[a.app] = !a.blocked && a.count > 0;
  });
}

function clean() {
  const ids = apps.filter(a => picked[a.app]).flatMap(a => a.ids);
  z.clean.trash(ids, r => {
    result = (r.moved || 0) + " file" + (r.moved === 1 ? "" : "s") + " moved to the Trash.";
    apps = null;
  });
}

zephydian.utility({
  start() { age = z.storage.get("age") ?? 1; },
  view() {
    const controls = [
      z.ui.picker("Older than", AGES.map(a => a.label), age, i => { age = i; z.storage.set("age", i); apps = null; }),
    ];
    if (scanning) return z.ui.column([...controls, z.ui.text("Looking…", { style: "secondary", align: "center" })], { spacing: 12, center: true, align: "center" });
    if (!apps) {
      return z.ui.column([
        ...controls,
        result ? z.ui.text(result, { align: "center", id: "result" }) : null,
        z.ui.button("Scan", scan, { symbol: "magnifyingglass", style: "prominent" }),
        z.ui.text("Only files you received or saved in these apps, older than the age above. Chats themselves aren't touched. Everything goes to the Trash.", { style: "caption", align: "center" }),
      ], { spacing: 12, center: true, align: "center" });
    }
    const size = apps.filter(a => picked[a.app]).reduce((s, a) => s + a.size, 0);
    const blocked = apps.some(a => a.blocked);
    return z.ui.column([
      ...controls,
      apps.length ? z.ui.section(null, apps.map(a => z.ui.row([
        a.blocked
          ? z.ui.text(a.app + ": needs Full Disk Access", { style: "secondary" })
          : z.ui.toggle(a.app + " (" + a.count + " file" + (a.count === 1 ? "" : "s") + ")", !!picked[a.app], on => { picked[a.app] = on; }, { id: "a" + a.app }),
        z.ui.spacer(),
        z.ui.text(a.blocked ? "" : bytes(a.size), { style: "mono" }),
      ]))) : z.ui.text("None of the chat apps Zephydian knows are on this Mac.", { style: "secondary" }),
      blocked ? z.ui.row([
        z.ui.text("macOS protects some chat files. Allow Zephydian under Full Disk Access, then scan again.", { style: "caption" }),
        z.ui.button("Open Settings", () => z.clean.openFullDiskAccess(), { symbol: "lock.open" }),
      ]) : null,
      z.ui.row([
        z.ui.button("Scan Again", scan, { symbol: "arrow.clockwise" }),
        z.ui.spacer(),
        z.ui.button("Move " + bytes(size) + " to the Trash", clean, { symbol: "trash", style: "destructive", disabled: size === 0 }),
      ]),
    ], { spacing: 12 });
  },
});
