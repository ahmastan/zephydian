// System: CPU, GPU, memory, temperatures, battery and power, the busiest apps, network and disk.
// It reads the numbers once a second only while it's on screen (the loop stops when the panel
// hides), so it costs nothing the rest of the time. The graphs use Zephydian's history, which also
// fills while the menu bar readouts are on, so they can show up to ten minutes.

const RANGES = [{ label: "1 min", seconds: 60 }, { label: "10 min", seconds: 600 }];
let stats = null;
let history = [];
let range = 0;
let publicIP = null;      // null: not asked; "…": asking; text: the address
let speed = null;         // null: not run; "running"; { download, upload, latency } or { error }

function read() {
  stats = z.system.stats();
  history = z.system.history();
}

// MARK: Formatting

/// Disk sizes count in 1000s (like Finder); memory in 1024s (like Activity Monitor), via `base`.
function bytes(n, base = 1000) {
  const units = ["B", "KB", "MB", "GB", "TB"];
  let i = 0;
  while (n >= base && i < units.length - 1) { n /= base; i++; }
  return (n >= 100 || i === 0 ? Math.round(n) : n.toFixed(1)) + " " + units[i];
}
const rate = n => bytes(n) + "/s";
const percent = n => Math.round(n) + "%";
const degrees = n => Math.round(n) + "°C";
const watts = n => (n >= 10 ? Math.round(n) : n.toFixed(1)) + " W";

function span(seconds) {
  const m = Math.floor(seconds / 60), h = Math.floor(m / 60), d = Math.floor(h / 24);
  if (d) return d + (d === 1 ? " day " : " days ") + (h % 24) + " h";
  if (h) return h + " h " + (m % 60) + " min";
  return m + " min";
}

// MARK: Pictures

/// A bar showing a fraction, in the accent color on the fill color.
function bar(fraction, id) {
  return z.ui.canvas({ height: 8, id, draw(g, w, h) {
    g.rect(0, 0, w, h, { fill: "fill", radius: h / 2 });
    g.rect(0, 0, Math.max(h, w * Math.min(1, Math.max(0, fraction))), h, { fill: "accent", radius: h / 2 });
  } });
}

/// A filled line of one history value over the chosen range. `max` null: scale to the highest value.
function graph(key, id, max) {
  const seconds = RANGES[range].seconds;
  const points = history.filter(s => s.t <= seconds && s[key] != null);
  const top = max || Math.max(1, ...points.map(s => s[key]));
  return z.ui.canvas({ height: 44, id, draw(g, w, h) {
    g.rect(0, 0, w, h, { fill: "fill", radius: 6 });
    if (points.length < 2) return;
    const xy = points.map(s => [w - (s.t / seconds) * w, h - 2 - (h - 4) * Math.min(1, s[key] / top)]);
    g.alpha(0.25);
    g.path([[xy[0][0], h], ...xy, [xy[xy.length - 1][0], h]], { fill: "accent", closed: true });
    g.alpha(1);
    g.path(xy, { stroke: "accent", lineWidth: 1.5 });
  } });
}

// MARK: Sections

function cpuSection() {
  const c = stats.cpu || {};
  const total = (c.user || 0) + (c.system || 0);
  return z.ui.section("CPU", [
    z.ui.row([z.ui.text(percent(total), { style: "title", id: "cpuTotal" }), z.ui.spacer(),
              z.ui.text("User " + percent(c.user || 0) + " · System " + percent(c.system || 0) + " · " + (c.cores || "?") + " cores", { style: "caption" })]),
    graph("cpu", "cpuGraph", 100),
  ]);
}

function gpuSection() {
  if (stats.gpu == null) return null;
  return z.ui.section("GPU", [
    z.ui.text(percent(stats.gpu), { style: "title", id: "gpuTotal" }),
    graph("gpu", "gpuGraph", 100),
  ]);
}

function memorySection() {
  const m = stats.memory || {};
  if (!m.total) return null;
  const pressure = { normal: "Normal", medium: "Medium", high: "High" }[m.pressure];
  return z.ui.section("Memory", [
    z.ui.row([z.ui.text(bytes(m.used, 1024) + " of " + bytes(m.total, 1024), { style: "body" }), z.ui.spacer(),
              pressure ? z.ui.text("Pressure: " + pressure, { style: "caption" }) : null]),
    graph("memory", "memGraph", 100),
  ]);
}

function heatSection() {
  const t = stats.temperatures || {}, fans = stats.fans || [];
  const parts = [];
  if (t.cpu != null) parts.push("Chip " + degrees(t.cpu));
  if (t.battery != null) parts.push("Battery " + degrees(t.battery));
  if (t.ssd != null) parts.push("SSD " + degrees(t.ssd));
  if (!parts.length && !fans.length) return null;
  const lines = [z.ui.text(parts.join(" · ") || "No temperature sensors", { style: "body", id: "temps" })];
  if (fans.length) lines.push(z.ui.text("Fans: " + fans.map(r => Math.round(r) + " rpm").join(", "), { style: "caption" }));
  if (t.cpu != null) lines.push(graph("temp", "tempGraph", 110));
  return z.ui.section("Temperature", lines);
}

