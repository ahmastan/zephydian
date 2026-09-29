// Screenshot: capture an area, a window or the whole screen. The capturing itself (the selection
// overlay, the picture, the preview card with Copy, Save, Edit and Close) is done by Zephydian
// through z.screen; this utility starts captures, holds the settings and lists this session's shots.

const MODES = [
  { mode: "area", label: "Area", symbol: "rectangle.dashed" },
  { mode: "window", label: "Window", symbol: "macwindow" },
  { mode: "screen", label: "Full screen", symbol: "display" },
];
const DELAYS = [0, 3, 5, 10];

let prefs = { delay: 0, pointer: false, sound: true, format: "png", autoCopy: false };
let error = "";

function capture(mode) {
  error = "";
  z.screen.capture(mode, result => {
    if (result && result.error) { error = result.error; z.toast(result.error); }
  });
}

function setPref(key, value) {
  prefs[key] = value;
  z.screen.setPrefs(prefs);
}

function time(ms) { return new Date(ms).toLocaleTimeString([], { hour: "numeric", minute: "2-digit", second: "2-digit" }); }

function permissionCard() {
  return z.ui.section(null, [
    z.ui.text("Allow screen recording", { style: "title" }),
    z.ui.text("macOS asks before any app can capture the screen. Click below, turn on Zephydian under Screen Recording in System Settings, then come back.", { style: "secondary" }),
    z.ui.button("Allow Screen Recording…", () => z.screen.requestPermission(), { style: "prominent", symbol: "lock.open" }),
    z.ui.text("Zephydian is not signed yet, so macOS may ask again after an update.", { style: "caption" }),
  ]);
}

function shotsList() {
  const shots = z.screen.shots(), canEdit = z.screen.canEdit();
  if (!shots.length) return z.ui.text("Your screenshots from this session appear here.", { style: "caption" });
  const actions = [{ symbol: "doc.on.doc", label: "Copy" }, { symbol: "square.and.arrow.down", label: "Save" }];
  if (canEdit) actions.push({ symbol: "pencil.tip.crop.circle", label: "Edit" });
  actions.push({ symbol: "trash", label: "Delete" });
  return z.ui.section("This session", [
    z.ui.list(shots.map(s => ({
      id: s.id, title: time(s.at), image: s.image,
      subtitle: s.width + " × " + s.height + (s.saved ? " · " + s.saved : " · not saved"),
      actions,
    })), {
      onSelect: id => { if (z.screen.copy(id)) z.toast("Copied"); },
      onAction: (id, i) => {
        const label = actions[i].label;
        if (label === "Copy" && z.screen.copy(id)) z.toast("Copied");
        if (label === "Save") { const name = z.screen.save(id); z.toast(name ? "Saved as " + name : "Couldn't save it there"); }
        if (label === "Edit") z.screen.edit(id);
        if (label === "Delete") z.screen.delete(id);
      },
    }),
  ]);
}

function settings() {
  const folder = z.screen.folder();
  return z.ui.section("Settings", [
    z.ui.picker("Delay", ["None", "3 seconds", "5 seconds", "10 seconds"], DELAYS.indexOf(prefs.delay), i => setPref("delay", DELAYS[i])),
    z.ui.row([z.ui.text("Format"), z.ui.spacer(),
              z.ui.segmented(["PNG", "JPEG"], prefs.format === "jpeg" ? 1 : 0, i => setPref("format", i ? "jpeg" : "png"))]),
    z.ui.toggle("Copy automatically", prefs.autoCopy, on => setPref("autoCopy", on)),
    z.ui.toggle("Camera sound", prefs.sound, on => setPref("sound", on)),
    z.ui.toggle("Include the pointer", prefs.pointer, on => setPref("pointer", on)),
    z.ui.shortcut("Shortcut for Area"),
    z.ui.divider(),
    z.ui.text("Saves to", { style: "caption" }),
    z.ui.text(folder.label, { style: "mono", selectable: true, id: "folder" }),
    z.ui.row([
      z.ui.button("Choose…", () => z.screen.chooseFolder(ok => { if (ok) z.toast("Screenshots now save there"); }), { symbol: "folder" }),
      folder.custom ? z.ui.button("Use Pictures/Screenshots", () => z.screen.resetFolder()) : null,
      z.ui.button("Open", () => z.screen.openFolder(), { symbol: "arrow.up.forward.app" }),
    ]),
  ]);
}

zephydian.utility({
  start() {
    prefs = Object.assign(prefs, z.screen.prefs());
  },

  key(e) {
    const i = ["1", "2", "3"].indexOf(e.key);
    if (i >= 0) { capture(MODES[i].mode); return true; }
    return false;
  },

  view() {
    return z.ui.column([
      z.screen.permission() ? null : permissionCard(),
      z.ui.row(MODES.map(m => z.ui.button(m.label, () => capture(m.mode), { symbol: m.symbol, style: m.mode === "area" ? "prominent" : "plain" })),
               { align: "center" }),
      z.ui.text("Press 1, 2 or 3 here too. Esc cancels a selection." + (prefs.delay ? " Waits " + prefs.delay + " seconds after you pick." : ""), { style: "caption", align: "center" }),
      shotsList(),
      settings(),
    ], { spacing: 12 });
  },
});
