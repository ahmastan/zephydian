// Calculator: type whole expressions ("12*(3+4)/2", "sqrt 2", "15% * 80") or unit conversions
// ("5 km in mi", "72 f to c"). The answer updates as you type; Enter keeps it in the history.

// MARK: Units (factor to the dimension's base unit)

// The first name is how the answer shows the unit; any name works when typing, in any case.
const UNITS = {};
function units(dim, list) {
  for (const [names, factor] of list) {
    const all = names.split(" ");
    for (const n of all) UNITS[n.toLowerCase()] = { dim, factor, name: all[0] };
  }
}
units("length", [
  ["mm millimeter millimeters millimetre millimetres", 0.001], ["cm centimeter centimeters centimetre centimetres", 0.01],
  ["m meter meters metre metres", 1], ["km kilometer kilometers kilometre kilometres", 1000],
  ["in inch inches", 0.0254], ["ft foot feet", 0.3048], ["yd yard yards", 0.9144],
  ["mi mile miles", 1609.344], ["nmi nautical", 1852],
]);
units("weight", [
  ["mg milligram milligrams", 1e-6], ["g gram grams", 0.001], ["kg kilogram kilograms kilo kilos", 1],
  ["t tonne tonnes", 1000], ["oz ounce ounces", 0.028349523125], ["lb lbs pound pounds", 0.45359237],
  ["st stone stones", 6.35029318],
]);
units("volume", [
  ["ml milliliter milliliters millilitre millilitres", 0.001], ["cl centiliter centiliters", 0.01],
  ["dl deciliter deciliters", 0.1], ["L liter liters litre litres", 1], ["m3", 1000],
  ["tsp teaspoon teaspoons", 0.00492892159375], ["tbsp tablespoon tablespoons", 0.01478676478125],
  ["floz", 0.0295735295625], ["cup cups", 0.2365882365], ["pt pint pints", 0.473176473],
  ["qt quart quarts", 0.946352946], ["gal gallon gallons", 3.785411784],
]);
units("area", [
  ["mm2", 1e-6], ["cm2", 1e-4], ["m2", 1], ["km2", 1e6], ["ha hectare hectares", 1e4],
  ["in2", 0.00064516], ["ft2", 0.09290304], ["yd2", 0.83612736], ["acre acres", 4046.8564224], ["mi2", 2589988.110336],
]);
units("speed", [
  ["m/s mps", 1], ["km/h kmh kph", 1 / 3.6], ["mph", 0.44704], ["knot knots kn", 1852 / 3600], ["ft/s fps", 0.3048],
]);
units("time", [
  ["ms millisecond milliseconds", 0.001], ["s sec secs second seconds", 1], ["min mins minute minutes", 60],
  ["h hr hrs hour hours", 3600], ["day days d", 86400], ["week weeks wk", 604800], ["year years yr", 31557600],
]);
units("data", [
  ["bit bits", 0.125], ["B byte bytes", 1], ["KB kilobyte kilobytes", 1e3], ["MB megabyte megabytes", 1e6],
  ["GB gigabyte gigabytes", 1e9], ["TB terabyte terabytes", 1e12],
  ["KiB", 1024], ["MiB", 1024 ** 2], ["GiB", 1024 ** 3], ["TiB", 1024 ** 4],
]);
const TEMPS = { c: "c", "°c": "c", celsius: "c", f: "f", "°f": "f", fahrenheit: "f", k: "k", kelvin: "k" };

function unitOf(raw) {
  const u = raw.toLowerCase().replace("²", "2").replace("³", "3");
  if (TEMPS[u]) return { dim: "temperature", temp: TEMPS[u], name: TEMPS[u] === "k" ? " K" : " °" + TEMPS[u].toUpperCase() };
  return UNITS[u] || null;
}

function convert(value, from, to) {
  if (from.dim !== to.dim) throw new Error("can't turn " + from.dim + " into " + to.dim);
  if (from.dim !== "temperature") return value * from.factor / to.factor;
  const k = from.temp === "c" ? value + 273.15 : from.temp === "f" ? (value - 32) * 5 / 9 + 273.15 : value;
  return to.temp === "c" ? k - 273.15 : to.temp === "f" ? (k - 273.15) * 9 / 5 + 32 : k;
}