function batterySection() {
  const b = stats.battery || {};
  if (!b.present) return stats.watts != null ? z.ui.section("Power", [z.ui.text("Using " + watts(stats.watts), { style: "body" })]) : null;
  let state = b.charging ? "Charging" : b.pluggedIn ? "Plugged in" : "On battery";
  if (b.charging && b.minutesToFull) state += " · full in " + span(b.minutesToFull * 60);
  if (!b.pluggedIn && b.minutesLeft) state += " · about " + span(b.minutesLeft * 60) + " left";
  const lines = [
    z.ui.row([z.ui.text(percent(b.level), { style: "title" }), z.ui.spacer(), z.ui.text(state, { style: "caption" })]),
    bar(b.level / 100, "batteryBar"),
  ];
  const details = [];
  if (b.healthPercent != null) details.push("Health " + percent(b.healthPercent));
  if (b.cycles != null) details.push(b.cycles + " cycles");
  if (b.systemWatts != null) details.push("Mac uses " + watts(b.systemWatts));
  if (b.adapterWatts && b.pluggedIn) details.push(b.adapterWatts + " W charger");
  if (details.length) lines.push(z.ui.text(details.join(" · "), { style: "caption", id: "batteryDetails" }));
  return z.ui.section("Battery", lines);
}

function appsSection() {
  const apps = stats.apps || [];
  if (!apps.length) return null;
  return z.ui.section("Busiest apps", [
    z.ui.list(apps.map(a => ({ id: a.name, title: a.name, detail: percent(a.cpu) + " CPU", symbol: "app.dashed" }))),
    z.ui.text("CPU use over the last second, helpers included with their app. 100% is one whole core.", { style: "caption" }),
  ]);
}

function networkSection() {
  const n = stats.network || {};
  const lines = [
    z.ui.row([z.ui.text("Down " + rate(n.in || 0), { style: "mono" }), z.ui.spacer(), z.ui.text("Up " + rate(n.out || 0), { style: "mono" })]),
    graph("in", "netGraph", null),
  ];
  const local = (stats.addresses || []).join(", ");
  lines.push(z.ui.row([
    z.ui.text("This Mac: " + (local || "not connected"), { style: "caption", selectable: true }),
    z.ui.spacer(),
    z.ui.text(publicIP == null ? "" : "Public: " + publicIP, { style: "caption", selectable: true, id: "publicIP" }),
  ]));
  let result = null;
  if (speed === "running") result = z.ui.text("Testing… this takes about 15 seconds.", { style: "caption" });
  else if (speed && speed.error) result = z.ui.text(speed.error, { style: "caption" });
  else if (speed) result = z.ui.text("Down " + Math.round(speed.download) + " Mbps · Up " + Math.round(speed.upload) + " Mbps · " + Math.round(speed.latency) + " ms", { style: "body", id: "speed" });
  lines.push(z.ui.row([
    z.ui.button("Public IP", () => {
      publicIP = "…";
      z.system.publicIP(r => { publicIP = (r && r.address) || "couldn't look it up"; });
    }, { symbol: "globe", disabled: publicIP === "…" }),
    z.ui.button("Speed Test", () => {
      speed = "running";
      z.system.speedTest(r => { speed = r; });
    }, { symbol: "speedometer", disabled: speed === "running" }),
  ]));
  if (result) lines.push(result);
  lines.push(z.ui.text("Public IP and the speed test use the internet (ipify.org and Cloudflare), only when you click them.", { style: "caption" }));
  return z.ui.section("Network", lines);
}

function diskSection() {
  const d = stats.disk || {};
  if (!d.total) return null;
  return z.ui.section("Disk", [
    z.ui.text(bytes(d.free) + " free of " + bytes(d.total), { style: "body" }),
    bar((d.total - d.free) / d.total, "diskBar"),
  ]);
}

zephydian.utility({
  start() {
    read();                 // the first reading sets the starting point for CPU, network and apps
    z.loop.start(1000);
  },

  tick() { read(); },

  resume() { read(); },

  view() {
    if (!stats) return z.ui.text("Reading…", { style: "secondary" });
    return z.ui.column([
      z.ui.segmented(RANGES.map(r => r.label), range, i => { range = i; }),
      cpuSection(),
      gpuSection(),
      memorySection(),
      heatSection(),
      batterySection(),
      appsSection(),
      networkSection(),
      diskSection(),
      z.ui.text("Up " + span(stats.uptime || 0) + " since the last restart. Measured only while this is open, or while the menu bar readouts are on.", { style: "caption" }),
    ], { spacing: 10 });
  },
});
