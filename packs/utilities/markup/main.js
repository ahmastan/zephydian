// Markup: crop, annotate, pixelate and dress up an image in its own window. In the panel it lists
// this session's screenshots and can open an image file or paste one; clicking a screenshot's
// preview opens it here directly. The editing is all in this file: the document is a list of marks
// drawn over the picture, with undo and redo. Zephydian draws it, turns it into an image and saves it.

// The tool rail, top to bottom. Markup opens on Crop.
const TOOLS = [
  { id: "crop", label: "Crop", symbol: "crop", key: "c" },
  { id: "select", label: "Select", symbol: "cursorarrow", key: "v" },
  { id: "arrow", label: "Arrow", symbol: "arrow.up.right", key: "a" },
  { id: "line", label: "Line", symbol: "line.diagonal", key: "l" },
  { id: "rect", label: "Rectangle", symbol: "rectangle", key: "r" },
  { id: "ellipse", label: "Ellipse", symbol: "circle", key: "o" },
  { id: "highlight", label: "Highlight", symbol: "highlighter", key: "h" },
  { id: "pixelate", label: "Pixelate", symbol: "checkerboard.rectangle", key: "x" },
  { id: "redact", label: "Redact", symbol: "rectangle.fill", key: "b" },
  { id: "pen", label: "Pen", symbol: "scribble", key: "p" },
  { id: "text", label: "Text", symbol: "textformat", key: "t" },
  { id: "counter", label: "Numbered step", symbol: "1.circle", key: "n" },
  { id: "sticker", label: "Sticker", symbol: "star.circle", key: "s" },
];
const COLORS = [
  { hex: "#ff3b30", name: "Red" }, { hex: "#ff9500", name: "Orange" }, { hex: "#ffcc00", name: "Yellow" },
  { hex: "#34c759", name: "Green" }, { hex: "#007aff", name: "Blue" }, { hex: "#af52de", name: "Purple" },
  { hex: "#1c1c1e", name: "Black" }, { hex: "#ffffff", name: "White" },
];
const STROKES = [{ name: "Thin", w: 2, bar: 1.8 }, { name: "Medium", w: 4, bar: 3.4 }, { name: "Thick", w: 7, bar: 5.4 }];
const TEXT_SIZES = [12, 14, 16, 18, 20, 24, 28, 32, 40, 48, 64];
const ARROWS = ["Filled", "Outline", "Open", "Double"];
const BLUR = [0.4, 0.65, 1, 1.5, 2.2];      // pixelate block size by strength, 1 to 5
const STICKERS = [
  { name: "Check", symbol: "checkmark.circle.fill", color: "#34c759" },
  { name: "Cross", symbol: "xmark.circle.fill", color: "#ff3b30" },
  { name: "Star", symbol: "star.fill", color: "#ffcc00" },
  { name: "Heart", symbol: "heart.fill", color: "#ff2d55" },
  { name: "Thumbs up", symbol: "hand.thumbsup.fill", color: "#007aff" },
  { name: "Thumbs down", symbol: "hand.thumbsdown.fill", color: "#ff9500" },
  { name: "Warning", symbol: "exclamationmark.triangle.fill", color: "#ffcc00" },
  { name: "Question", symbol: "questionmark.circle.fill", color: "#af52de" },
  { name: "Flame", symbol: "flame.fill", color: "#ff9500" },
  { name: "Bolt", symbol: "bolt.fill", color: "#ffcc00" },
  { name: "Pin", symbol: "mappin.circle.fill", color: "#ff3b30" },
  { name: "Eyes", symbol: "eyes", color: "#1c1c1e" },
];
const BACKDROPS = [
  { name: "None" },
  { name: "Sunset", colors: ["#ff7e5f", "#feb47b"] }, { name: "Ocean", colors: ["#2193b0", "#6dd5ed"] },
  { name: "Lavender", colors: ["#834d9b", "#d04ed6"] }, { name: "Mint", colors: ["#43cea2", "#185a9d"] },
  { name: "Graphite", colors: ["#48484a", "#1c1c1e"] }, { name: "Paper", colors: ["#f2f2f7", "#d1d1d6"] },
];
const ASPECTS = ["Freeform", "Original", "Square", "4:3", "16:9"];
const MAX_UNDO = 100;
const RECTS = ["rect", "ellipse", "highlight", "pixelate", "redact"];   // made by dragging out a rectangle

// MARK: - The panel: pick what to edit

function openWindow(info) {
  if (info) z.window.open({ image: info.id });
}

function time(ms) { return new Date(ms).toLocaleTimeString([], { hour: "numeric", minute: "2-digit", second: "2-digit" }); }

function panelView() {
  const shots = z.images.screenshots();
  return z.ui.column([
    z.ui.text("Mark up a screenshot or any image. It opens in its own window.", { style: "secondary" }),
    z.ui.row([
      z.ui.button("Open Image…", () => z.images.open(openWindow), { symbol: "photo", style: "prominent" }),
      z.ui.button("Paste Image", () => {
        const info = z.images.paste();
        if (info) openWindow(info); else z.toast("There's no image on the clipboard");
      }, { symbol: "doc.on.clipboard" }),
    ], { align: "center" }),
    z.ui.section("This session's screenshots", [
      z.ui.list(shots.map(s => ({
        id: s.id, title: time(s.at), image: s.image,
        subtitle: s.width + " × " + s.height + (s.saved ? " · " + s.saved : " · not saved"),
        actions: [{ symbol: "pencil.tip.crop.circle", label: "Edit" }],
      })), {
        empty: "Screenshots you take with Screenshot appear here.",
        onSelect: id => openWindow(z.images.fromScreenshot(id)),
        onAction: id => openWindow(z.images.fromScreenshot(id)),
      }),
    ]),
    z.ui.text("You can also click a screenshot's preview to edit it.", { style: "caption", align: "center" }),
  ], { spacing: 12 });
}

