// Timer: countdowns, a stopwatch with laps, and a focus mode (work/break cycles).
// Countdowns and focus phases are Zephydian timers (z.timers): they keep running with the panel
// closed, and when one ends macOS shows a notification and the chosen sound plays.
// The stopwatch only needs a start time, so it keeps counting on its own.

const TABS = ["Timers", "Stopwatch", "Focus"];
const PRESETS = [["1 min", 60], ["3 min", 180], ["5 min", 300], ["10 min", 600], ["25 min", 1500], ["1 h", 3600]];
const FOCUS_LABELS = ["Focus", "Break", "Long break"];

let prefs = { tab: 0, sound: "Glass", focus: 25, shortBreak: 5, longBreak: 15, rounds: 4 };
let name = "";
let duration = "";
let watch = { running: false, startedAt: 0, total: 0, laps: [] };   // times in ms
let focusID = null;

const savePrefs = () => z.storage.set("prefs", prefs);
const saveWatch = () => z.storage.set("watch", watch);

// MARK: Formatting and parsing

function clock(ms, tenths) {
  const t = Math.max(0, ms), s = Math.floor(t / 1000), h = Math.floor(s / 3600), m = Math.floor(s / 60) % 60;
  const body = (h ? h + ":" + String(m).padStart(2, "0") : String(m)) + ":" + String(s % 60).padStart(2, "0");
  return tenths ? body + "." + Math.floor(t / 100) % 10 : body;
}

/// Seconds left, rounded up, so a timer shows 0:01 until it really ends.
const left = t => clock(Math.ceil(t.remaining / 1000) * 1000);
const at = ms => new Date(ms).toLocaleTimeString([], { hour: "numeric", minute: "2-digit" });

/// "5" (minutes), "5:00", "1:30:00", "90s", "10m", "1h 30m", "1.5h". Returns seconds, or 0.
function parseDuration(input) {
  const s = input.trim().toLowerCase();
  if (!s) return 0;
  if (/^\d+(\.\d+)?$/.test(s)) return parseFloat(s) * 60;
  if (/^\d+(:\d{1,2}){1,2}$/.test(s)) return s.split(":").map(Number).reduce((a, n) => a * 60 + n, 0);
  const re = /(\d+(?:\.\d+)?)\s*(h|hr|hrs|hours?|m|min|mins|minutes?|s|sec|secs|seconds?)\b/g;
  let total = 0, m, used = "";
  while ((m = re.exec(s))) {
    total += parseFloat(m[1]) * (m[2][0] === "h" ? 3600 : m[2][0] === "m" ? 60 : 1);
    used += m[0];
  }
  return used.replace(/\s/g, "").length === s.replace(/\s/g, "").length ? total : 0;
}

// MARK: Countdowns

const sound = () => prefs.sound === "None" ? null : prefs.sound;

function startTimer(seconds, label) {
  if (seconds < 1) { z.toast("Type a time, like 5:00 or 10m"); return; }
  z.timers.start({ label: label || "Timer", seconds, sound: sound() });
  name = "";
  duration = "";
}

function countdowns() {
  const list = z.timers.list().filter(t => t.phases === 1);
  return [
    z.ui.section("New timer", [
      z.ui.field({ value: name, placeholder: "Name (optional)", id: "name", onChange: t => { name = t; } }),
      z.ui.row([
        z.ui.field({ value: duration, placeholder: "5:00, 10m, 1h 30m", id: "duration", mono: true,
                     onChange: t => { duration = t; }, onSubmit: t => startTimer(parseDuration(t), name.trim()) }),
        z.ui.button("Start", () => startTimer(parseDuration(duration), name.trim()), { style: "prominent", symbol: "play.fill" }),
      ]),
      z.ui.row(PRESETS.slice(0, 3).map(([label, s]) => z.ui.button(label, () => startTimer(s, name.trim() || label)))),
      z.ui.row(PRESETS.slice(3).map(([label, s]) => z.ui.button(label, () => startTimer(s, name.trim() || label)))),
    ]),
    z.ui.list(list.map(t => ({
      id: t.id, title: t.label, symbol: t.paused ? "pause.circle" : "timer",
      subtitle: t.paused ? "Paused" : "Ends " + at(t.endsAt), detail: left(t),
      actions: [{ symbol: t.paused ? "play.fill" : "pause.fill", label: t.paused ? "Resume" : "Pause" },
                { symbol: "xmark", label: "Cancel" }],
    })), {
      empty: "Timers keep running when the panel is closed.",
      onAction: (id, i) => {
        const t = list.find(x => x.id === id);
        if (!t) return;
        if (i === 0) t.paused ? z.timers.resume(id) : z.timers.pause(id); else z.timers.cancel(id);
      },
    }),
  ];
}

// MARK: Stopwatch

const elapsed = () => watch.total + (watch.running ? Date.now() - watch.startedAt : 0);

function toggleWatch() {
  if (watch.running) { watch.total = elapsed(); watch.running = false; }
  else { watch.startedAt = Date.now(); watch.running = true; }
  saveWatch();
  updateLoop();
}

function lap() { if (watch.running) { watch.laps.unshift(elapsed()); watch.laps = watch.laps.slice(0, 99); saveWatch(); } }
function resetWatch() { watch = { running: false, startedAt: 0, total: 0, laps: [] }; saveWatch(); updateLoop(); }

