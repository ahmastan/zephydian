// Media: shrink a video, convert images, make a GIF from a video, add a watermark to images.
// The work is done by Zephydian on this Mac (z.media); files come in through macOS's open dialog
// and go out through its save dialog, so this utility only ever sees their names.

const TABS = ["Shrink Video", "Convert", "GIF", "Watermark"];
const QUALITIES = [{ id: "small", label: "540p" }, { id: "medium", label: "720p" }, { id: "large", label: "1080p" }];
const FORMATS = [{ id: "jpeg", label: "JPEG" }, { id: "png", label: "PNG" }, { id: "heic", label: "HEIC" }, { id: "tiff", label: "TIFF" }];
const WIDTHS = [480, 720, 1080];
const RATES = [10, 15, 20];
const POSITIONS = [
  { id: "bottomRight", label: "Bottom right" }, { id: "bottomLeft", label: "Bottom left" },
  { id: "topRight", label: "Top right" }, { id: "topLeft", label: "Top left" }, { id: "center", label: "Center" },
];

let tab = 0;
let video = null;        // { id, name, size }
let images = [];         // [{ id, name, size }]
let quality = 1, format = 0, width = 1, rate = 1, position = 0, opacity = 0.8;
let mark = "";
let result = "";

function size(bytes) {
  if (bytes >= 1e9) return (bytes / 1e9).toFixed(1) + " GB";
  if (bytes >= 1e6) return (bytes / 1e6).toFixed(1) + " MB";
  return Math.max(1, Math.round(bytes / 1e3)) + " KB";
}

function save() { z.storage.set("prefs", { tab, quality, format, width, rate, position, opacity, mark }); }

// While a job runs, the view is redrawn twice a second for its progress.
function started() { result = ""; z.loop.start(500); }
function finished(r, success) {
  z.loop.stop();
  if (!r) return;
  if (r.error) { result = r.error; z.toast(r.error); return; }
  if (r.saved || r.count != null) { result = success(r); z.toast("Done"); }
}

function pickVideo() { z.media.pick("video", files => { if (files.length) { video = files[0]; result = ""; } }, false); }
function pickImages() { z.media.pick("images", files => { if (files.length) { images = files; result = ""; } }, true); }

function chosenVideo() {
  return z.ui.row([
    z.ui.button(video ? "Choose Another…" : "Choose a Video…", pickVideo, { symbol: "film" }),
    video ? z.ui.text(video.name + " · " + size(video.size), { style: "secondary" }) : null,
  ]);
}

function chosenImages() {
  return z.ui.row([
    z.ui.button(images.length ? "Choose Others…" : "Choose Images…", pickImages, { symbol: "photo.on.rectangle" }),
    images.length ? z.ui.text(images.length === 1 ? images[0].name : images.length + " images", { style: "secondary" }) : null,
  ]);
}

function shrinkTab() {
  return [
    chosenVideo(),
    z.ui.row([z.ui.text("Size"), z.ui.spacer(),
              z.ui.segmented(QUALITIES.map(q => q.label), quality, i => { quality = i; save(); })]),
    z.ui.button("Shrink and Save…", () => {
      started();
      z.media.shrink(video.id, QUALITIES[quality].id, r => finished(r, r => "Saved " + r.saved + ": " + size(r.before) + " → " + size(r.after)));
    }, { style: "prominent", symbol: "arrow.down.right.and.arrow.up.left", disabled: !video }),
  ];
}

function convertTab() {
  return [
    chosenImages(),
    z.ui.row([z.ui.text("Format"), z.ui.spacer(),
              z.ui.segmented(FORMATS.map(f => f.label), format, i => { format = i; save(); })]),
    z.ui.button("Convert and Save…", () => {
      started();
      z.media.convert(images.map(i => i.id), FORMATS[format].id, r => finished(r, r => "Converted " + r.count + " image" + (r.count === 1 ? "" : "s")));
    }, { style: "prominent", symbol: "arrow.triangle.2.circlepath", disabled: !images.length }),
  ];
}

function gifTab() {
  return [
    chosenVideo(),
    z.ui.row([z.ui.text("Width"), z.ui.spacer(),
              z.ui.segmented(WIDTHS.map(w => w + " px"), width, i => { width = i; save(); })]),
    z.ui.row([z.ui.text("Frames per second"), z.ui.spacer(),
              z.ui.segmented(RATES.map(String), rate, i => { rate = i; save(); })]),
    z.ui.button("Make the GIF…", () => {
      started();
      z.media.gif(video.id, { width: WIDTHS[width], fps: RATES[rate] }, r => finished(r, r => "Saved " + r.saved));
    }, { style: "prominent", symbol: "sparkles.tv", disabled: !video }),
  ];
}

function watermarkTab() {
  return [
    chosenImages(),
    z.ui.field({ value: mark, placeholder: "Watermark text, like © Your Name", id: "mark", onChange: t => { mark = t; save(); } }),
    z.ui.picker("Position", POSITIONS.map(p => p.label), position, i => { position = i; save(); }),
    z.ui.row([z.ui.text("Opacity"), z.ui.spacer(),
              z.ui.slider({ value: opacity, min: 0.2, max: 1, step: 0.1, onChange: v => { opacity = v; save(); } })]),
    z.ui.button("Add and Save…", () => {
      started();
      z.media.watermark(images.map(i => i.id), { text: mark, position: POSITIONS[position].id, opacity },
                        r => finished(r, r => "Watermarked " + r.count + " image" + (r.count === 1 ? "" : "s")));
    }, { style: "prominent", symbol: "signature", disabled: !images.length || !mark.trim() }),
  ];
}

zephydian.utility({
  start() {
    const p = z.storage.get("prefs") || {};
    ({ tab = 0, quality = 1, format = 0, width = 1, rate = 1, position = 0, opacity = 0.8, mark = "" } = p);
  },

  tick() {},

  view() {
    const job = z.media.status();
    const content = [shrinkTab, convertTab, gifTab, watermarkTab][tab]();
    return z.ui.column([
      z.ui.segmented(TABS, tab, i => { tab = i; result = ""; save(); }),
      z.ui.section(null, content),
      job ? z.ui.text(job.label + " " + Math.round(job.progress * 100) + "%", { style: "secondary" })
          : result ? z.ui.text(result, { style: "secondary", selectable: true }) : null,
      z.ui.text("Everything happens on your Mac. The originals are never changed.", { style: "caption" }),
    ], { spacing: 12 });
  },
});
