// Capture: screenshots (area, window, whole screen, scrolling), screen recordings, text copied
// off the screen, and colors. The capturing itself (the capture bar, the selection overlay with its
// magnifier, the preview card, the recorder and its editor) is done by Zephydian through z.screen;
// this utility starts captures, holds the settings and lists this session's shots and recordings.

const TABS = ["Screenshot", "Record", "Copy Text", "Color"];
const SHOTS = [
  { mode: "area", label: "Area", symbol: "rectangle.dashed" },
  { mode: "window", label: "Window", symbol: "macwindow" },
  { mode: "screen", label: "Screen", symbol: "display" },
  { mode: "scrolling", label: "Scrolling", symbol: "arrow.up.and.down.text.horizontal" },
];
const RECORDS = SHOTS.slice(0, 3);
const DELAYS = [0, 3, 5, 10];

let tab = 0;
let prefs = { delay: 0, pointer: false, sound: true, format: "png", autoCopy: false, freeze: false, shortcutAction: "bar", instantMode: "area" };
const INSTANT = ["area", "window", "screen"];
let record = { systemAudio: true, microphone: false, fps: 60, pointer: true };

function load() {
  prefs = Object.assign(prefs, z.screen.prefs());
  record = Object.assign(record, z.screen.recordPrefs());
  tab = z.storage.get("tab") || 0;
}

function capture(mode) {
  z.screen.capture(mode, result => {
    if (result && result.error) z.toast(result.error);
  });
}

function setPref(key, value) {
  prefs[key] = value;
  z.screen.setPrefs(prefs);
}

function setRecord(key, value) {
  record[key] = value;
  z.screen.setRecordPrefs(record);
}

function time(ms) { return new Date(ms).toLocaleTimeString([], { hour: "numeric", minute: "2-digit", second: "2-digit" }); }

function permissionCard() {
  return z.ui.section(null, [
    z.ui.text("Allow screen recording", { style: "title" }),
    z.ui.text("macOS asks before any app can capture the screen. Click below, turn on Zephydian under Screen Recording in System Settings, then come back.", { style: "secondary" }),
    z.ui.button("Allow Screen Recording…", () => z.screen.requestPermission(), { style: "prominent", symbol: "lock.open" }),
  ]);
}

function shotsList() {
  const shots = z.screen.shots(), canEdit = z.screen.canEdit();
  if (!shots.length) return z.ui.text("Your screenshots from this session appear here.", { style: "caption" });
  const actions = [{ symbol: "doc.on.doc", label: "Copy" }, { symbol: "square.and.arrow.down", label: "Save" }];
  if (canEdit) actions.push({ symbol: "pencil.tip.crop.circle", label: "Edit" });
  actions.push({ symbol: "pin", label: "Pin" }, { symbol: "trash", label: "Delete" });
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
        if (label === "Pin") z.screen.pin(id);
        if (label === "Delete") z.screen.delete(id);
      },
    }),
  ]);
}

function screenshotTab() {
  return [
    z.ui.row(SHOTS.map(m => z.ui.button(m.label, () => capture(m.mode), { symbol: m.symbol, style: m.mode === "area" ? "prominent" : "plain" })),
             { align: "center" }),
    z.ui.text("Press 1–4 here too. Scrolling scrolls the area for you and stitches one long picture." +
              (prefs.delay ? " Waits " + prefs.delay + " seconds after you pick." : ""), { style: "caption", align: "center" }),
    shotsList(),
  ];
}

function recordTab() {
  const recordings = z.screen.recordings();
  return [
    z.screen.isRecording()
      ? z.ui.button("Stop Recording", () => z.screen.stopRecording(), { symbol: "stop.circle.fill", style: "destructive" })
      : z.ui.row(RECORDS.map(m => z.ui.button(m.label, () => z.screen.record(m.mode), { symbol: m.symbol, style: m.mode === "area" ? "prominent" : "plain" })),
                 { align: "center" }),
    z.ui.section(null, [
      z.ui.toggle("Record your Mac's sound", record.systemAudio, on => setRecord("systemAudio", on)),
      z.ui.toggle("Record the microphone", record.microphone, on => setRecord("microphone", on)),
    ]),
    z.ui.text("Stop with the pill at the top of the screen or the capture shortcut. The recording then opens in the editor: trim, cut, blur, zoom on clicks, save as video or GIF.", { style: "caption" }),
    recordings.length
      ? z.ui.section("This session", [
          z.ui.list(recordings.map(r => ({ id: r.id, title: time(r.at), subtitle: r.clicks + " clicks", symbol: "film" })),
                    { onSelect: id => z.screen.openRecording(id) }),
        ])
      : null,
  ];
}

