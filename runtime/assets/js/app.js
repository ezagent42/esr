// PR-23: ESR attach page — direct Phoenix.Channel + xterm.js, no LiveView.
//
// Page is served by EsrWeb.AttachController.show/2 with sid embedded as
// window.ESR_SID. We open a WebSocket to /attach_socket, join channel
// `attach:<sid>`, and forward stdout/stdin/resize/ended between
// xterm.js and EsrWeb.AttachChannel.
import { Socket } from "phoenix";
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
  convertEol: false,
  theme,
});

const fitAddon = new FitAddon();
term.loadAddon(fitAddon);
term.open(document.getElementById("term"));

// Defer first fit until the browser computes the fixed/inset layout.
requestAnimationFrame(() => fitAddon.fit());

// Open Phoenix Socket + join attach:<sid> channel.
const socket = new Socket("/attach_socket");
socket.connect();

const channel = socket.channel("attach:" + sid, {});

channel
  .join()
  .receive("ok", () => {
    sendResize();
    // Nudge claude to repaint into the known viewport.
    channel.push("stdin", { data: "\x0c" });
  })
  .receive("error", (resp) => {
    term.writeln(
      "\r\n\x1b[31m[attach failed: " + JSON.stringify(resp) + "]\x1b[0m"
    );
  });

// server → client
channel.on("stdout", ({ data }) => term.write(data));
channel.on("ended", ({ reason }) => {
  const banner = document.getElementById("ended-banner");
  if (banner) banner.style.display = "block";
  term.writeln(
    "\r\n\x1b[33m[session ended" + (reason ? ": " + reason : "") + "]\x1b[0m"
  );
});

// client → server
term.onData((data) => channel.push("stdin", { data }));

// Debounced resize so window-drag doesn't spam SIGWINCH.
let resizeTimer;
function sendResize() {
  const { cols, rows } = term;
  if (cols > 0 && rows > 0) {
    channel.push("resize", { cols, rows });
  }
}
window.addEventListener("resize", () => {
  if (resizeTimer) clearTimeout(resizeTimer);
  resizeTimer = setTimeout(() => {
    fitAddon.fit();
    sendResize();
  }, 80);
});
