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
term.open(document.getElementById("term"));

// Defer first fit until the browser computes the fixed/inset layout.
requestAnimationFrame(() => fitAddon.fit());

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
