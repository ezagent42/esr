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
  fontFamily: '"SF Mono", Menlo, Monaco, "Courier New", monospace',
  fontSize: 14,
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
term.open(termContainer);

// xterm.js does not auto-resize when its container size changes
// (CSS layout, font load, viewport rotation, panel toggle, …). One
// `requestAnimationFrame` fit fires too early on slow font loads and
// leaves the terminal stuck at 80x24 — operator sees a "phone-width"
// terminal even when the browser viewport is desktop-sized.
//
// Fit on every container size change via ResizeObserver, plus an
// initial pass after fonts settle. Each fit is followed by sending
// the new winsize to the server so claude's TUI re-flows.
function fitNow() {
  try {
    fitAddon.fit();
    sendResize();
  } catch (_) {
    /* dimensions not yet measurable; next observer tick will retry */
  }
}

requestAnimationFrame(() => fitNow());

if (typeof ResizeObserver !== "undefined") {
  const ro = new ResizeObserver(() => fitNow());
  ro.observe(termContainer);
}

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
  sendResize();
  // Nudge claude to repaint into the known viewport.
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

// Debounced resize so window-drag doesn't spam SIGWINCH.
let resizeTimer;
function sendResize() {
  if (ws.readyState !== WebSocket.OPEN) return;
  const { cols, rows } = term;
  if (cols > 0 && rows > 0) {
    ws.send(JSON.stringify({ cols, rows }));
  }
}
window.addEventListener("resize", () => {
  if (resizeTimer) clearTimeout(resizeTimer);
  resizeTimer = setTimeout(() => {
    fitAddon.fit();
    sendResize();
  }, 80);
});
