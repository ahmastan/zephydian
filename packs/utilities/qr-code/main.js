// QR Code: text or a link in, a QR code out. The code is made by macOS on this Mac (z.qr),
// so nothing is sent anywhere. Copy it as an image, or save a PNG where you choose.

const LEVELS = ["L", "M", "Q", "H"];
const LEVEL_NAMES = ["Low (7%)", "Medium (15%)", "Quartile (25%)", "High (30%)"];
const QUIET = 4;           // the white border QR readers need, in modules

let text = "";
let level = 1;

function save() { z.storage.set("state", { text: text.slice(0, 2000), level }); }
function modules() { return text ? z.qr(text, { level: LEVELS[level] }) : null; }

/// Black modules on white, drawn as horizontal runs (fewer shapes, no seams between modules).
function drawCode(g, size, m, overlap) {
  const n = m.length + QUIET * 2, cell = size / n;
  g.rect(0, 0, size, size, { fill: "#ffffff" });
  for (let y = 0; y < m.length; y++) {
    let x = 0;
    while (x < m.length) {
      if (!m[y][x]) { x++; continue; }
      const start = x;
      while (x < m.length && m[y][x]) x++;
      g.rect((start + QUIET) * cell, (y + QUIET) * cell, (x - start) * cell + overlap, cell + overlap, { fill: "#000000" });
    }
  }
}

/// The image for copying and saving: whole pixels per module, about 1000 pixels wide.
function image(m) {
  const n = m.length + QUIET * 2, cell = Math.max(4, Math.floor(1000 / n)), size = n * cell;
  return { width: size, height: size, scale: 1, draw(g) { drawCode(g, size, m, 0); } };
}

zephydian.utility({
  start() {
    const s = z.storage.get("state");
    if (s) { text = s.text || ""; level = s.level == null ? 1 : s.level; }
  },

  view() {
    const m = modules();
    const side = Math.min(Math.floor(z.width), 240);
    return z.ui.column([
      z.ui.field({ value: text, placeholder: "Text or a link", multiline: true, lines: 3, id: "text",
                   onChange: t => { text = t; save(); } }),
      !text ? z.ui.text("Type something above to make its QR code.", { style: "secondary", align: "center" })
        : !m ? z.ui.text("That's too long for a QR code. Try something shorter.", { style: "secondary", align: "center" })
        : z.ui.canvas({ width: side, height: side, id: "code", draw(g, w) { drawCode(g, w, m, 0.4); } }),
      z.ui.row([
        z.ui.button("Copy image", () => { if (z.clipboard.writeImage(image(m))) z.toast("Copied"); },
                    { symbol: "doc.on.doc", disabled: !m }),
        z.ui.button("Save PNG…", () => z.files.save({ name: "QR Code.png", image: image(m) }, ok => { if (ok) z.toast("Saved"); }),
                    { symbol: "square.and.arrow.down", disabled: !m }),
      ], { align: "center" }),
      z.ui.picker("Error correction", LEVEL_NAMES, level, i => { level = i; save(); }),
      z.ui.text("Higher error correction still scans when part of the code is covered, but makes it denser. Made on this Mac; nothing is sent anywhere.", { style: "caption" }),
    ], { spacing: 12 });
  },
});