// MARK: - The window: state

let img = null, info = null;       // the picture ("image:<id>") and { name, width, height, source, saved }
let W = 1, H = 1, u = 1;           // its size in pixels, and the unit marks are measured in
let doc = { items: [], crop: null, backdrop: 0, shadow: false };
let undoStack = [], redoStack = [];
let tool = "crop";                 // Markup opens on the crop box
let color = COLORS[0].hex, stroke = 1, textSize = 24, arrowStyle = 0, blur = 3, sticker = 0, aspect = 0;
let selected = -1;                 // the mark the Select tool picked
let drag = null;                   // a mark being dragged out, in image pixels
let move = null;                   // { index, handle, x, y, before, orig } while Select moves or resizes a mark
let cropDrag = null;               // { handle, x, y, from, box } while the crop box is adjusted
let hoverCursor = null;
let typing = null;                 // { id, x, y, text, index } while a text label is typed (index: the label being edited)
let nextID = 1;
let scale = 1;                     // screen points per image pixel (from the canvas)
let dirty = false;                 // changed since the last save
let discarded = false, closing = false;

const clamp = (v, lo, hi) => Math.min(Math.max(v, lo), hi);
const clone = o => JSON.parse(JSON.stringify(o));
const pt = n => n / scale;         // n screen points, in image pixels
const full = () => ({ x: 0, y: 0, w: W, h: H });
const edited = () => doc.items.length > 0 || doc.crop != null || doc.backdrop > 0 || doc.shadow;
const lineWidth = () => STROKES[stroke].w * u;

function commit(change) {
  undoStack.push(JSON.stringify(doc));
  if (undoStack.length > MAX_UNDO) undoStack.shift();
  redoStack = [];
  change();
  touched();
}

function touched() {
  dirty = true;
  z.window.edited(true);
}

function restore(from, to) {
  if (!from.length) return false;
  to.push(JSON.stringify(doc));
  doc = JSON.parse(from.pop());
  drag = null; move = null; cropDrag = null; typing = null;
  if (selected >= doc.items.length) selected = -1;
  touched();
  return true;
}

/// The part of the picture that's kept.
function frame() { return doc.crop || full(); }
/// What the canvas shows: everything while cropping, the crop otherwise.
function view() { return tool === "crop" ? full() : frame(); }
/// The backdrop's margin around the picture, in pixels (none while cropping).
function margin(box) { return doc.backdrop && tool !== "crop" ? Math.round(Math.max(box.w, box.h) * 0.06) : 0; }
function exportMargin() { const b = frame(); return doc.backdrop ? Math.round(Math.max(b.w, b.h) * 0.06) : 0; }

// MARK: Drawing marks

function withAlpha(hex, a) { return hex.slice(0, 7) + Math.round(a * 255).toString(16).padStart(2, "0"); }
function normalized(d) {
  return { x: Math.min(d.x1, d.x2), y: Math.min(d.y1, d.y2), w: Math.abs(d.x2 - d.x1), h: Math.abs(d.y2 - d.y1) };
}

function arrowHead(g, fromX, fromY, toX, toY, it, style) {
  const dx = toX - fromX, dy = toY - fromY, len = Math.hypot(dx, dy);
  const head = Math.min(len * 0.6, Math.max(it.lw * 3.5, 10 * u)), ux = dx / len, uy = dy / len;
  const bx = toX - ux * head, by = toY - uy * head, half = head * 0.55;
  const a = [bx - uy * half, by + ux * half], b = [bx + uy * half, by - ux * half];
  if (style === "Open") g.path([a, [toX, toY], b], { stroke: it.color, lineWidth: it.lw, cap: "round" });
  else if (style === "Outline") g.path([[toX, toY], a, b], { stroke: it.color, lineWidth: Math.max(1, it.lw * 0.7), closed: true, cap: "round" });
  else g.path([[toX, toY], a, b], { fill: it.color, closed: true });
  return style === "Open" ? [toX, toY] : [bx + ux, by + uy];
}

function drawArrow(g, it) {
  const len = Math.hypot(it.x2 - it.x1, it.y2 - it.y1);
  if (len < 1) return;
  const style = ARROWS[it.style || 0];
  let start = [it.x1, it.y1];
  const end = arrowHead(g, it.x1, it.y1, it.x2, it.y2, it, style);
  if (style === "Double") start = arrowHead(g, it.x2, it.y2, it.x1, it.y1, it, "Filled");
  g.line(start[0], start[1], end[0], end[1], { stroke: it.color, lineWidth: it.lw, cap: "round" });
}

