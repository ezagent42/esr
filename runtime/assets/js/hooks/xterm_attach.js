// PR-22: xterm.js LiveView hook. Wires the browser-side terminal to
// EsrWeb.AttachLive's PubSub stream.
//
// Server → client: `stdout` event with raw bytes from PtyProcess (the
// peer broadcasts on PubSub topic pty:<sid> via on_raw_stdout/2).
// Client → server: `stdin` (each keystroke / paste) and `resize` (on
// window resize, fires SIGWINCH via :exec.winsz/3 in the BEAM).
// On PtyProcess termination, the LiveView pushes `ended` and we paint
// a "[session ended]" line into the terminal.
import { Terminal } from "xterm";
import { FitAddon } from "xterm-addon-fit";
import "xterm/css/xterm.css";

// ttyd-style dark theme. Operators tuning colors edit here.
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

export const XtermAttach = {
  mounted() {
    this.term = new Terminal({
      cursorBlink: true,
      cursorStyle: "block",
      fontFamily: '"SF Mono", Menlo, Monaco, "Courier New", monospace',
      fontSize: 14,
      lineHeight: 1.2,
      scrollback: 5000,
      convertEol: false,
      theme,
    });
    this.fitAddon = new FitAddon();
    this.term.loadAddon(this.fitAddon);
    this.term.open(this.el);

    // Defer the first fit until layout settles. The container is
    // flex:1 so it has zero size until the parent flex computes —
    // calling fit() synchronously in mounted() reads cols=0 and
    // produces an invisible terminal. requestAnimationFrame fires
    // after the next layout pass.
    requestAnimationFrame(() => {
      this.fitAddon.fit();
      this.sendResize();
      // Force claude to redraw once we know our real size: a Ctrl-L
      // gets sent as user input here, which prompts most TUIs to
      // repaint. Skip if you don't want this — comment the line.
      this.pushEvent("stdin", { data: "\x0c" });
    });

    // server → client
    this.handleEvent("stdout", ({ data }) => this.term.write(data));
    this.handleEvent("ended", ({ reason }) => {
      this.term.writeln(
        `\r\n\x1b[33m[session ended${reason ? ": " + reason : ""}]\x1b[0m`
      );
    });

    // client → server
    this.term.onData((data) => this.pushEvent("stdin", { data }));

    // resize handling — debounce so window-drag doesn't spam events.
    this._onWindowResize = () => {
      if (this._resizeTimer) clearTimeout(this._resizeTimer);
      this._resizeTimer = setTimeout(() => {
        this.fitAddon.fit();
        this.sendResize();
      }, 80);
    };
    window.addEventListener("resize", this._onWindowResize);
  },

  sendResize() {
    const { cols, rows } = this.term;
    if (cols > 0 && rows > 0) {
      this.pushEvent("resize", { cols, rows });
    }
  },

  destroyed() {
    if (this._onWindowResize) {
      window.removeEventListener("resize", this._onWindowResize);
    }
    if (this._resizeTimer) clearTimeout(this._resizeTimer);
    if (this.term) this.term.dispose();
  },
};