function textTab() {
  return [
    z.ui.button("Select Text on Screen", () => z.screen.copyText(), { symbol: "text.viewfinder", style: "prominent" }),
    z.ui.text("Drag over any text (in a picture, a video, an app that won't let you select it): it's read on your Mac and copied. A QR code's link is copied instead.", { style: "caption" }),
  ];
}

function colorTab() {
  return [
    z.ui.button("Pick a Color on Screen", () => z.screen.pickColor(), { symbol: "eyedropper", style: "prominent" }),
    z.ui.text("Click any pixel (a magnifier helps you aim): its color is copied as hex.", { style: "caption" }),
  ];
}

// Capture's page in Zephydian's Settings window.
function settings() {
  const folder = z.screen.folder();
  return z.ui.column([
    z.ui.section(null, [
      z.ui.shortcut("Capture shortcut"),
      z.ui.picker("The shortcut", ["Shows the capture bar", "Takes a screenshot"], prefs.shortcutAction === "instant" ? 1 : 0,
                  i => setPref("shortcutAction", i ? "instant" : "bar")),
      prefs.shortcutAction === "instant"
        ? z.ui.picker("Screenshot", ["Area", "Window", "Screen"], Math.max(0, INSTANT.indexOf(prefs.instantMode)), i => setPref("instantMode", INSTANT[i]))
        : null,
      z.ui.text(prefs.shortcutAction === "instant"
        ? "Takes that kind of screenshot from any app, without the bar. Pressing it while recording stops the recording."
        : "Opens the capture bar from any app: Screenshot, Record, Copy Text and Color (keys 1–4). Pressing it while recording stops the recording.", { style: "caption" }),
    ]),
    z.ui.section("Screenshots", [
      z.ui.picker("Delay", ["None", "3 seconds", "5 seconds", "10 seconds"], DELAYS.indexOf(prefs.delay), i => setPref("delay", DELAYS[i])),
      z.ui.row([z.ui.text("Format"), z.ui.spacer(),
                z.ui.segmented(["PNG", "JPEG"], prefs.format === "jpeg" ? 1 : 0, i => setPref("format", i ? "jpeg" : "png"))]),
      z.ui.toggle("Copy automatically", prefs.autoCopy, on => setPref("autoCopy", on)),
      z.ui.toggle("Camera sound", prefs.sound, on => setPref("sound", on)),
      z.ui.toggle("Include the pointer", prefs.pointer, on => setPref("pointer", on)),
      z.ui.toggle("Freeze the screen", prefs.freeze, on => setPref("freeze", on)),
      z.ui.text("Holds everything still (videos too) from the moment a screenshot starts until it's taken. The capture bar's pause button turns it on or off for one shot.", { style: "caption" }),
    ]),
    z.ui.section("Recordings", [
      z.ui.toggle("Record your Mac's sound", record.systemAudio, on => setRecord("systemAudio", on)),
      z.ui.toggle("Record the microphone", record.microphone, on => setRecord("microphone", on)),
      z.ui.row([z.ui.text("Frames per second"), z.ui.spacer(),
                z.ui.segmented(["30", "60"], record.fps === 30 ? 0 : 1, i => setRecord("fps", i ? 60 : 30))]),
      z.ui.toggle("Show the pointer", record.pointer, on => setRecord("pointer", on)),
      z.ui.text("The microphone needs macOS 15 or newer.", { style: "caption" }),
    ]),
    z.ui.section("Screenshots save to", [
      z.ui.text(folder.label, { style: "mono", selectable: true, id: "folder" }),
      z.ui.row([
        z.ui.button("Choose…", () => z.screen.chooseFolder(ok => { if (ok) z.toast("Screenshots now save there"); }), { symbol: "folder" }),
        folder.custom ? z.ui.button("Use Pictures/Screenshots", () => z.screen.resetFolder()) : null,
        z.ui.button("Open", () => z.screen.openFolder(), { symbol: "arrow.up.forward.app" }),
      ]),
    ]),
  ]);
}

zephydian.utility({
  start: load,

  // The settings may have changed in the Settings window while the panel was closed.
  resume: load,

  key(e) {
    const i = ["1", "2", "3", "4"].indexOf(e.key);
    if (i < 0) return false;
    if (tab === 0) capture(SHOTS[i].mode);
    else if (tab === 1 && i < 3) z.screen.record(RECORDS[i].mode);
    return true;
  },

  view() {
    const content = [screenshotTab, recordTab, textTab, colorTab][tab]();
    return z.ui.column([
      z.screen.permission() ? null : permissionCard(),
      z.ui.segmented(TABS, tab, i => { tab = i; z.storage.set("tab", i); }),
      ...content,
    ], { spacing: 12 });
  },

  settings: {
    start: load,
    view: settings,
  },
});
