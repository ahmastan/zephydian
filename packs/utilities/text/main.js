// Text: counts and quick changes for whatever you paste in. Changes replace the text and can be
// undone with the Undo button; results that aren't text changes (a hash, a UUID) show underneath.

const TABS = ["Case", "Lines", "Developer", "Lorem"];
const LOREM = [
  "Lorem ipsum dolor sit amet, consectetur adipiscing elit.",
  "Sed do eiusmod tempor incididunt ut labore et dolore magna aliqua.",
  "Ut enim ad minim veniam, quis nostrud exercitation ullamco laboris nisi ut aliquip ex ea commodo consequat.",
  "Duis aute irure dolor in reprehenderit in voluptate velit esse cillum dolore eu fugiat nulla pariatur.",
  "Excepteur sint occaecat cupidatat non proident, sunt in culpa qui officia deserunt mollit anim id est laborum.",
  "Curabitur pretium tincidunt lacus, nulla gravida orci a odio.",
  "Nullam varius, turpis et commodo pharetra, est eros bibendum elit, nec luctus magna felis sollicitudin mauris.",
  "Integer in mauris eu nibh euismod gravida.",
  "Duis ac tellus et risus vulputate vehicula.",
  "Donec lobortis risus a elit, etiam tempor.",
];

let text = "";
let tab = 0;
let paragraphs = 2;
let result = null;          // { label, value }
const undoStack = [];

function save() { if (text.length <= 200000) z.storage.set("text", text); }

function set(next) {
  if (next === text) return;
  undoStack.push(text);
  if (undoStack.length > 30) undoStack.shift();
  text = next;
  result = null;
  save();
}

function undo() {
  if (!undoStack.length) return false;
  text = undoStack.pop();
  save();
  return true;
}

// MARK: Counts