function drawItem(g, it, index) {
  if (typing && typing.index === index) return;          // being retyped: the text field shows it
  const shadow = doc.shadow && !["pixelate", "highlight"].includes(it.t);
  if (shadow) { g.save(); g.shadow("#00000066", { radius: 4 * u, y: 2 * u }); }
  switch (it.t) {
    case "arrow": drawArrow(g, it); break;
    case "line": g.line(it.x1, it.y1, it.x2, it.y2, { stroke: it.color, lineWidth: it.lw, cap: "round" }); break;
    case "rect": g.rect(it.x, it.y, it.w, it.h, { stroke: it.color, lineWidth: it.lw, radius: it.lw }); break;
    case "ellipse": g.ellipse(it.x, it.y, it.w, it.h, { stroke: it.color, lineWidth: it.lw }); break;
    case "highlight": g.rect(it.x, it.y, it.w, it.h, { fill: withAlpha(it.color, 0.35), radius: 2 * u }); break;
    case "redact": g.rect(it.x, it.y, it.w, it.h, { fill: it.color }); break;
    case "pen": g.path(it.points, { stroke: it.color, lineWidth: it.lw, cap: "round" }); break;
    case "pixelate":
      g.save();
      g.clip(it.x, it.y, it.w, it.h);
      g.image(img, 0, 0, W, H, { pixelate: Math.max(4, Math.round(8 * u * BLUR[(it.level || 3) - 1])) });
      g.restore();
      break;
    case "text":
      g.text(it.text, it.x, it.y, { size: it.size, color: it.color, weight: "semibold" });
      break;
    case "counter": {
      const light = it.color === "#ffffff" || it.color === "#ffcc00";
      g.circle(it.x, it.y, it.r, { fill: it.color, stroke: light ? "#00000055" : "#ffffffcc", lineWidth: Math.max(1, it.r / 8) });
      g.text(String(it.n), it.x, it.y, { size: it.r * 1.15, color: light ? "#000000" : "#ffffff", weight: "bold", align: "center" });
      break;
    }
    case "sticker": {
      const s = STICKERS[it.id] || STICKERS[0];
      g.symbol(s.symbol, it.x, it.y, it.side, { color: s.color });
      break;
    }
  }
  if (shadow) g.restore();
}

/// The picture with every mark on it, in image pixels.
function paint(g) {
  g.image(img, 0, 0, W, H);
  doc.items.forEach((it, i) => drawItem(g, it, i));
}

/// The backdrop, the picture on it (rounded, with a shadow) and the marks. `box` is the part shown.
function compose(g, box, pad) {
  if (pad) {
    const b = BACKDROPS[doc.backdrop];
    g.gradient(0, 0, box.w + pad * 2, box.h + pad * 2, b.colors);
    const r = Math.round(Math.min(box.w, box.h) * 0.02 + 4 * u);
    g.save();
    g.shadow("#00000073", { radius: pad * 0.35, y: pad * 0.12 });
    g.rect(pad, pad, box.w, box.h, { fill: "#000000", radius: r });
    g.restore();
    g.save();
    g.clip(pad, pad, box.w, box.h, { radius: r });
  }
  g.save();
  g.translate(pad - box.x, pad - box.y);
  paint(g);
  g.restore();
  if (pad) g.restore();
}

/// The finished image: marks flattened, cropped, on its backdrop.
function exported() {
  const box = frame(), pad = exportMargin();
  return { width: box.w + pad * 2, height: box.h + pad * 2, scale: 1, draw(g) { compose(g, box, pad); } };
}

function drawCanvas(g) {
  const v = view(), pad = margin(v);
  compose(g, v, pad);
  g.save();
  g.translate(pad - v.x, pad - v.y);
  if (drag) drawItem(g, dragItem(), -1);
  if (tool === "select" && selected >= 0 && doc.items[selected]) drawSelection(g, doc.items[selected]);
  if (tool === "crop") drawCropBox(g);
  g.restore();
}

// MARK: Marks: making, bounds, hit-testing

/// The mark being dragged out, as the mark it would become.
function dragItem() {
  const d = drag, lw = lineWidth();
  if (tool === "arrow") return { t: "arrow", x1: d.x1, y1: d.y1, x2: d.x2, y2: d.y2, color, lw, style: arrowStyle };
  if (tool === "line") return { t: "line", x1: d.x1, y1: d.y1, x2: d.x2, y2: d.y2, color, lw };
  const r = normalized(d);
  if (tool === "pixelate") return Object.assign({ t: "pixelate", level: blur }, r);
  if (tool === "highlight" || tool === "redact") return Object.assign({ t: tool, color }, r);
  return Object.assign({ t: tool, color, lw }, r);
}

function bounds(it) {
  switch (it.t) {
    case "arrow": case "line": return normalized(it);
    case "pen": {
      const xs = it.points.map(p => p[0]), ys = it.points.map(p => p[1]);
      const x = Math.min(...xs), y = Math.min(...ys);
      return { x, y, w: Math.max(...xs) - x, h: Math.max(...ys) - y };
    }
    case "text": return { x: it.x, y: it.y - it.size * 0.65, w: Math.max(it.size, it.text.length * it.size * 0.56), h: it.size * 1.3 };
    case "counter": return { x: it.x - it.r, y: it.y - it.r, w: it.r * 2, h: it.r * 2 };
    case "sticker": return { x: it.x - it.side / 2, y: it.y - it.side / 2, w: it.side, h: it.side };
    default: return { x: it.x, y: it.y, w: it.w, h: it.h };
  }
}

function segmentDistance(px, py, x1, y1, x2, y2) {
  const dx = x2 - x1, dy = y2 - y1, l2 = dx * dx + dy * dy;
  const t = l2 ? clamp(((px - x1) * dx + (py - y1) * dy) / l2, 0, 1) : 0;
  return Math.hypot(px - (x1 + t * dx), py - (y1 + t * dy));
}

function hits(it, x, y) {
  const slack = Math.max(pt(6), (it.lw || 0) / 2 + pt(3));
  if (it.t === "arrow" || it.t === "line") return segmentDistance(x, y, it.x1, it.y1, it.x2, it.y2) <= slack;
  if (it.t === "pen") {
    for (let i = 1; i < it.points.length; i++) {
      const a = it.points[i - 1], b = it.points[i];
      if (segmentDistance(x, y, a[0], a[1], b[0], b[1]) <= slack) return true;
    }
    return it.points.length === 1 && Math.hypot(x - it.points[0][0], y - it.points[0][1]) <= slack;
  }
  const b = bounds(it);
  return x >= b.x - slack && x <= b.x + b.w + slack && y >= b.y - slack && y <= b.y + b.h + slack;
}

/// The top-most mark under a point.
function markAt(x, y) {
  for (let i = doc.items.length - 1; i >= 0; i--) if (hits(doc.items[i], x, y)) return i;
  return -1;
}

