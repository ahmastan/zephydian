// Dictionary: definitions from the New Oxford American Dictionary and synonyms from the Oxford
// American Writer's Thesaurus, the two that come with macOS (z.dictionary reads them offline).
// Look up as you type, click a synonym to follow it, look up the word you copied (a button, or
// the utility's own shortcut), hear it said, and a word of the day.

const TABS = ["Definition", "Synonyms"];
const MAX_RECENT = 12;
const MAX_SENSES = 12;          // synonyms: senses shown before "Show all"
const MAX_WORDS = 40;           // synonyms: words per sense

let query = "";
let tab = 0;
let recent = [];
let trail = [];                 // words left by following a synonym, for Back
let showAll = false;
let remember = null;            // z.after id: keeps a typed word in Recent once typing stops
let words = null;               // the word-of-the-day list
const cache = { define: new Map(), synonyms: new Map() };

// MARK: Lookups

function lookup(kind, word) {
  const key = word.trim().toLowerCase();
  if (!key) return null;
  const store = cache[kind];
  if (!store.has(key)) {
    if (store.size > 60) store.clear();
    store.set(key, kind === "define" ? z.dictionary.define(word.trim()) : z.dictionary.synonyms(word.trim()));
  }
  return store.get(key);
}

const found = r => r && r.found;

function save() { z.storage.set("state", { recent, tab }); }

function keep(word) {
  const w = word.trim();
  if (!w || !found(lookup("define", w))) return;
  recent = [w].concat(recent.filter(r => r.toLowerCase() !== w.toLowerCase())).slice(0, MAX_RECENT);
  save();
}

/// Shows a word: from Recent, a suggestion, a synonym (`follow` keeps a way back) or the clipboard.
function go(word, follow) {
  const w = String(word).trim();
  if (!w) return;
  if (follow && query.trim() && query.trim().toLowerCase() !== w.toLowerCase()) trail = trail.concat([query.trim()]).slice(-20);
  if (!follow) trail = [];
  query = w;
  showAll = false;
  keep(w);
}

function back() {
  const w = trail[trail.length - 1];
  trail = trail.slice(0, -1);
  query = w;
  showAll = false;
}

function typed(t) {
  query = t;
  trail = [];
  showAll = false;
  if (remember) z.cancel(remember);
  remember = z.after(1500, () => { remember = null; keep(query); });
}

/// The first few words of what's on the clipboard, without quotes or punctuation around them.
function fromClipboard() {
  const t = z.clipboard.readText();
  const line = (t || "").split("\n").map(s => s.trim()).find(s => s) || "";
  const word = line.replace(/^[^\p{L}\p{N}]+|[^\p{L}\p{N}]+$/gu, "").split(/\s+/).slice(0, 4).join(" ").slice(0, 60);
  if (!word) { z.toast("Copy a word first"); return; }
  go(word, false);
}

// MARK: Word of the day

function wordOfTheDay() {
  if (!words) words = String(z.data("words.txt") || "").split("\n").map(s => s.trim()).filter(Boolean);
  if (!words.length) return null;
  const now = new Date();
  const day = Math.floor(Date.UTC(now.getFullYear(), now.getMonth(), now.getDate()) / 86400000);
  return words[day % words.length];
}

function firstSense(r) {
  const entry = r.entries && r.entries[0];
  const group = entry && entry.groups.find(g => g.senses.length);
  return group ? { pos: group.pos, text: group.senses[0].text } : null;
}

// MARK: Pieces

function speakButton(word) {
  return z.ui.button("Say “" + word + "”", () => z.dictionary.speak(word), { symbol: "speaker.wave.2", style: "icon" });
}

function heading(word, detail) {
  return z.ui.column([
    z.ui.row([
      z.ui.text(word, { style: "display", selectable: true }),
      speakButton(word),
      z.ui.spacer(),
      z.ui.copy(word, { label: "Copy" }),
    ], { spacing: 10 }),
    detail ? z.ui.text(detail, { style: "secondary" }) : null,
  ], { spacing: 2 });
}

function redirect(entry) {
  const q = query.trim();
  return entry.headword.toLowerCase() !== q.toLowerCase()
    ? z.ui.text("Showing “" + entry.headword + "” for “" + q + "”.", { style: "caption" }) : null;
}

