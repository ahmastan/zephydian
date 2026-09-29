// Switch: flip a light and its four neighbours until the whole board is dark.
// Every board is made by flipping a solved (dark) board at random, so it can always be solved,
// and "par" is the number of flips used to make it (the best solution is never longer).

const N = 5;
const LEVELS = [
  { name: "Easy", flips: 4 },
  { name: "Medium", flips: 8 },
  { name: "Hard", flips: 12 },
];
const MAX_UNDO = 100;

let level = 0;       // index into LEVELS
let board = [];      // N*N booleans, true = lit
let moves = 0;
let par = 0;
let history = [];    // cells flipped, for undo
let cursor = 12;     // keyboard focus (starts in the middle)
let solved = false;
let showCursor = false;  // the focus ring appears once the arrow keys are used

// ───────────── Rules ─────────────

function flip(cells, i) {
  const r = Math.floor(i / N), c = i % N;
  for (const [dr, dc] of [[0, 0], [1, 0], [-1, 0], [0, 1], [0, -1]]) {
    const rr = r + dr, cc = c + dc;
    if (rr >= 0 && rr < N && cc >= 0 && cc < N) cells[rr * N + cc] = !cells[rr * N + cc];
  }
}

function newBoard() {
  const flips = LEVELS[level].flips;
  // Pick distinct cells (flipping one twice would cancel out), and never hand out a dark board.
  do {
    board = Array(N * N).fill(false);
    const picked = new Set();
    while (picked.size < flips) picked.add(Math.floor(Math.random() * N * N));
    picked.forEach(i => flip(board, i));
  } while (board.every(on => !on));
  par = flips;
  moves = 0;
  history = [];
  solved = false;
  z.overlay(null);
  update();
}

function press(i) {
  if (solved) return;
  flip(board, i);
  history.push(i);
  if (history.length > MAX_UNDO) history.shift();
  moves++;
  if (board.every(on => !on)) win();
  update();
}

function win() {
  solved = true;
  const stats = z.storage.get("stats") || {};
  const key = LEVELS[level].name;
  const best = stats[key];
  const isBest = best == null || moves < best;
  if (isBest) stats[key] = moves;
  stats.solved = (stats.solved || 0) + 1;
  z.storage.set("stats", stats);
  const underPar = moves <= par ? "At or under par!" : `Par is ${par}.`;
  z.overlay({
    title: isBest && best != null ? "New best!" : "All dark!",
    subtitle: `${moves} ${moves === 1 ? "move" : "moves"}. ${underPar}`,
    buttons: [{ label: "Next board", prominent: true, action: newBoard }],
  });
}

// ───────────── Saving and the header ─────────────

function update() {
  const best = (z.storage.get("stats") || {})[LEVELS[level].name];
  z.score(`${moves} · par ${par}` + (best != null ? ` · best ${best}` : ""));
  z.storage.set("game", { level, board, moves, par, history, cursor, solved });
  z.redraw();
}

function setMenu() {
  z.menu({
    title: "Difficulty",
    items: LEVELS.map(l => `${l.name} (par ${l.flips})`),
    selected: level,
    onSelect(i) {
      level = i;
      z.storage.set("level", level);
      setMenu();
      newBoard();
    },
  });
}

// ───────────── Layout ─────────────

function layout() {
  const size = Math.min(z.width, z.height) - 16;
  const cell = size / N;
  return { cell, x0: (z.width - size) / 2, y0: (z.height - size) / 2 };
}

function cellAt(x, y) {
  const { cell, x0, y0 } = layout();
  const c = Math.floor((x - x0) / cell), r = Math.floor((y - y0) / cell);
  return r >= 0 && r < N && c >= 0 && c < N ? r * N + c : -1;
}

// ───────────── The game ─────────────

zephydian.game({
  start() {
    const saved = z.storage.get("game");
    if (saved && Array.isArray(saved.board) && saved.board.length === N * N) {
      ({ level, board, moves, par, history, cursor, solved } = saved);
      setMenu();
      if (solved) { solved = false; newBoard(); } else update();
    } else {
      level = z.storage.get("level") || 0;
      setMenu();
      newBoard();
    }
  },

  draw(g) {
    const { cell, x0, y0 } = layout();
    const gap = Math.max(4, cell * 0.08), radius = cell * 0.22;
    board.forEach((on, i) => {
      const x = x0 + (i % N) * cell + gap / 2, y = y0 + Math.floor(i / N) * cell + gap / 2, s = cell - gap;
      g.rect(x, y, s, s, { radius, fill: on ? "accent" : "fill" });
      if (on) {
        // A soft highlight, so lit cells glow a little (and differ by more than color alone).
        g.circle(x + s / 2, y + s / 2, s * 0.16, { fill: "rgba(255, 255, 255, 0.55)" });
      }
    });
    if (!showCursor) return;
    // Keyboard focus ring
    const x = x0 + (cursor % N) * cell + gap / 2 - 2, y = y0 + Math.floor(cursor / N) * cell + gap / 2 - 2;
    g.rect(x, y, cell - gap + 4, cell - gap + 4, { radius: radius + 2, stroke: "text", lineWidth: 2 });
  },

  click(e) {
    const i = cellAt(e.x, e.y);
    if (i < 0) return;
    cursor = i;
    showCursor = false;
    press(i);
  },

  key(e) {
    const r = Math.floor(cursor / N), c = cursor % N;
    if (e.key.startsWith("Arrow") || e.key === " ") showCursor = true;
    switch (e.key) {
      case "ArrowUp": cursor = Math.max(r - 1, 0) * N + c; break;
      case "ArrowDown": cursor = Math.min(r + 1, N - 1) * N + c; break;
      case "ArrowLeft": cursor = r * N + Math.max(c - 1, 0); break;
      case "ArrowRight": cursor = r * N + Math.min(c + 1, N - 1); break;
      case " ": press(cursor); return true;
      case "r": newBoard(); return true;
      default: return false;
    }
    z.redraw();
    return true;
  },

  undo() {
    if (solved || history.length === 0) return false;
    const i = history.pop();
    flip(board, i);
    moves = Math.max(0, moves - 1);
    update();
    return true;
  },
});