/// Grips on the selected mark: the two ends of an arrow or line, the corners of a box.
function grips(it) {
  if (it.t === "arrow" || it.t === "line") return [{ id: "p1", x: it.x1, y: it.y1 }, { id: "p2", x: it.x2, y: it.y2 }];
  if (!RECTS.includes(it.t) && it.t !== "sticker") return [];
  const b = bounds(it);
  return [{ id: "nw", x: b.x, y: b.y }, { id: "ne", x: b.x + b.w, y: b.y }, { id: "sw", x: b.x, y: b.y + b.h }, { id: "se", x: b.x + b.w, y: b.y + b.h }];
}

function gripAt(it, x, y) {
  return grips(it).find(p => Math.hypot(p.x - x, p.y - y) <= pt(9));
}

function drawSelection(g, it) {
  const b = bounds(it), o = pt(4);
  if (it.t !== "arrow" && it.t !== "line") {
    g.rect(b.x - o, b.y - o, b.w + o * 2, b.h + o * 2, { stroke: "#ffffff", lineWidth: pt(3) });
    g.rect(b.x - o, b.y - o, b.w + o * 2, b.h + o * 2, { stroke: "accent", lineWidth: pt(1.5) });
  }
  for (const p of grips(it)) {
    g.circle(p.x, p.y, pt(5), { fill: "#ffffff", stroke: "accent", lineWidth: pt(1.5) });
  }
}

/// Moves or resizes `orig` by (dx, dy).
function moved(orig, handle, dx, dy) {
  const it = clone(orig);
  if (handle === "body") {
    if ("x1" in it) { it.x1 += dx; it.y1 += dy; it.x2 += dx; it.y2 += dy; }
    else if (it.t === "pen") it.points = it.points.map(p => [p[0] + dx, p[1] + dy]);
    else { it.x += dx; it.y += dy; }
    return it;
  }
  if (handle === "p1") { it.x1 += dx; it.y1 += dy; return it; }
  if (handle === "p2") { it.x2 += dx; it.y2 += dy; return it; }
  const b = bounds(orig);
  let l = b.x, t = b.y, r = b.x + b.w, bt = b.y + b.h;
  if (handle.includes("w")) l += dx; else r += dx;
  if (handle.includes("n")) t += dy; else bt += dy;
  const box = normalized({ x1: l, y1: t, x2: r, y2: bt });
  if (it.t === "sticker") {
    it.side = Math.max(pt(16), Math.max(box.w, box.h));
    it.x = box.x + box.w / 2; it.y = box.y + box.h / 2;
  } else {
    Object.assign(it, { x: box.x, y: box.y, w: Math.max(1, box.w), h: Math.max(1, box.h) });
  }
  return it;
}

// MARK: The crop box
//
// Like cropping a photo on iPhone: a box around the picture that you resize by its corners and
// edges, or move by dragging inside it. The part outside is dimmed, and a rule-of-thirds grid shows
// while you adjust it. Each adjustment is one step to undo.

const cropBox = () => cropDrag ? cropDrag.box : frame();

/// The aspect ratio to keep (width ÷ height), or null for Freeform. 4:3 and 16:9 follow the box's
/// orientation, so a tall box gets 3:4 or 9:16.
function ratio(box) {
  const tall = box.h > box.w;
  switch (ASPECTS[aspect]) {
    case "Original": return W / H;
    case "Square": return 1;
    case "4:3": return tall ? 3 / 4 : 4 / 3;
    case "16:9": return tall ? 9 / 16 : 16 / 9;
    default: return null;
  }
}

/// The largest box of the chosen shape that fits in `box`, centered on it.
function fitRatio(box, r) {
  if (!r) return box;
  let w = box.w, h = w / r;
  if (h > box.h) { h = box.h; w = h * r; }
  return { x: box.x + (box.w - w) / 2, y: box.y + (box.h - h) / 2, w, h };
}

function drawCropBox(g) {
  const c = cropBox(), dim = { fill: "#00000099" };
  g.rect(0, 0, W, c.y, dim);
  g.rect(0, c.y + c.h, W, H - c.y - c.h, dim);
  g.rect(0, c.y, c.x, c.h, dim);
  g.rect(c.x + c.w, c.y, W - c.x - c.w, c.h, dim);
  // White lines with a soft dark edge, so they show on light pictures (screenshots) as well as dark.
  const edge = "#00000059";
  g.rect(c.x, c.y, c.w, c.h, { stroke: edge, lineWidth: pt(3) });
  g.rect(c.x, c.y, c.w, c.h, { stroke: "#ffffffe6", lineWidth: pt(1) });
  if (cropDrag) {
    for (const f of [1 / 3, 2 / 3]) {
      for (const [col, lw] of [[edge, 2], ["#ffffffb3", 1]]) {
        g.line(c.x + c.w * f, c.y, c.x + c.w * f, c.y + c.h, { stroke: col, lineWidth: pt(lw) });
        g.line(c.x, c.y + c.h * f, c.x + c.w, c.y + c.h * f, { stroke: col, lineWidth: pt(lw) });
      }
    }
  }
  // Thick corners and short bars in the middle of each edge, just inside the box.
  const t = pt(3), len = Math.min(pt(22), c.w / 3, c.h / 3), o = t / 2;
  const x1 = c.x + o, y1 = c.y + o, x2 = c.x + c.w - o, y2 = c.y + c.h - o;
  const mx = c.x + c.w / 2, my = c.y + c.h / 2, bar = Math.min(pt(18), c.w / 4, c.h / 4);
  for (const style of [{ stroke: edge, lineWidth: t + pt(2) }, { stroke: "#ffffff", lineWidth: t }]) {
    g.path([[x1, y1 + len], [x1, y1], [x1 + len, y1]], style);
    g.path([[x2 - len, y1], [x2, y1], [x2, y1 + len]], style);
    g.path([[x1, y2 - len], [x1, y2], [x1 + len, y2]], style);
    g.path([[x2 - len, y2], [x2, y2], [x2, y2 - len]], style);
    g.line(mx - bar, y1, mx + bar, y1, style);
    g.line(mx - bar, y2, mx + bar, y2, style);
    g.line(x1, my - bar, x1, my + bar, style);
    g.line(x2, my - bar, x2, my + bar, style);
  }
}