// MARK: Expressions

const CONSTANTS = { pi: Math.PI, "π": Math.PI, e: Math.E, tau: 2 * Math.PI };
let degrees = false;
const toRad = x => degrees ? x * Math.PI / 180 : x;
const fromRad = x => degrees ? x * 180 / Math.PI : x;
const FUNCTIONS = {
  sqrt: Math.sqrt, "√": Math.sqrt, cbrt: Math.cbrt, abs: Math.abs, round: Math.round, floor: Math.floor, ceil: Math.ceil,
  ln: Math.log, log: Math.log10, log2: Math.log2, exp: Math.exp,
  sin: x => Math.sin(toRad(x)), cos: x => Math.cos(toRad(x)), tan: x => Math.tan(toRad(x)),
  asin: x => fromRad(Math.asin(x)), acos: x => fromRad(Math.acos(x)), atan: x => fromRad(Math.atan(x)),
};

function tokenize(s) {
  const tokens = [];
  const re = /\s*(?:(\d[\d_]*(?:\.\d*)?(?:[eE][+-]?\d+)?|\.\d+(?:[eE][+-]?\d+)?)|([a-zA-Z][a-zA-Z0-9]*|π|√)|(\*\*|[-+*/×÷^%!()]))/y;
  let m, at = 0;
  while (at < s.length) {
    re.lastIndex = at;
    if (/^\s*$/.test(s.slice(at))) break;
    m = re.exec(s);
    if (!m) throw new Error("I don't understand \"" + s.slice(at).trim().slice(0, 12) + "\"");
    at = re.lastIndex;
    if (m[1] !== undefined) tokens.push({ t: "num", v: parseFloat(m[1].replace(/_/g, "")) });
    else if (m[2] !== undefined) tokens.push({ t: "id", v: m[2].toLowerCase() });
    else tokens.push({ t: "op", v: { "**": "^", "×": "*", "÷": "/" }[m[3]] || m[3] });
  }
  return tokens;
}

function evaluate(s, ans) {
  const tokens = tokenize(s);
  if (!tokens.length) throw new Error("empty");
  let i = 0;
  const peek = () => tokens[i];
  const isOp = v => peek() && peek().t === "op" && peek().v === v;
  const startsValue = () => peek() && (peek().t === "num" || peek().t === "id" || isOp("("));

  function expr() {
    let v = term();
    while (isOp("+") || isOp("-")) v = tokens[i++].v === "+" ? v + term() : v - term();
    return v;
  }
  function term() {
    let v = unary();
    for (;;) {
      if (isOp("*")) { i++; v *= unary(); }
      else if (isOp("/")) { i++; v /= unary(); }
      else if (startsValue()) v *= unary();       // 2pi, 3(4+1)
      else return v;
    }
  }
  function unary() {
    if (isOp("-")) { i++; return -unary(); }
    if (isOp("+")) { i++; return unary(); }
    return power();
  }
  function power() {
    const base = postfix();
    if (isOp("^")) { i++; return Math.pow(base, unary()); }
    return base;
  }
  function postfix() {
    let v = primary();
    for (;;) {
      if (isOp("%")) { i++; v /= 100; }
      else if (isOp("!")) {
        i++;
        if (v < 0 || v > 170 || v !== Math.floor(v)) throw new Error("! needs a whole number from 0 to 170");
        let f = 1; for (let k = 2; k <= v; k++) f *= k; v = f;
      } else return v;
    }
  }
  function primary() {
    const tok = tokens[i++];
    if (!tok) throw new Error("unfinished");
    if (tok.t === "num") return tok.v;
    if (tok.t === "op" && tok.v === "(") {
      const v = expr();
      if (!isOp(")")) throw new Error("missing )");
      i++;
      return v;
    }
    if (tok.t === "id") {
      if (tok.v === "ans") return ans;
      if (tok.v in CONSTANTS) return CONSTANTS[tok.v];
      if (tok.v in FUNCTIONS) return FUNCTIONS[tok.v](isOp("(") ? primary() : unary());
      throw new Error("unknown name \"" + tok.v + "\"");
    }
    throw new Error("unexpected " + tok.v);
  }

  const v = expr();
  if (i < tokens.length) throw new Error("unexpected " + tokens[i].v);
  return v;
}

