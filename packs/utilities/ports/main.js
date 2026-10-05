// Ports: what's listening for connections on this Mac (a dev server on :3000, a database on
// :5432…), with the app behind it. Stop asks it to quit; Force Stop ends it. Only your own
// processes can be stopped; macOS's are listed but left alone.

let ports = null;
let filter = "";
let note = null;
let stopping = {};        // pid → true after Stop, offering Force Stop

function load() { z.ports.list(list => { ports = Array.isArray(list) ? list : []; }); }

zephydian.utility({
  start() { load(); z.loop.start(3000); },
  resume() { load(); },
  tick() { load(); },
  view() {
    if (!ports) return z.ui.text("Looking…", { style: "secondary" });
    const q = filter.trim().toLowerCase();
    const shown = ports.filter(p => !q || String(p.port).includes(q) || p.name.toLowerCase().includes(q));
    return z.ui.column([
      z.ui.field({ value: filter, placeholder: "Filter by port or app", onChange: t => { filter = t; }, id: "filter" }),
      note ? z.ui.text(note, { style: "caption", id: "note" }) : null,
      z.ui.list(shown.map(p => ({
        id: String(p.pid) + ":" + p.port,
        title: ":" + p.port + "  " + p.name,
        subtitle: "Process " + p.pid + " · " + p.address,
        image: p.app ? "app:" + p.app : undefined,
        symbol: p.app ? undefined : "terminal",
        actions: p.canStop ? [{ symbol: stopping[p.pid] ? "xmark.octagon.fill" : "stop.circle", label: stopping[p.pid] ? "Force Stop" : "Stop" }] : [],
      })), {
        empty: q ? "Nothing matches." : "Nothing is listening.",
        onAction: id => {
          const p = shown.find(x => String(x.pid) + ":" + x.port === id);
          if (!p) return;
          const force = !!stopping[p.pid];
          const ok = z.ports.stop(p.pid, force);
          note = ok ? (force ? "Ended " : "Asked to quit: ") + p.name + (force ? "." : ". If it's still listening, click again to force it.") : "Couldn't stop " + p.name + ".";
          stopping[p.pid] = true;
          z.after(800, load);
        },
      }),
      z.ui.text("Updates every 3 seconds while open. macOS's own services can't be stopped from here.", { style: "caption" }),
    ], { spacing: 10 });
  },
});
