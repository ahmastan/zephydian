// Passwords: random passwords and passphrases from the Mac's secure random source (z.random).
// Nothing generated is ever saved, and copies are marked concealed so clipboard histories skip them.

const SETS = {
  upper: "ABCDEFGHIJKLMNOPQRSTUVWXYZ",
  lower: "abcdefghijklmnopqrstuvwxyz",
  digits: "0123456789",
  symbols: "!@#$%^&*()-_=+[]{};:,.?/~",
};
const LOOKALIKES = /[Il1O0o|]/g;
const SEPARATORS = [{ label: "Hyphen", s: "-" }, { label: "Space", s: " " }, { label: "Period", s: "." },
                    { label: "Underscore", s: "_" }, { label: "None", s: "" }];

let prefs = {
  mode: 0,                                                      // 0 password, 1 passphrase
  length: 20, upper: true, lower: true, digits: true, symbols: true, avoid: false,
  words: 5, separator: 0, capitalize: false, number: false,
};
let words = null;       // the word list, loaded the first time a passphrase is made
let current = "";

const save = () => z.storage.set("prefs", prefs);

function chosenSets() {
  return ["upper", "lower", "digits", "symbols"].filter(k => prefs[k])
    .map(k => prefs.avoid ? SETS[k].replace(LOOKALIKES, "") : SETS[k]);
}

function makePassword() {
  const sets = chosenSets();
  if (!sets.length) return "";
  const pool = sets.join("");
  // Draw until every chosen kind of character is in it (almost always the first try).
  for (;;) {
    let out = "";
    for (let i = 0; i < prefs.length; i++) out += pool[z.random.int(pool.length)];
    if (prefs.length < sets.length || sets.every(set => [...out].some(c => set.includes(c)))) return out;
  }
}

function makePassphrase() {
  if (!words) words = z.data("words.txt").split("\n").map(w => w.trim()).filter(Boolean);
  const list = [];
  for (let i = 0; i < prefs.words; i++) {
    const w = z.random.pick(words);
    list.push(prefs.capitalize ? w[0].toUpperCase() + w.slice(1) : w);
  }
  if (prefs.number) {
    const i = z.random.int(list.length);
    list[i] += z.random.int(10);
  }
  return list.join(SEPARATORS[prefs.separator].s);
}

/// Bits of entropy: how many guesses it would take, as a power of two.
function bits() {
  if (prefs.mode === 1) {
    return prefs.words * Math.log2(7776) + (prefs.number ? Math.log2(10 * prefs.words) : 0);
  }
  const pool = chosenSets().join("").length;
  return pool ? prefs.length * Math.log2(pool) : 0;
}

function strength() {
  const b = Math.round(bits());
  const word = b < 40 ? "Weak" : b < 60 ? "Fair" : b < 80 ? "Strong" : "Very strong";
  return word + " · about " + b + " bits";
}

function regenerate() { current = prefs.mode === 1 ? makePassphrase() : makePassword(); }
function change(key, value) { prefs[key] = value; save(); regenerate(); }

function passwordOptions() {
  const count = chosenSets().length;
  const toggle = (label, key) => z.ui.toggle(label, prefs[key], on => {
    if (!on && count === 1 && prefs[key]) { z.toast("Keep at least one kind of character"); return; }
    change(key, on);
  });
  return [
    z.ui.row([
      z.ui.text("Length", { style: "body" }),
      z.ui.slider({ value: prefs.length, min: 8, max: 64, step: 1, onChange: v => change("length", Math.round(v)) }),
      z.ui.text(String(prefs.length), { style: "mono" }),
    ]),
    toggle("Uppercase (A–Z)", "upper"),
    toggle("Lowercase (a–z)", "lower"),
    toggle("Digits (0–9)", "digits"),
    toggle("Symbols (!@#…)", "symbols"),
    z.ui.toggle("Avoid look-alikes (I, l, 1, O, 0)", prefs.avoid, on => change("avoid", on)),
  ];
}

function passphraseOptions() {
  return [
    z.ui.row([
      z.ui.text("Words", { style: "body" }),
      z.ui.slider({ value: prefs.words, min: 3, max: 10, step: 1, onChange: v => change("words", Math.round(v)) }),
      z.ui.text(String(prefs.words), { style: "mono" }),
    ]),
    z.ui.picker("Separator", SEPARATORS.map(s => s.label), prefs.separator, i => change("separator", i)),
    z.ui.toggle("Capitalize words", prefs.capitalize, on => change("capitalize", on)),
    z.ui.toggle("Add a number", prefs.number, on => change("number", on)),
  ];
}

zephydian.utility({
  start() {
    prefs = Object.assign(prefs, z.storage.get("prefs") || {});
    regenerate();
  },

  key(e) {
    if (e.key === "Enter" || e.key === " " || e.key === "r") { regenerate(); return true; }
    return false;
  },

  view() {
    return z.ui.column([
      z.ui.segmented(["Password", "Passphrase"], prefs.mode, i => change("mode", i)),
      z.ui.section(null, [
        z.ui.text(current, { style: "mono", selectable: true, id: "result" }),
        z.ui.text(strength(), { style: "caption" }),
        z.ui.row([
          z.ui.copy(current, { concealed: true }),
          z.ui.button("New", regenerate, { symbol: "arrow.clockwise", style: "prominent" }),
        ]),
      ]),
      z.ui.section("Options", prefs.mode === 1 ? passphraseOptions() : passwordOptions()),
      z.ui.text("Made on this Mac with its secure random generator. Nothing is saved, and copies stay out of clipboard histories.", { style: "caption" }),
    ], { spacing: 12 });
  },
});
