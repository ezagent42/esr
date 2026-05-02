// PR-24: ESR attach page — raw binary WebSocket + xterm.js, no
// Phoenix.Channel.
//
// PR-23 routed PTY bytes through Phoenix.Channel with JSON serialisation,
// which mangled ANSI ESC sequences and any byte 0x80-0xff. Result was
// garbled xterm.js render plus claude blocking on unanswered terminal-
// capability queries (DA1 / XTVERSION) because xterm.js's auto-replies
// could never make it back as valid bytes.
//
// PR-24 mirrors ttyd's approach:
//   - WebSocket with binaryType='arraybuffer'
//   - server → client: binary frames carry raw PTY stdout, fed straight
//     into terminal.write(uint8) — xterm.js handles UTF-8 decode
//     internally and auto-answers terminal-cap queries via stdin
//   - client → server, binary: stdin keystrokes (and xterm.js's
//     terminal-cap replies) as raw bytes
//   - client → server, text: JSON `{"cols": N, "rows": N}` for resize
import { Terminal } from "xterm";
import { FitAddon } from "xterm-addon-fit";
import "xterm/css/xterm.css";

const sid = window.ESR_SID;
if (!sid) {
  throw new Error("ESR_SID not set; AttachController must inject it");
}

const theme = {
  background: "#1e1e1e",
  foreground: "#d4d4d4",
  cursor: "#d4d4d4",
  black: "#000000",
  red: "#cd3131",
  green: "#0dbc79",
  yellow: "#e5e510",
  blue: "#2472c8",
  magenta: "#bc3fbc",
  cyan: "#11a8cd",
  white: "#e5e5e5",
  brightBlack: "#666666",
  brightRed: "#f14c4c",
  brightGreen: "#23d18b",
  brightYellow: "#f5f543",
  brightBlue: "#3b8eea",
  brightMagenta: "#d670d6",
  brightCyan: "#29b8db",
  brightWhite: "#e5e5e5",
};

const term = new Terminal({
  cursorBlink: true,
  cursorStyle: "block",
  // Match ttyd's stack — guarantees a system mono on every OS without a
  // web-font load race that can throw off fitAddon's first measurement.
  fontFamily: 'Consolas, "Liberation Mono", Menlo, Courier, monospace',
  fontSize: 13,
  lineHeight: 1.2,
  scrollback: 5000,
  // Don't translate \n → \r\n; PTY emits \r\n natively.
  convertEol: false,
  allowProposedApi: true,
  theme,
});

const fitAddon = new FitAddon();
term.loadAddon(fitAddon);
const termContainer = document.getElementById("term");

// Defer term.open until the layout has actually been computed. With
// `defer` script + inline CSS the layout is supposed to be done before
// our script runs, but xterm.js in some Chrome versions still measures
// the parent at intrinsic content width (=0 for an empty div), pinning
// the renderer to default 80×24. A double-rAF gives layout one frame
// to settle and is what other xterm.js consumers do (microsoft/vscode-
// remote-tunnel uses the same trick).
function openTerminal() {
  term.open(termContainer);
  fitAddon.fit();
  // Diagnostic: surface measured dims into the DOM so headless
  // dump-dom can verify the container actually got viewport size.
  termContainer.dataset.openedCols = term.cols;
  termContainer.dataset.openedRows = term.rows;
  termContainer.dataset.openedWidth = termContainer.clientWidth;
  termContainer.dataset.openedHeight = termContainer.clientHeight;
}

requestAnimationFrame(() => requestAnimationFrame(openTerminal));

// Two distinct concerns, kept distinct:
//   1. PAGE RESIZE (cols/rows recalc) → fitAddon.fit()
//   2. TUI RESIZE (SIGWINCH to server) → term.onResize (below)
function safeFit() {
  try { fitAddon.fit(); } catch (_) { /* container not measurable yet */ }
}

if (typeof ResizeObserver !== "undefined") {
  const ro = new ResizeObserver(() => safeFit());
  ro.observe(termContainer);
}
window.addEventListener("resize", () => safeFit());