/// Which part of the box is under a point: a corner ("nw"…), an edge ("n"…), "move" inside, or null.
function cropHandle(x, y) {
  const c = cropBox(), grab = pt(14), corner = pt(20);
  const nearL = Math.abs(x - c.x) < grab, nearR = Math.abs(x - (c.x + c.w)) < grab;
  const nearT = Math.abs(y - c.y) < grab, nearB = Math.abs(y - (c.y + c.h)) < grab;
  const inX = x > c.x - grab && x < c.x + c.w + grab, inY = y > c.y - grab && y < c.y + c.h + grab;
  const cornerX = Math.abs(x - c.x) < corner ? "w" : Math.abs(x - (c.x + c.w)) < corner ? "e" : "";
  const cornerY = Math.abs(y - c.y) < corner ? "n" : Math.abs(y - (c.y + c.h)) < corner ? "s" : "";
  if (cornerX && cornerY) return cornerY + cornerX;
  if (nearT && inX) return "n";
  if (nearB && inX) return "s";
  if (nearL && inY) return "w";
  if (nearR && inY) return "e";
  if (x > c.x && x < c.x + c.w && y > c.y && y < c.y + c.h) return "move";
  return null;
}

const CURSORS = { nw: "resize-nwse", se: "resize-nwse", ne: "resize-nesw", sw: "resize-nesw",
                  n: "resize-ns", s: "resize-ns", e: "resize-ew", w: "resize-ew", move: "move" };

/// The box after dragging `handle` by (dx, dy) from `from`, kept inside the picture, at least
/// 40 points on screen, and in the chosen shape.
function resized(from, handle, dx, dy) {
  const min = Math.min(pt(40), W, H);
  if (handle === "move") {
    return { x: clamp(from.x + dx, 0, W - from.w), y: clamp(from.y + dy, 0, H - from.h), w: from.w, h: from.h };
  }
  let l = from.x, t = from.y, r = from.x + from.w, b = from.y + from.h;
  if (handle.includes("w")) l = clamp(l + dx, 0, r - min);
  if (handle.includes("e")) r = clamp(r + dx, l + min, W);
  if (handle.includes("n")) t = clamp(t + dy, 0, b - min);
  if (handle.includes("s")) b = clamp(b + dy, t + min, H);
  const k = ratio(from);
  if (!k) return { x: l, y: t, w: r - l, h: b - t };
  // Keep the shape: the dragged side leads, and the other one follows from the fixed corner or the
  // middle of the fixed edge, shrinking if it would leave the picture.
  let w = r - l, h = b - t;
  const horizontal = handle === "e" || handle === "w", vertical = handle === "n" || handle === "s";
  if (horizontal) h = w / k;
  else if (vertical) w = h * k;
  else if (w / h > k) h = w / k; else w = h * k;
  const ax = handle.includes("w") ? r : handle.includes("e") ? l : from.x + from.w / 2;
  const ay = handle.includes("n") ? b : handle.includes("s") ? t : from.y + from.h / 2;
  const roomX = handle.includes("w") ? ax : handle.includes("e") ? W - ax : 2 * Math.min(ax, W - ax);
  const roomY = handle.includes("n") ? ay : handle.includes("s") ? H - ay : 2 * Math.min(ay, H - ay);
  const fit = Math.min(1, roomX / w, roomY / h);
  w *= fit; h *= fit;
  const x = handle.includes("w") ? ax - w : handle.includes("e") ? ax : ax - w / 2;
  const y = handle.includes("n") ? ay - h : handle.includes("s") ? ay : ay - h / 2;
  return { x, y, w, h };
}

function setCrop(box) {
  const c = { x: Math.round(box.x), y: Math.round(box.y), w: Math.round(box.w), h: Math.round(box.h) };
  const same = (a, b) => a && b && a.x === b.x && a.y === b.y && a.w === b.w && a.h === b.h;
  const next = same(c, full()) ? null : c;
  if (same(next, doc.crop) || (!next && !doc.crop)) return;
  commit(() => { doc.crop = next; });
}

function cropPointer(e, x, y) {
  if (e.type === "down") {
    const handle = cropHandle(x, y);
    cropDrag = handle ? { handle, x, y, from: cropBox(), box: cropBox() } : null;
    return;
  }
  if (!cropDrag) return;
  cropDrag.box = resized(cropDrag.from, cropDrag.handle, x - cropDrag.x, y - cropDrag.y);
  if (e.type !== "up") return;
  const box = cropDrag.box;
  cropDrag = null;
  setCrop(box);
}

function pickAspect(i) {
  aspect = i;
  const k = ratio(cropBox());
  if (k) setCrop(fitRatio(cropBox(), k));
}

// MARK: Pointer and typing

/// A canvas point in image pixels.
function imagePoint(e) {
  const v = view(), pad = margin(v);
  return [e.x - pad + v.x, e.y - pad + v.y];
}