function stopwatch() {
  const laps = watch.laps.map((total, i) => {
    const previous = watch.laps[i + 1] || 0;
    return { id: "lap" + (watch.laps.length - i), title: "Lap " + (watch.laps.length - i), detail: clock(total - previous, true),
             subtitle: "Total " + clock(total, true) };
  });
  return [
    z.ui.text(clock(elapsed(), true), { style: "large", align: "center", id: "elapsed" }),
    z.ui.row([
      z.ui.button(watch.running ? "Stop" : elapsed() ? "Continue" : "Start", toggleWatch,
                  { style: "prominent", symbol: watch.running ? "pause.fill" : "play.fill" }),
      z.ui.button("Lap", lap, { disabled: !watch.running, symbol: "flag" }),
      z.ui.button("Reset", resetWatch, { disabled: !elapsed() || watch.running, symbol: "arrow.counterclockwise" }),
    ], { align: "center" }),
    z.ui.text("Space starts and stops, L adds a lap. The stopwatch keeps counting when the panel is closed.", { style: "caption", align: "center" }),
    z.ui.list(laps, {}),
  ];
}

// MARK: Focus

function focusTimer() {
  return z.timers.list().find(t => t.id === focusID) || z.timers.list().find(t => t.phases > 1) || null;
}

function startFocus() {
  const chain = [];
  for (let round = 1; round <= prefs.rounds; round++) {
    if (round > 1) chain.push({ label: "Focus", seconds: prefs.focus * 60 });
    chain.push(round === prefs.rounds ? { label: "Long break", seconds: prefs.longBreak * 60 }
                                      : { label: "Break", seconds: prefs.shortBreak * 60 });
  }
  focusID = z.timers.start({ label: "Focus", seconds: prefs.focus * 60, sound: sound(), chain });
  z.storage.set("focusID", focusID);
}

function sessionsToday() {
  const midnight = new Date(); midnight.setHours(0, 0, 0, 0);
  return z.timers.finished().filter(f => f.label === "Focus" && f.at >= midnight.getTime()).length;
}

function slider(label, key, min, max, step) {
  return z.ui.row([
    z.ui.text(label),
    z.ui.slider({ value: prefs[key], min, max, step, onChange: v => { prefs[key] = Math.round(v); savePrefs(); } }),
    z.ui.text(prefs[key] + (key === "rounds" ? "" : " min"), { style: "mono" }),
  ]);
}

function focus() {
  const t = focusTimer(), done = sessionsToday();
  const status = t ? [
    z.ui.text(left(t), { style: "large", align: "center", id: "focusLeft" }),
    z.ui.text(t.label + " · round " + Math.ceil(t.phase / 2) + " of " + prefs.rounds + (t.paused ? " · paused" : ""), { style: "secondary", align: "center" }),
    z.ui.row([
      z.ui.button(t.paused ? "Resume" : "Pause", () => t.paused ? z.timers.resume(t.id) : z.timers.pause(t.id),
                  { symbol: t.paused ? "play.fill" : "pause.fill" }),
      z.ui.button("Stop", () => { z.timers.cancel(t.id); focusID = null; z.storage.remove("focusID"); }, { symbol: "stop.fill" }),
    ], { align: "center" }),
  ] : [
    z.ui.button("Start focusing", startFocus, { style: "prominent", symbol: "brain.head.profile" }),
  ];
  return [
    z.ui.section(null, status),
    z.ui.text(done === 1 ? "1 focus session today" : done + " focus sessions today", { style: "caption", align: "center" }),
    z.ui.section("Lengths", [
      slider("Focus", "focus", 5, 90, 5),
      slider("Break", "shortBreak", 1, 30, 1),
      slider("Long break", "longBreak", 5, 60, 5),
      slider("Rounds", "rounds", 1, 8, 1),
    ]),
  ];
}

// MARK: Screen

/// Redraws every second for the countdowns, or ten times a second while the stopwatch runs on screen.
function updateLoop() { z.loop.start(prefs.tab === 1 && watch.running ? 100 : 1000); }

zephydian.utility({
  start() {
    prefs = Object.assign(prefs, z.storage.get("prefs") || {});
    watch = Object.assign(watch, z.storage.get("watch") || {});
    focusID = z.storage.get("focusID");
    updateLoop();
  },

  tick() {},

  key(e) {
    if (prefs.tab === 1 && e.key === " ") { toggleWatch(); return true; }
    if (prefs.tab === 1 && e.key === "l") { lap(); return true; }
    return false;
  },

  view() {
    const body = prefs.tab === 0 ? countdowns() : prefs.tab === 1 ? stopwatch() : focus();
    return z.ui.column([
      z.ui.segmented(TABS, prefs.tab, i => { prefs.tab = i; savePrefs(); updateLoop(); }),
      ...body,
      prefs.tab !== 1 ? z.ui.picker("Sound", ["None", ...z.timers.sounds()], ["None", ...z.timers.sounds()].indexOf(prefs.sound), i => {
        prefs.sound = ["None", ...z.timers.sounds()][i];
        savePrefs();
        if (prefs.sound !== "None") z.timers.preview(prefs.sound);
      }) : null,
    ], { spacing: 12 });
  },
});