function suggestions(r) {
  const list = (r && r.suggestions) || [];
  return z.ui.column([
    z.ui.text("No entry for “" + query.trim() + "”.", { style: "body" }),
    list.length ? z.ui.text("Did you mean", { style: "caption" }) : null,
    list.length ? z.ui.flow(list.map(w => z.ui.button(w, () => go(w, false), { style: "chip", id: "sug-" + w }))) : null,
  ], { spacing: 8 });
}

function unavailable(what) {
  return z.ui.section(null, [
    z.ui.text("The " + what + " isn't on this Mac yet.", { style: "body" }),
    z.ui.text("Open the Dictionary app, choose Settings, and turn on " +
              (what === "thesaurus" ? "Oxford American Writer's Thesaurus" : "New Oxford American Dictionary") +
              ". macOS downloads it, then it works here too.", { style: "caption" }),
    z.ui.button("Open Dictionary", () => z.dictionary.open(query.trim() || "dictionary"), { symbol: "book" }),
  ]);
}

// MARK: Definition

function sense(s, number) {
  return z.ui.column([
    s.label ? z.ui.text(s.label, { style: "caption", italic: true }) : null,
    z.ui.text((number ? number + ". " : "• ") + s.text, { style: "body", selectable: true }),
    ...s.examples.slice(0, 2).map(e => z.ui.text("“" + e + "”", { style: "secondary", italic: true, selectable: true })),
  ], { spacing: 3 });
}

function definitionEntry(entry, i) {
  const detail = [entry.syllables, entry.pronunciation ? "| " + entry.pronunciation + " |" : null].filter(Boolean).join("  ");
  const parts = [i === 0 ? heading(entry.headword, detail) : z.ui.text(entry.headword + (detail ? "   " + detail : ""), { style: "title" })];
  for (const group of entry.groups) {
    if (!group.senses.length) continue;
    parts.push(z.ui.section(group.pos + (group.forms ? " · " + group.forms : ""), group.senses.map((s, n) =>
      z.ui.column([sense(s, group.senses.length > 1 ? n + 1 : 0), ...(s.subsenses || []).map(sub => sense(sub, 0))], { spacing: 6 }))));
  }
  if (entry.phrases.length) {
    parts.push(z.ui.disclosure("Phrases (" + entry.phrases.length + ")", !!z.storage.get("open.phrases"),
      on => z.storage.set("open.phrases", on),
      entry.phrases.map(p => z.ui.column([
        z.ui.text(p.phrase, { style: "title" }),
        ...p.senses.slice(0, 3).map(s => sense(s, 0)),
      ], { spacing: 3 })), { id: "phrases-" + i }));
  }
  if (entry.derivatives.length) {
    parts.push(z.ui.text("Also: " + entry.derivatives.map(d => d.word + (d.pos ? " (" + d.pos + ")" : "")).join(", "),
                         { style: "caption", selectable: true }));
  }
  if (entry.origin) {
    parts.push(z.ui.disclosure("Origin", !!z.storage.get("open.origin"), on => z.storage.set("open.origin", on),
      [z.ui.text(entry.origin, { style: "secondary", selectable: true })], { id: "origin-" + i }));
  }
  return z.ui.column(parts, { spacing: 10 });
}

function definition() {
  const r = lookup("define", query);
  if (!r) return null;
  if (r.available === false) return unavailable("dictionary");
  if (!r.found) return suggestions(r);
  if (r.plain) return z.ui.column([heading(query.trim()), z.ui.text(r.plain, { selectable: true })], { spacing: 10 });
  return z.ui.column([
    redirect(r.entries[0]),
    ...r.entries.map(definitionEntry),
    z.ui.button("Open in Dictionary", () => z.dictionary.open(query.trim()), { symbol: "book" }),
  ], { spacing: 14 });
}

// MARK: Synonyms

function chips(list, id) {
  return z.ui.flow(list.slice(0, MAX_WORDS).map((w, i) => {
    const word = typeof w === "string" ? w : w.word;
    return z.ui.button(word, () => go(word, true), { style: "chip", selected: !!w.core, id: id + "-" + i });
  }));
}