function selectPointer(e, x, y) {
  if (e.type === "down") {
    const current = doc.items[selected];
    const grip = current && gripAt(current, x, y);
    const index = grip ? selected : markAt(x, y);
    selected = index;
    if (index < 0) { move = null; return; }
    if (e.clicks >= 2 && doc.items[index].t === "text") {
      const it = doc.items[index];
      typing = { id: "t" + nextID++, x: it.x, y: it.y, text: it.text, index };
      move = null;
      return;
    }
    move = { index, handle: grip ? grip.id : "body", x, y, before: JSON.stringify(doc), orig: clone(doc.items[index]) };
    return;
  }
  if (!move) return;
  doc.items[move.index] = moved(move.orig, move.handle, x - move.x, y - move.y);
  if (e.type !== "up") return;
  const before = move.before;
  move = null;
  if (before !== JSON.stringify(doc)) {
    undoStack.push(before);
    redoStack = [];
    touched();
  }
}

function pointer(e) {
  if (e.scale) scale = e.scale;
  const [x, y] = imagePoint(e);
  if (tool === "crop") return cropPointer(e, x, y);
  if (tool === "select") return selectPointer(e, x, y);
  if (e.type === "down") {
    if (tool === "text") {
      typing = { id: "t" + nextID++, x, y, text: "", index: -1 };
      return;
    }
    if (tool === "counter") {
      const n = doc.items.filter(i => i.t === "counter").length + 1;
      commit(() => doc.items.push({ t: "counter", x, y, n, r: (STROKES[stroke].w * 2.5 + 7) * u, color }));
      return;
    }
    if (tool === "sticker") {
      const side = Math.max(24 * u, Math.min(W, H) * 0.12);
      commit(() => doc.items.push({ t: "sticker", x, y, side, id: sticker }));
      return;
    }
    drag = { x1: clamp(x, 0, W), y1: clamp(y, 0, H), x2: clamp(x, 0, W), y2: clamp(y, 0, H) };
    return;
  }
  if (!drag) return;
  let x2 = clamp(x, 0, W), y2 = clamp(y, 0, H);
  if (e.shift) {
    const dx = x2 - drag.x1, dy = y2 - drag.y1;
    if (tool === "arrow" || tool === "line") {
      // Snap to 45° steps.
      const a = Math.round(Math.atan2(dy, dx) / (Math.PI / 4)) * (Math.PI / 4), len = Math.hypot(dx, dy);
      x2 = drag.x1 + Math.cos(a) * len; y2 = drag.y1 + Math.sin(a) * len;
    } else {
      // A square or a circle.
      const side = Math.max(Math.abs(dx), Math.abs(dy));
      x2 = drag.x1 + Math.sign(dx || 1) * side; y2 = drag.y1 + Math.sign(dy || 1) * side;
    }
  }
  drag.x2 = x2; drag.y2 = y2;
  if (e.type !== "up") return;
  const d = drag, r = normalized(d), item = dragItem();
  drag = null;
  const lineLike = tool === "arrow" || tool === "line";
  const big = lineLike ? Math.hypot(d.x2 - d.x1, d.y2 - d.y1) > 4 * u : r.w > 3 * u && r.h > 3 * u;
  if (big) commit(() => doc.items.push(item));
}

function hover(e) {
  if (e.scale) scale = e.scale;
  const [x, y] = imagePoint(e);
  if (tool === "crop") hoverCursor = CURSORS[cropHandle(x, y)] || null;
  else if (tool === "select") {
    const it = doc.items[selected], grip = it && gripAt(it, x, y);
    hoverCursor = grip ? (grip.id === "nw" || grip.id === "se" ? "resize-nwse" : grip.id === "ne" || grip.id === "sw" ? "resize-nesw" : "pointer")
      : markAt(x, y) >= 0 ? "move" : null;
  }
}

function penStroke(e) {
  const v = view(), pad = margin(v);
  const points = e.points.map(p => [p[0] - pad + v.x, p[1] - pad + v.y]);
  commit(() => doc.items.push({ t: "pen", points, color, lw: lineWidth() }));
}

function endTyping(text) {
  const t = typing;
  typing = null;
  if (!t) return;
  const value = text.slice(0, 500);
  if (t.index >= 0) {
    // Retyping a label: empty removes it.
    if (value === doc.items[t.index].text) return;
    commit(() => {
      if (value.trim()) doc.items[t.index].text = value; else { doc.items.splice(t.index, 1); selected = -1; }
    });
  } else if (value.trim()) {
    commit(() => doc.items.push({ t: "text", x: t.x, y: t.y, text: value, size: textSize * u, color }));
  }
}

// MARK: Styles (they change the selected mark too)

function current() { return tool === "select" && selected >= 0 ? doc.items[selected] : null; }

function restyle(change) {
  if (current()) commit(() => change(doc.items[selected]));
}

function setColor(hex) {
  color = hex;
  restyle(it => { if ("color" in it) it.color = hex; });
}

function setStroke(i) {
  stroke = i;
  restyle(it => {
    if ("lw" in it) it.lw = STROKES[i].w * u;
    if (it.t === "counter") it.r = (STROKES[i].w * 2.5 + 7) * u;
  });
}

function setTextSize(size) {
  textSize = size;
  restyle(it => { if (it.t === "text") it.size = size * u; });
}

function setArrowStyle(i) {
  arrowStyle = i;
  restyle(it => { if (it.t === "arrow") it.style = i; });
}

function setBlur(level) {
  blur = level;
  restyle(it => { if (it.t === "pixelate") it.level = level; });
}

function setSticker(i) {
  sticker = i;
  restyle(it => { if (it.t === "sticker") it.id = i; });
}

function moveLayer(step) {
  const i = selected, j = i + step;
  if (i < 0 || j < 0 || j >= doc.items.length) return;
  commit(() => { const t = doc.items[i]; doc.items[i] = doc.items[j]; doc.items[j] = t; });
  selected = j;
}

