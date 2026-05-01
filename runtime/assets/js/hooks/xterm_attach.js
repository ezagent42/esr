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

export const XtermAttach = {
  mounted() {
    this.term = new Terminal({
      cursorBlink: true,
      fontFamily: "Menlo, Monaco, monospace",
      fontSize: 13,
      convertEol: false,
    });
    const fitAddon = new FitAddon();
    this.term.loadAddon(fitAddon);
    this.term.open(this.el);
    fitAddon.fit();

    // server → client
    this.handleEvent("stdout", ({ data }) => this.term.write(data));
    this.handleEvent("ended", ({ reason }) => {
      this.term.writeln(`\r\n\x1b[33m[session ended${reason ? ": " + reason : ""}]\x1b[0m`);
    });

    // client → server
    this.term.onData((data) => this.pushEvent("stdin", { data }));

    // resize handling
    const sendResize = () => {
      const { cols, rows } = this.term;
      this.pushEvent("resize", { cols, rows });
    };

    this._onWindowResize = () => {
      fitAddon.fit();
      sendResize();
    };
    window.addEventListener("resize", this._onWindowResize);

    sendResize();
  },

  destroyed() {
    if (this._onWindowResize) {
      window.removeEventListener("resize", this._onWindowResize);
    }
    if (this.term) this.term.dispose();
  },
};
