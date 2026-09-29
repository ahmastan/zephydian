// Awake: keeps the Mac from sleeping for a chosen time, or until switched off.
// The keep-awake itself is a Zephydian service (z.awake), so it carries on after the panel closes.

const LENGTHS = [
  { label: "15 minutes", minutes: 15 },
  { label: "30 minutes", minutes: 30 },
  { label: "1 hour", minutes: 60 },
  { label: "2 hours", minutes: 120 },
  { label: "5 hours", minutes: 300 },
  { label: "Until turned off", minutes: 0 },
];

let choice = 5;        // index into LENGTHS
let screen = false;    // keep the display on too

function save() { z.storage.set("prefs", { choice, screen }); }
function turnOn() { z.awake.start({ minutes: LENGTHS[choice].minutes, display: screen }); }

function clock(ms) {
  return new Date(ms).toLocaleTimeString([], { hour: "numeric", minute: "2-digit" });
}

function left(until) {
  const minutes = Math.max(1, Math.ceil((until - Date.now()) / 60000));
  if (minutes < 60) return minutes + " min left";
  const h = Math.floor(minutes / 60), m = minutes % 60;
  return h + " h" + (m ? " " + m + " min" : "") + " left";
}

zephydian.utility({
  start() {
    const prefs = z.storage.get("prefs");
    if (prefs) {
      choice = Math.min(Math.max(prefs.choice | 0, 0), LENGTHS.length - 1);
      screen = !!prefs.screen;
    }
    z.loop.start(15000);   // keeps "… left" current while it's on screen (stops when the panel hides)
  },

  tick() {},

  key(e) {
    if (e.key === " " || e.key === "Enter") {
      z.awake.status().on ? z.awake.stop() : turnOn();
      return true;
    }
    return false;
  },

  view() {
    const status = z.awake.status();
    const detail = !status.on
      ? "Your Mac sleeps as set in System Settings."
      : status.until ? "Until " + clock(status.until) + " · " + left(status.until) : "Until you turn it off";
    return z.ui.column([
      z.ui.section(null, [
        z.ui.toggle("Keep awake", status.on, on => { on ? turnOn() : z.awake.stop(); }, { id: "switch" }),
        z.ui.text(detail, { style: "secondary" }),
      ]),
      z.ui.section("Options", [
        z.ui.picker("Keep awake for", LENGTHS.map(l => l.label), choice, i => {
          choice = i;
          save();
          if (z.awake.status().on) turnOn();   // apply the new length right away
        }),
        z.ui.toggle("Keep the screen on too", screen, on => {
          screen = on;
          save();
          if (z.awake.status().on) turnOn();
        }),
      ]),
      z.ui.text("Awake stops when Zephydian quits. While it's on, the menu bar icon takes your accent color.", { style: "caption" }),
    ], { spacing: 12 });
  },
});