function deleteSelected() {
  if (selected < 0) return false;
  commit(() => doc.items.splice(selected, 1));
  selected = -1;
  return true;
}

// MARK: Actions

function finishTyping() { if (typing) endTyping(typing.text); }

function copy() {
  finishTyping();
  if (z.images.copy(exported())) z.toast("Copied"); else z.toast("Couldn't copy the image");
}

/// Saves where the picture came from, then calls `then(saved)` (Save As… for a pasted picture).
function save(then) {
  finishTyping();
  if (info.source === "clipboard") return saveAs(then);
  const name = z.images.save(img, exported());
  if (name) {
    dirty = false;
    z.window.edited(false);
    info = z.images.info(img) || info;
    z.toast("Saved as " + name);
    if (then) then(true);
  } else if (info.source === "file") {
    z.toast("This file can't be saved here, so choose where to save a copy");
    saveAs(then);
  } else {
    z.toast("Couldn't save it there");
    if (then) then(false);
  }
}

function saveAs(then) {
  finishTyping();
  z.images.saveAs(img, exported(), saved => {
    if (saved) {
      dirty = false;
      z.window.edited(false);
      z.toast("Saved");
    }
    if (then) then(saved);
  });
}

function discard() {
  discarded = true;
  z.images.discard(img);
  z.window.close();
}

/// The trash button: asks first only if the screenshot was edited.
function remove() {
  if (!edited()) return discard();
  z.window.confirm({
    title: "Delete this screenshot?",
    message: "Your changes are lost too." + (info.saved ? " Its file, " + info.saved + ", moves to the Trash." : ""),
    button: "Delete", destructive: true,
  }, ok => { if (ok) discard(); });
}

function closeAfter(saved) { if (saved) { closing = true; z.window.close(); } }

function pickTool(id) {
  finishTyping();
  drag = null; move = null; cropDrag = null; hoverCursor = null;
  if (id !== "select") selected = -1;
  tool = tool === id && id === "crop" ? "select" : id;
}

// MARK: The window's screen

function rail() {
  return z.ui.toolbar(TOOLS.map(t => z.ui.button(t.label, () => pickTool(t.id), {
    symbol: t.symbol, selected: tool === t.id, badge: t.key.toUpperCase(), id: "tool-" + t.id,
  })), { vertical: true });
}

function actions() {
  const screenshot = info.source === "screenshot";
  return z.ui.toolbar([
    screenshot ? z.ui.button("Delete the screenshot", remove, { symbol: "trash", id: "delete" }) : null,
    screenshot ? z.ui.divider() : null,
    z.ui.button("Undo (⌘Z)", () => restore(undoStack, redoStack), { symbol: "arrow.uturn.backward", disabled: !undoStack.length }),
    z.ui.button("Redo (⇧⌘Z)", () => restore(redoStack, undoStack), { symbol: "arrow.uturn.forward", disabled: !redoStack.length }),
    z.ui.divider(),
    z.ui.menu("Save", ["Save As…"], -1, () => saveAs(), { onPress: () => save(), id: "save" }),
    z.ui.button("Copy", copy, { style: "prominent", id: "copy" }),
  ]);
}

function infoChip() {
  const box = frame(), pad = exportMargin();
  return z.ui.toolbar([z.ui.text((box.w + pad * 2) + " × " + (box.h + pad * 2), { style: "caption" })]);
}

function cropBar() {
  return z.ui.toolbar([
    z.ui.menu("Aspect: " + ASPECTS[aspect], ASPECTS, aspect, pickAspect, { id: "aspect" }),
    z.ui.button("Reset", () => { aspect = 0; setCrop(full()); }, { disabled: !doc.crop, id: "crop-reset" }),
    z.ui.button("Done", () => pickTool("select"), { style: "prominent", id: "crop-done" }),
  ]);
}

function styleBar() {
  const it = current(), kind = it ? it.t : tool;
  const colors = !["select", "pixelate", "sticker"].includes(kind);
  const parts = [];
  const group = items => { parts.push(...items, z.ui.divider()); };
  if (kind === "arrow") group([z.ui.menu("Arrow style", ARROWS, it ? it.style || 0 : arrowStyle, setArrowStyle, { symbol: "arrow.up.right.circle", id: "arrow-style" })]);
  if (kind === "sticker") group([z.ui.menu("Sticker", STICKERS.map(s => s.name), it ? it.id : sticker, setSticker, { symbol: STICKERS[it ? it.id : sticker].symbol, id: "sticker" })]);
  if (kind === "pixelate") {
    const level = it ? it.level : blur;
    group([z.ui.button("Lighter", () => setBlur(Math.max(1, level - 1)), { symbol: "aqi.low" }),
           z.ui.slider({ value: level, min: 1, max: 5, step: 1, onChange: v => setBlur(v), accessibilityLabel: "Pixelate strength", id: "blur" }),
           z.ui.button("Heavier", () => setBlur(Math.min(5, level + 1)), { symbol: "aqi.high" })]);
  }
  if (colors) {
    const chosen = it && it.color ? it.color : color;
    group(COLORS.map(c => z.ui.swatch(c.hex, { shape: "circle", size: 17, selected: chosen === c.hex, accessibilityLabel: c.name,
                                                id: "color-" + c.name, onPress: () => setColor(c.hex) })));
    if (kind === "text") {
      const size = it ? Math.round(it.size / u) : textSize, i = TEXT_SIZES.indexOf(size);
      group([
        z.ui.button("Smaller text", () => setTextSize(TEXT_SIZES[Math.max(0, i - 1)]), { symbol: "textformat.size.smaller", disabled: i <= 0 }),
        z.ui.menu(size + " pt", TEXT_SIZES.map(s => s + " pt"), i, k => setTextSize(TEXT_SIZES[k]), { id: "text-size" }),
        z.ui.button("Larger text", () => setTextSize(TEXT_SIZES[Math.min(TEXT_SIZES.length - 1, i + 1)]), { symbol: "textformat.size.larger", disabled: i >= TEXT_SIZES.length - 1 }),
      ]);
    } else if (!["highlight", "redact"].includes(kind)) {
      const w = it && it.lw ? STROKES.findIndex(s => s.w * u === it.lw) : stroke;
      group(STROKES.map((s, i) => z.ui.button(s.name + " line", () => setStroke(i), { bar: s.bar, selected: w === i, id: "stroke-" + i })));
    }
  }
  if (it && doc.items.length > 1) {
    group([z.ui.button("Send backward", () => moveLayer(-1), { symbol: "square.2.layers.3d.bottom.filled", disabled: selected === 0 }),
           z.ui.button("Bring forward", () => moveLayer(1), { symbol: "square.2.layers.3d.top.filled", disabled: selected === doc.items.length - 1 })]);
  }
  if (it) group([z.ui.button("Delete mark (⌫)", deleteSelected, { symbol: "delete.left", id: "delete-mark" })]);
  parts.push(z.ui.button("Shadows on marks", () => commit(() => { doc.shadow = !doc.shadow; }),
                         { symbol: "circle.lefthalf.filled", selected: doc.shadow, id: "shadow" }));
  parts.push(z.ui.divider());
  parts.push(z.ui.menu("Backdrop", BACKDROPS.map(b => b.name), doc.backdrop, i => commit(() => { doc.backdrop = i; }),
                       { symbol: "photo.artframe", id: "backdrop" }));
  return z.ui.toolbar(parts);
}

