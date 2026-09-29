// System: CPU, memory, disk, battery, network and uptime. It reads the numbers once a second only
// while it's on screen (the loop stops when the panel hides), so it costs nothing the rest of the time.

const HISTORY = 60;          // seconds of CPU shown in the graph
let stats = null;
let cpuHistory = [];

function read() {
  stats = z.system.stats();
  const cpu = stats.cpu ? stats.cpu.user + stats.cpu.system : 0;
  cpuHistory.push(Math.min(100, Math.max(0, cpu)));
  if (cpuHistory.length > HISTORY) cpuHistory.shift();
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

/// The last minute of CPU use as a filled line.
function graph() {
  return z.ui.canvas({ height: 48, id: "cpuGraph", draw(g, w, h) {
    g.rect(0, 0, w, h, { fill: "fill", radius: 6 });
    if (cpuHistory.length < 2) return;
    const step = w / (HISTORY - 1), x0 = w - (cpuHistory.length - 1) * step;
    const points = cpuHistory.map((v, i) => [x0 + i * step, h - 2 - (h - 4) * v / 100]);
    g.alpha(0.25);
    g.path([[x0, h], ...points, [w, h]], { fill: "accent", closed: true });
    g.alpha(1);
    g.path(points, { stroke: "accent", lineWidth: 1.5 });
  } });
}

// MARK: Sections

function cpuSection() {
  const c = stats.cpu || {};
  const total = (c.user || 0) + (c.system || 0);
  return z.ui.section("CPU", [
    z.ui.row([z.ui.text(percent(total), { style: "title", id: "cpuTotal" }), z.ui.spacer(),
              z.ui.text("User " + percent(c.user || 0) + " · System " + percent(c.system || 0) + " · " + (c.cores || "?") + " cores", { style: "caption" })]),
    graph(),
  ]);
}

function memorySection() {
  const m = stats.memory || {};
  if (!m.total) return null;
  const pressure = { normal: "Normal", medium: "Medium", high: "High" }[m.pressure];
  return z.ui.section("Memory", [
    z.ui.row([z.ui.text(bytes(m.used, 1024) + " of " + bytes(m.total, 1024), { style: "body" }), z.ui.spacer(),
              pressure ? z.ui.text("Pressure: " + pressure, { style: "caption" }) : null]),
    bar(m.used / m.total, "memBar"),
  ]);
}

function diskSection() {
  const d = stats.disk || {};
  if (!d.total) return null;
  return z.ui.section("Disk", [
    z.ui.text(bytes(d.free) + " free of " + bytes(d.total), { style: "body" }),
    bar((d.total - d.free) / d.total, "diskBar"),
  ]);
}

function batterySection() {
  const b = stats.battery || {};
  if (!b.present) return null;
  let state = b.charging ? "Charging" : b.pluggedIn ? "Plugged in" : "On battery";
  if (b.charging && b.minutesToFull) state += " · full in " + span(b.minutesToFull * 60);
  if (!b.pluggedIn && b.minutesLeft) state += " · about " + span(b.minutesLeft * 60) + " left";
  const lines = [
    z.ui.row([z.ui.text(percent(b.level), { style: "title" }), z.ui.spacer(), z.ui.text(state, { style: "caption" })]),
    bar(b.level / 100, "batteryBar"),
  ];
  if (b.health && b.health !== "Unknown") lines.push(z.ui.text("Health: " + b.health, { style: "caption" }));
  return z.ui.section("Battery", lines);
}

function networkSection() {
  const n = stats.network || {};
  return z.ui.section("Network", [
    z.ui.row([
      z.ui.text("Down " + rate(n.in || 0), { style: "mono" }),
      z.ui.spacer(),
      z.ui.text("Up " + rate(n.out || 0), { style: "mono" }),
    ]),
  ]);
}

zephydian.utility({
  start() {
    read();                 // the first reading sets the starting point for CPU and network
    z.loop.start(1000);
  },

  tick() { read(); },

  resume() { read(); },

  view() {
    if (!stats) return z.ui.text("Reading…", { style: "secondary" });
    return z.ui.column([
      cpuSection(),
      memorySection(),
      diskSection(),
      batterySection(),
      networkSection(),
      z.ui.text("Up " + span(stats.uptime || 0) + " since the last restart. Measured only while this is open.", { style: "caption" }),
    ], { spacing: 10 });
  },
});