function counts() {
  const words = (text.match(/[\p{L}\p{N}][\p{L}\p{N}'’-]*/gu) || []).length;
  const chars = [...text].length;
  const lines = text ? text.split("\n").length : 0;
  const minutes = words / 238;
  const reading = !words ? "0 min" : minutes < 1 ? "under 1 min" : Math.round(minutes) + " min";
  const n = x => x.toLocaleString();
  return [n(words) + (words === 1 ? " word" : " words"), n(chars) + " characters", n(lines) + (lines === 1 ? " line" : " lines"), reading + " read"];
}

// MARK: Case

const wordsOf = s => s
  .replace(/([a-z0-9])([A-Z])/g, "$1 $2")
  .split(/[^\p{L}\p{N}]+/u)
  .filter(Boolean);
const cap = w => w ? w[0].toUpperCase() + w.slice(1).toLowerCase() : w;

const CASES = [
  ["UPPER", s => s.toUpperCase()],
  ["lower", s => s.toLowerCase()],
  ["Title Case", s => s.toLowerCase().replace(/(^|[\s\-(“"'])(\p{L})/gu, (m, a, b) => a + b.toUpperCase())],
  ["Sentence case", s => s.toLowerCase().replace(/(^\s*|[.!?]\s+)(\p{L})/gu, (m, a, b) => a + b.toUpperCase())],
  ["camelCase", s => s.split("\n").map(l => wordsOf(l).map((w, i) => i ? cap(w) : w.toLowerCase()).join("")).join("\n")],
  ["snake_case", s => s.split("\n").map(l => wordsOf(l).map(w => w.toLowerCase()).join("_")).join("\n")],
  ["kebab-case", s => s.split("\n").map(l => wordsOf(l).map(w => w.toLowerCase()).join("-")).join("\n")],
];

// MARK: Lines

const lines = () => text.split("\n");
const LINES = [
  ["Trim spaces", () => lines().map(l => l.trim()).join("\n").trim()],
  ["Sort A–Z", () => lines().sort((a, b) => a.localeCompare(b, undefined, { numeric: true, sensitivity: "base" })).join("\n")],
  ["Sort Z–A", () => lines().sort((a, b) => b.localeCompare(a, undefined, { numeric: true, sensitivity: "base" })).join("\n")],
  ["Remove duplicates", () => [...new Set(lines())].join("\n")],
  ["Reverse", () => lines().reverse().join("\n")],
  ["Remove empty lines", () => lines().filter(l => l.trim()).join("\n")],
];

// MARK: Developer

/// Where a JSON text first goes wrong, as "line 3, column 7" (JavaScriptCore's own message has no position).
function jsonErrorAt(s) {
  let i = 0;
  const fail = () => { throw i; };
  const ws = () => { while (i < s.length && " \t\n\r".includes(s[i])) i++; };
  const lit = w => { if (s.startsWith(w, i)) i += w.length; else fail(); };
  function str() {
    i++;
    while (i < s.length && s[i] !== '"') {
      if (s[i] === "\\") { i++; if (s[i] === "u") { if (!/^[0-9a-fA-F]{4}$/.test(s.substr(i + 1, 4))) fail(); i += 4; } else if (!'"\\/bfnrt'.includes(s[i])) fail(); }
      else if (s.charCodeAt(i) < 0x20) fail();
      i++;
    }
    if (s[i] !== '"') fail();
    i++;
  }
  function num() {
    const m = /^-?(0|[1-9]\d*)(\.\d+)?([eE][+-]?\d+)?/.exec(s.slice(i));
    if (!m) fail();
    i += m[0].length;
  }
  function value() {
    ws();
    const c = s[i];
    if (c === "{") {
      i++; ws();
      if (s[i] === "}") { i++; return; }
      for (;;) { ws(); if (s[i] !== '"') fail(); str(); ws(); if (s[i] !== ":") fail(); i++; value(); ws();
        if (s[i] === ",") { i++; continue; } if (s[i] === "}") { i++; return; } fail(); }
    }
    if (c === "[") {
      i++; ws();
      if (s[i] === "]") { i++; return; }
      for (;;) { value(); ws(); if (s[i] === ",") { i++; continue; } if (s[i] === "]") { i++; return; } fail(); }
    }
    if (c === '"') return str();
    if (c === "t") return lit("true");
    if (c === "f") return lit("false");
    if (c === "n") return lit("null");
    return num();
  }
  try { value(); ws(); if (i < s.length) fail(); return null; } catch (at) {
    if (typeof at !== "number") throw at;
    const before = s.slice(0, at).split("\n");
    return "line " + before.length + ", column " + (before[before.length - 1].length + 1);
  }
}

function json(indent) {
  try {
    set(JSON.stringify(JSON.parse(text), null, indent));
  } catch (e) {
    const where = jsonErrorAt(text);
    z.toast(where ? "Not valid JSON: " + where : "Not valid JSON");
  }
}

function decodeURL() {
  try { set(decodeURIComponent(text.replace(/\+/g, " "))); } catch (e) { z.toast("Not valid URL encoding"); }
}

function decodeBase64() {
  const out = z.text.base64Decode(text);
  if (out == null) z.toast("Not valid Base64 text"); else set(out);
}

const DEVELOPER = [
  ["JSON pretty", () => json(2)],
  ["JSON minify", () => json(0)],
  ["Base64 encode", () => set(z.text.base64Encode(text))],
  ["Base64 decode", decodeBase64],
  ["URL encode", () => set(encodeURIComponent(text))],
  ["URL decode", decodeURL],
  ["SHA-256", () => { result = { label: "SHA-256", value: z.text.sha256(text) }; }],
  ["New UUID", () => { result = { label: "UUID", value: z.random.uuid() }; }],
];

function lorem(n) {
  const out = [];
  for (let p = 0; p < n; p++) {
    const count = 4 + z.random.int(3);
    const sentences = [];
    for (let i = 0; i < count; i++) sentences.push(p === 0 && i === 0 ? LOREM[0] : z.random.pick(LOREM.slice(1)));
    out.push(sentences.join(" "));
  }
  return out.join("\n\n");
}

// MARK: Screen

/// Buttons laid out two per row, so the labels fit.
function grid(items) {
  const rows = [];
  for (let i = 0; i < items.length; i += 2) rows.push(z.ui.row(items.slice(i, i + 2)));
  return z.ui.column(rows, { spacing: 8 });
}

function tools() {
  if (tab === 0) return grid(CASES.map(([label, f]) => z.ui.button(label, () => set(f(text)), { disabled: !text })));
  if (tab === 1) return grid(LINES.map(([label, f]) => z.ui.button(label, () => set(f()), { disabled: !text })));
  if (tab === 2) return grid(DEVELOPER.map(([label, f]) => z.ui.button(label, f, { disabled: !text && label !== "New UUID" })));
  return z.ui.row([
    z.ui.picker("Paragraphs", ["1", "2", "3", "4", "5"], paragraphs - 1, i => { paragraphs = i + 1; }),
    z.ui.button("Insert", () => set(lorem(paragraphs)), { style: "prominent" }),
  ]);
}

zephydian.utility({
  start() { text = z.storage.get("text") || ""; },

  undo,

  view() {
    return z.ui.column([
      z.ui.field({ value: text, placeholder: "Type or paste text", multiline: true, lines: 8, id: "text",
                   onChange: t => { text = t; result = null; save(); } }),
      z.ui.text(counts().join(" · "), { style: "caption" }),
      z.ui.row([
        z.ui.copy(text),
        z.ui.button("Undo", () => { undo(); }, { symbol: "arrow.uturn.backward", disabled: !undoStack.length }),
        z.ui.button("Clear", () => set(""), { disabled: !text }),
      ]),
      z.ui.segmented(TABS, tab, i => { tab = i; }),
      tools(),
      result && z.ui.section(result.label, [
        z.ui.text(result.value, { style: "mono", selectable: true }),
        z.ui.copy(result.value),
      ]),
    ], { spacing: 10 });
  },
});