// Coalesce the "send current size to server" path. Two callsites need
// it: (a) term.onResize (cols/rows changed locally), (b) ws.open (we
// just connected and the server has no idea what viewport we're at —
// it's still on the boot bridge's 120×40 default).
let lastSentCols = 0;
let lastSentRows = 0;
function sendCurrentSize() {
  const cols = term.cols, rows = term.rows;
  if (cols <= 0 || rows <= 0) return;
  if (ws.readyState !== WebSocket.OPEN) return;
  if (cols === lastSentCols && rows === lastSentRows) return;
  ws.send(JSON.stringify({ cols, rows }));
  lastSentCols = cols;
  lastSentRows = rows;
}

term.onResize(() => sendCurrentSize());

// Custom keys that the browser would otherwise eat (tab focus moves,
// page scroll on space, etc.). We keep them inside the terminal so
// claude TUI behaves normally — including Shift+Tab for mode switch
// (claude binds it as the bypass-permissions / accept-edits cycle).
//
// Returning false tells xterm.js "I handled it; don't propagate" —
// so xterm.js still emits the right escape sequence to the PTY but
// the browser's default keydown action is blocked.
term.attachCustomKeyEventHandler((e) => {
  if (e.type !== "keydown") return true;

  // Tab + Shift+Tab: claude's mode toggle. preventDefault on browser
  // focus traversal; xterm.js will translate to "\t" / "\e[Z".
  if (e.key === "Tab") {
    e.preventDefault();
    return true;
  }

  return true;
});

// Raw WebSocket to /attach_socket/websocket?sid=<sid>.
const wsScheme = window.location.protocol === "https:" ? "wss:" : "ws:";
const wsUrl = `${wsScheme}//${window.location.host}/attach_socket/websocket?sid=${encodeURIComponent(sid)}`;
const ws = new WebSocket(wsUrl);
ws.binaryType = "arraybuffer";

const textEncoder = new TextEncoder();

ws.addEventListener("open", () => {
  // Race we have to defend against:
  //   (a) ws may open BEFORE term.open (double-rAF) so term.cols=0
  //       at this moment — we can't send size now, but
  //   (b) term.onResize fires during fitAddon.fit() inside openTerminal,
  //       and at that point ws.readyState IS open, so sendCurrentSize
  //       there will succeed.
  //
  // Conversely if term.open ran first (slow WS handshake), term.onResize
  // already fired with ws CONNECTING and was a no-op — sendCurrentSize
  // here picks it up using the now-current term.cols/rows.
  //
  // Either way the dedupe in sendCurrentSize keeps us idempotent.
  sendCurrentSize();
  // Ctrl+L: nudge claude to repaint into the new (or unchanged) size.
  ws.send(textEncoder.encode("\x0c"));
});

ws.addEventListener("message", (event) => {
  if (event.data instanceof ArrayBuffer) {
    // Server pushed raw PTY bytes — feed straight into xterm.js.
    term.write(new Uint8Array(event.data));
  } else if (typeof event.data === "string") {
    // Text frames are reserved for future server-side control messages.
    // Not used today; ignore quietly.
  }
});

ws.addEventListener("close", () => {
  const banner = document.getElementById("ended-banner");
  if (banner) banner.style.display = "block";
  term.writeln("\r\n\x1b[33m[session ended]\x1b[0m");
});

ws.addEventListener("error", (e) => {
  term.writeln(`\r\n\x1b[31m[ws error: ${e.message || "unknown"}]\x1b[0m`);
});

// client → server: raw binary stdin (keystrokes + xterm.js's
// terminal-capability replies).
term.onData((data) => {
  if (ws.readyState === WebSocket.OPEN) {
    ws.send(textEncoder.encode(data));
  }
});

// (Window-resize → safeFit() is registered above. xterm.js's onResize
// callback sends the JSON resize text frame on every cols/rows change,
// so there's nothing to wire here.)
