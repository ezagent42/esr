// PR-22: ESR web entrypoint. Currently the only LiveView surface is
// EsrWeb.AttachLive at /sessions/:sid/attach (xterm.js terminal).
import { Socket } from "phoenix";
import { LiveSocket } from "phoenix_live_view";
import { XtermAttach } from "./hooks/xterm_attach";

const csrfToken = document
  .querySelector("meta[name='csrf-token']")
  ?.getAttribute("content");

const liveSocket = new LiveSocket("/live", Socket, {
  hooks: { XtermAttach },
  params: { _csrf_token: csrfToken },
});

liveSocket.connect();
window.liveSocket = liveSocket;
