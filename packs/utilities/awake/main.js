// Awake: keeps the Mac from sleeping for a chosen time, or until switched off, and (SDK 8) by
// itself while chosen apps are open, while on power or with an external display. The keep-awake
// and the rules are Zephydian services (z.awake), so they carry on after the panel closes.

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
function load() {
  const prefs = z.storage.get("prefs");
  if (prefs) {
    choice = Math.min(Math.max(prefs.choice | 0, 0), LENGTHS.length - 1);
    screen = !!prefs.screen;
  }
}
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
    load();
    z.loop.start(15000);   // keeps "… left" current while it's on screen (stops when the panel hides)
  },

  tick() {},

  // "Keep the screen on too" changed on Awake's settings page.
  storageChanged: load,

  key(e) {
    if (e.key === " " || e.key === "Enter") {
      z.awake.status().on ? z.awake.stop() : turnOn();
      return true;
    }
    return false;
  },

  view() {
    const status = z.awake.status();
    const rules = z.awake.rules();
    const detail = !status.on
      ? (rules.active ? "Kept awake automatically: " + rules.active + "." : "Your Mac sleeps as set in System Settings.")
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
      ]),
      z.ui.text("Awake stops when Zephydian quits. While it's on, the menu bar icon takes your accent color. Set it to keep the Mac awake by itself on its settings page (the gear above).", { style: "caption" }),
    ], { spacing: 12 });
  },

  // Awake's page in Zephydian's Settings window.
  settings: {
    start: load,
    storageChanged: load,
    view() {
      const rules = z.awake.rules();
      const ids = rules.apps.map(a => a.id);
      return z.ui.column([
        z.ui.section(null, [
          z.ui.toggle("Keep the screen on too", screen, on => {
            screen = on;
            save();
            z.awake.setRules({ display: on });
            if (z.awake.status().on) turnOn();   // apply it right away
          }),
          z.ui.text("Without it, the display can still dim and sleep while the Mac stays awake.", { style: "caption" }),
        ]),
        z.ui.section("Keep awake automatically", [
          z.ui.toggle("While the Mac is on power", rules.onPower, on => z.awake.setRules({ onPower: on })),
          z.ui.toggle("While an external display is connected", rules.externalDisplay, on => z.awake.setRules({ externalDisplay: on })),
          z.ui.text("While any of these apps is open:", { style: "body" }),
          z.ui.list(rules.apps.map(a => ({ id: a.id, title: a.name, symbol: "app", actions: [{ symbol: "minus.circle", label: "Remove" }] })), {
            empty: "No apps yet.",
            onAction: id => z.awake.setRules({ apps: ids.filter(x => x !== id) }),
          }),
          z.ui.button("Add App…", () => z.awake.pickApp(app => {
            if (app && !ids.includes(app.id)) z.awake.setRules({ apps: ids.concat([app.id]) });
          }), { symbol: "plus" }),
          z.ui.text(rules.active ? "Right now: on, because " + rules.active.charAt(0).toLowerCase() + rules.active.slice(1) + "." : "Right now: no rule applies.", { style: "caption" }),
        ]),
      ], { spacing: 12 });
    },
  },
});