function synonyms() {
  const r = lookup("synonyms", query);
  if (!r) return null;
  if (r.available === false) return unavailable("thesaurus");
  if (!r.found) {
    return found(lookup("define", query))
      ? z.ui.text("The thesaurus has no synonyms for “" + query.trim() + "”.", { style: "body" })
      : suggestions(r);
  }
  const entry = r.entries[0];
  const parts = [redirect(entry), heading(entry.headword)];
  let shown = 0, total = 0;
  r.entries.forEach((e, ei) => e.groups.forEach((group, gi) => group.senses.forEach((s, si) => {
    total++;
    if (!showAll && shown >= MAX_SENSES) return;
    shown++;
    const id = ei + "." + gi + "." + si;
    parts.push(z.ui.section(si === 0 ? group.pos : null, [
      s.example ? z.ui.text("“" + s.example + "”", { style: "secondary", italic: true }) : null,
      chips(s.synonyms, "syn-" + id),
      ...s.labeled.map((l, li) => z.ui.column([z.ui.text(l.label, { style: "caption", italic: true }), chips(l.words, "lab-" + id + "-" + li)], { spacing: 4 })),
      s.antonyms.length ? z.ui.column([z.ui.text("Opposites", { style: "caption" }), chips(s.antonyms, "ant-" + id)], { spacing: 4 }) : null,
    ]));
  })));
  if (total > shown) parts.push(z.ui.button("Show all " + total + " meanings", () => { showAll = true; }, { symbol: "chevron.down" }));
  parts.push(z.ui.text("Click a word to look it up. The first words of each meaning are the closest.", { style: "caption" }));
  return z.ui.column(parts, { spacing: 10 });
}

// MARK: Home (nothing typed)

function home() {
  const parts = [];
  const w = wordOfTheDay();
  const r = w && lookup("define", w);
  if (found(r) && r.entries) {
    const first = firstSense(r), entry = r.entries[0];
    parts.push(z.ui.section("Word of the day", [
      z.ui.row([z.ui.text(entry.headword, { style: "display" }), speakButton(entry.headword), z.ui.spacer()], { spacing: 10 }),
      entry.pronunciation ? z.ui.text("| " + entry.pronunciation + " |", { style: "secondary" }) : null,
      first ? z.ui.text(first.pos, { style: "caption", italic: true }) : null,
      first ? z.ui.text(first.text, { style: "body" }) : null,
      z.ui.button("Look up", () => go(entry.headword, false), { symbol: "arrow.right" }),
    ]));
  } else if (r && r.available === false) {
    parts.push(unavailable("dictionary"));
  }
  parts.push(z.ui.section("Recent", [
    z.ui.list(recent.map(word => ({ id: word, title: word, symbol: "clock", actions: [{ symbol: "xmark", label: "Remove" }] })), {
      empty: "Words you look up appear here.",
      onSelect: word => go(word, false),
      onAction: word => { recent = recent.filter(x => x !== word); save(); },
    }),
    recent.length ? z.ui.button("Clear", () => { recent = []; save(); }, { symbol: "trash" }) : null,
  ]));
  return z.ui.column(parts, { spacing: 12 });
}

// Dictionary's page in Zephydian's Settings window.
function settings() {
  return z.ui.section(null, [
    z.ui.shortcut("Shortcut"),
    z.ui.text("From any app: copy a word, press the shortcut, and Dictionary opens on it.", { style: "caption" }),
  ]);
}

zephydian.utility({
  start() {
    const s = z.storage.get("state") || {};
    recent = Array.isArray(s.recent) ? s.recent.filter(w => typeof w === "string").slice(0, MAX_RECENT) : [];
    tab = s.tab === 1 ? 1 : 0;
  },

  // Opened with its shortcut: look up what's on the clipboard.
  shortcut() { fromClipboard(); },

  view() {
    const hasQuery = !!query.trim();
    return z.ui.column([
      z.ui.row([
        trail.length ? z.ui.button("Back to “" + trail[trail.length - 1] + "”", back, { symbol: "chevron.left", style: "icon" }) : null,
        z.ui.field({ value: query, placeholder: "Look up a word", id: "search", onChange: typed,
                     onSubmit: t => { if (remember) { z.cancel(remember); remember = null; } keep(t); } }),
        z.ui.button("Look up copied word", fromClipboard, { symbol: "doc.on.clipboard", style: "icon" }),
      ], { spacing: 8 }),
      hasQuery ? z.ui.segmented(TABS, tab, i => { tab = i; showAll = false; save(); }) : null,
      hasQuery ? (tab === 0 ? definition() : synonyms()) : home(),
    ], { spacing: 12 });
  },

  settings: { view: settings },
});