/// { value, unit } or throws. Handles "<expression> <unit> in|to|as <unit>".
function calculate(input, ans) {
  const m = /^(.+?)\s*([a-zA-Z°µ²³][a-zA-Z0-9°µ²³/]*)\s+(?:in|to|as)\s+([a-zA-Z°µ²³][a-zA-Z0-9°µ²³/]*)\s*$/.exec(input.trim());
  if (m) {
    const from = unitOf(m[2]), to = unitOf(m[3]);
    if (from && to) return { value: convert(evaluate(m[1], ans), from, to), unit: to.dim === "temperature" ? to.name : " " + to.name };
  }
  return { value: evaluate(input, ans), unit: "" };
}

function format(x) {
  if (Number.isNaN(x)) return "Not a number";
  if (!Number.isFinite(x)) return x > 0 ? "∞" : "−∞";
  const a = Math.abs(x);
  if (a !== 0 && (a >= 1e15 || a < 1e-9)) return x.toPrecision(10).replace(/\.?0+e/, "e");
  return x.toLocaleString("en-US", { maximumSignificantDigits: 12 });
}

// MARK: State and screen

let input = "";
let history = [];           // [{ id, input, value, unit }], newest first
let nextID = 1;
let lastAnswer = 0;

function current() {
  if (!input.trim()) return null;
  try { return calculate(input, lastAnswer); } catch (e) { return { error: e.message }; }
}

function save() { z.storage.set("state", { history: history.slice(0, 50), degrees, lastAnswer }); }

function commit() {
  const r = current();
  if (!r || r.error || !Number.isFinite(r.value)) return;
  history.unshift({ id: "h" + nextID++, input: input.trim(), value: r.value, unit: r.unit });
  history = history.slice(0, 50);
  lastAnswer = r.value;
  input = "";
  save();
}

function setMenu() {
  z.menu({ title: "Angles", items: ["Radians", "Degrees"], selected: degrees ? 1 : 0,
           onSelect: i => { degrees = i === 1; save(); } });
}

zephydian.utility({
  start() {
    const s = z.storage.get("state");
    if (s) {
      history = (s.history || []).map(h => Object.assign({}, h, { id: "h" + nextID++ }));
      degrees = !!s.degrees;
      lastAnswer = s.lastAnswer || 0;
    }
    setMenu();
  },

  view() {
    const r = current();
    const answer = !r ? " " : r.error ? "…" : "= " + format(r.value) + r.unit;
    return z.ui.column([
      z.ui.field({ value: input, placeholder: "12 × (3 + 4), sqrt 2, 5 km in mi", mono: true, id: "input",
                   onChange: t => { input = t; }, onSubmit: commit }),
      z.ui.text(answer, { style: "large", align: "right", selectable: true, id: "answer" }),
      r && r.error && input.trim().length > 1 ? z.ui.text(r.error, { style: "caption", align: "right" }) : null,
      z.ui.row([
        r && !r.error ? z.ui.copy(format(r.value).replace(/,/g, "") ) : null,
        z.ui.spacer(),
        z.ui.button("Clear history", () => { history = []; save(); }, { disabled: !history.length }),
      ]),
      z.ui.list(history.map(h => ({ id: h.id, title: h.input, detail: format(h.value) + h.unit })), {
        empty: "Press Enter to keep an answer here. Click one to use it again.",
        onSelect: id => {
          const h = history.find(x => x.id === id);
          if (h) { input = String(Number(h.value.toPrecision(12))); lastAnswer = h.value; }
        },
      }),
    ], { spacing: 10 });
  },
});