function editorView() {
  if (!info) return z.ui.text("This image isn't available anymore. Close the window and open it again.", { style: "secondary", align: "center" });
  const v = view(), pad = margin(v), ink = tool === "pen";
  return z.ui.column([
    z.ui.band(null, z.ui.logo({ size: 30 }), actions()),
    z.ui.row([
      rail(),
      z.ui.canvas({
        id: "picture",
        fit: { width: v.w + pad * 2, height: v.h + pad * 2 },
        draw: g => drawCanvas(g),
        cursor: tool === "crop" || tool === "select" ? hoverCursor : tool === "text" ? "text" : "crosshair",
        ink: ink ? { color, width: lineWidth(), opacity: 1 } : null,
        textEdit: typing ? { id: typing.id, x: typing.x - v.x + pad, y: typing.y - v.y + pad, text: typing.text,
                             size: typing.index >= 0 ? doc.items[typing.index].size : textSize * u,
                             color: typing.index >= 0 ? doc.items[typing.index].color : color } : null,
        onPointer: pointer,
        onHover: tool === "crop" || tool === "select" ? hover : null,
        onLayout: e => { scale = e.scale; },
        onStroke: penStroke,
        onTextChange: t => { if (typing) typing.text = t; },
        onTextEnd: endTyping,
      }),
    ], { fill: true, spacing: 10 }),
    z.ui.band(infoChip(), tool === "crop" ? cropBar() : styleBar(),
              z.ui.text("Editor inspired by Vorssaint", { style: "caption", id: "credit" })),
  ], { spacing: 8 });
}

zephydian.utility({
  view: panelView,

  window: {
    start(input) {
      img = input && input.image;
      info = img ? z.images.info(img) : null;
      if (!info) return;
      W = info.width; H = info.height;
      u = clamp(Math.max(W, H) / 1000, 1, 8);
      z.window.title(info.name);
      z.window.appearance("dark");
    },

    view: editorView,

    key(e) {
      if (!info) return false;
      if (e.command) {
        if (e.key === "c") { copy(); return true; }
        if (e.key === "s") { e.shift ? saveAs() : save(); return true; }
        return false;
      }
      if (e.key === "Escape" || e.key === "Enter") {
        // Esc drops what's in progress; Esc and Enter finish cropping; Esc lets go of a selection;
        // Enter otherwise copies (like the Copy button).
        if (e.key === "Escape" && (drag || cropDrag || move)) { drag = null; cropDrag = null; move = null; }
        else if (tool === "crop") pickTool("select");
        else if (e.key === "Escape" && selected >= 0) selected = -1;
        else if (e.key === "Enter") copy();
        else return false;
        return true;
      }
      if (e.key === "Backspace") return tool === "select" && deleteSelected();
      const t = TOOLS.find(t => t.key === e.key);
      if (t) { pickTool(t.id); return true; }
      const n = Number(e.key);
      if (n >= 1 && n <= COLORS.length) { setColor(COLORS[n - 1].hex); return true; }
      return false;
    },

    undo() { return restore(undoStack, redoStack); },
    redo() { return restore(redoStack, undoStack); },

    /// Closing asks what to do: save, delete (a screenshot) or don't save (a file), or cancel.
    shouldClose() {
      if (!info || discarded || closing) return true;
      finishTyping();
      if (info.source === "screenshot") {
        z.window.choose({
          title: "Save this screenshot before closing?",
          message: info.saved ? "It's saved as " + info.saved + ". Delete moves that file to the Trash." : "It isn't saved yet.",
          buttons: [{ label: "Save" }, { label: "Delete", destructive: true }],
        }, i => {
          if (i === 0) save(closeAfter);
          if (i === 1) discard();
        });
        return false;
      }
      if (!dirty) return true;
      z.window.choose({
        title: "Save your changes to " + info.name + "?",
        message: "If you don't, they're lost.",
        buttons: [{ label: info.source === "clipboard" ? "Save As…" : "Save" }, { label: "Don't Save", destructive: true }],
      }, i => {
        if (i === 0) save(closeAfter);
        if (i === 1) closeAfter(true);
      });
      return false;
    },
  },
});
