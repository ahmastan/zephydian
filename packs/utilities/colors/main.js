// Colors: pick a color anywhere on screen with macOS's color loupe (z.color.sample), or type one,
// then copy it in the format you need. Keeps your last 12 picks and a saved palette.

let color = { r: 0, g: 122, b: 255 };
let recent = [];        // hex strings, newest first
let saved = [];
let typed = "";

const hex2 = n => n.toString(16).padStart(2, "0");
const toHex = c => "#" + hex2(c.r) + hex2(c.g) + hex2(c.b);
const clamp = n => Math.min(255, Math.max(0, Math.round(n)));

function fromHex(h) {
  let s = h.trim().replace(/^#/, "");
  if (/^[0-9a-f]{3}$/i.test(s)) s = s.replace(/./g, "$&$&");
  if (!/^[0-9a-f]{6}$/i.test(s)) return null;
  const v = parseInt(s, 16);
  return { r: v >> 16 & 255, g: v >> 8 & 255, b: v & 255 };
}

function toHSL({ r, g, b }) {
  r /= 255; g /= 255; b /= 255;
  const max = Math.max(r, g, b), min = Math.min(r, g, b), l = (max + min) / 2;
  let h = 0, s = 0;
  if (max !== min) {
    const d = max - min;
    s = l > 0.5 ? d / (2 - max - min) : d / (max + min);
    h = max === r ? (g - b) / d + (g < b ? 6 : 0) : max === g ? (b - r) / d + 2 : (r - g) / d + 4;
    h *= 60;
  }
  return { h: Math.round(h) % 360, s: Math.round(s * 100), l: Math.round(l * 100) };
}

function fromHSL(h, s, l) {
  s /= 100; l /= 100;
  const k = n => (n + h / 30) % 12, a = s * Math.min(l, 1 - l);
  const f = n => l - a * Math.max(-1, Math.min(k(n) - 3, Math.min(9 - k(n), 1)));
  return { r: clamp(f(0) * 255), g: clamp(f(8) * 255), b: clamp(f(4) * 255) };
}

/// "#f90", "#ff9900", "ff9900", "rgb(255, 153, 0)", "255 153 0" or "hsl(36, 100%, 50%)".
function parse(input) {
  const s = input.trim().toLowerCase();
  const hex = fromHex(s);
  if (hex) return hex;
  let m = /^hsla?\(\s*([\d.]+)\s*[, ]\s*([\d.]+)%\s*[, ]\s*([\d.]+)%/.exec(s);
  if (m) return fromHSL(+m[1] % 360, Math.min(100, +m[2]), Math.min(100, +m[3]));
  m = /^(?:rgba?\()?\s*([\d.]+)\s*[, ]\s*([\d.]+)\s*[, ]\s*([\d.]+)/.exec(s);
  if (m && [m[1], m[2], m[3]].every(v => +v <= 255)) return { r: clamp(+m[1]), g: clamp(+m[2]), b: clamp(+m[3]) };
  return null;
}

function formats(c) {
  const { h, s, l } = toHSL(c), f = n => (n / 255).toFixed(3);
  return [
    ["HEX", toHex(c).toUpperCase()],
    ["RGB", "rgb(" + c.r + ", " + c.g + ", " + c.b + ")"],
    ["HSL", "hsl(" + h + ", " + s + "%, " + l + "%)"],
    ["CSS", "color: " + toHex(c) + ";"],
    ["SwiftUI", "Color(red: " + f(c.r) + ", green: " + f(c.g) + ", blue: " + f(c.b) + ")"],
  ];
}

function save() {
  z.storage.set("state", { color: toHex(color), recent, saved });
  z.tile(toHex(color).toUpperCase());
}

function choose(c, remember) {
  color = c;
  const h = toHex(c);
  if (remember) recent = [h, ...recent.filter(x => x !== h)].slice(0, 12);
  save();
}

function pick() {
  z.color.sample(c => { if (c) choose({ r: c.r, g: c.g, b: c.b }, true); });
}

/// Rows of 12 small swatches; clicking one makes it the current color.
function swatches(list) {
  const rows = [];
  for (let i = 0; i < list.length; i += 12) {
    rows.push(z.ui.row(list.slice(i, i + 12).map(h => z.ui.swatch(h, {
      size: 22, selected: h === toHex(color), accessibilityLabel: h.toUpperCase(), id: "sw" + i + h,
      onPress: () => choose(fromHex(h), false),
    })), { spacing: 6 }));
  }
  return rows;
}

zephydian.utility({
  start() {
    const s = z.storage.get("state");
    if (s) {
      color = fromHex(s.color || "") || color;
      recent = s.recent || [];
      saved = s.saved || [];
    }
  },

  key(e) {
    if (e.key === "p") { pick(); return true; }
    return false;
  },

  view() {
    const h = toHex(color), isSaved = saved.includes(h);
    return z.ui.column([
      z.ui.row([
        z.ui.swatch(h, { size: 56 }),
        z.ui.column([
          z.ui.text(h.toUpperCase(), { style: "title", selectable: true }),
          z.ui.row([
            z.ui.button("Pick from screen", pick, { symbol: "eyedropper", style: "prominent" }),
            z.ui.button(isSaved ? "Unsave" : "Save", () => {
              saved = isSaved ? saved.filter(x => x !== h) : [h, ...saved].slice(0, 24);
              save();
            }, { symbol: isSaved ? "pin.slash" : "pin" }),
          ]),
        ], { spacing: 6 }),
      ], { spacing: 12 }),
      z.ui.field({ value: typed, placeholder: "Or type #FF9500, rgb(255, 149, 0)…", mono: true, id: "typed",
                   onChange: t => { typed = t; const c = parse(t); if (c) choose(c, false); },
                   onSubmit: t => { const c = parse(t); if (c) { choose(c, true); typed = ""; } else z.toast("That isn't a color I know"); } }),
      z.ui.section(null, formats(color).map(([name, value]) => z.ui.row([
        z.ui.column([
          z.ui.text(name, { style: "caption" }),
          z.ui.text(value, { style: "mono", selectable: true }),
        ], { spacing: 2 }),
        z.ui.spacer(),
        z.ui.copy(value),
      ]))),
      recent.length ? z.ui.section("Recent", swatches(recent)) : null,
      saved.length ? z.ui.section("Saved", swatches(saved)) : null,
    ], { spacing: 12 });
  },
});
