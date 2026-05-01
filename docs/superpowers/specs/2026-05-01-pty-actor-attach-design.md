# PR-22 — PtyProcess actor + xterm.js LiveView attach

Date: 2026-05-01.
Status: Spec — rev 3 post user review (drop auth/Tracker, route URL through `Esr.Uri`).

## TLDR

- **Problem:** `Esr.Peers.TmuxProcess` runs claude inside a `tmux -C` (control mode) child of erlexec. Tmux is a separate OS process tree; its lifecycle is hard for BEAM to fully own (the zombie-session class of bugs we hit in PR-21κ live test). The original justification was multi-attach for operator copilot — but operator multi-attach needs are realistically (b) "all clients are writers, no auth, Tailscale boundary," which Phoenix.PubSub solves natively without a multiplexer.
- **Decision:** Replace `TmuxProcess` with a generic `Esr.Peers.PtyProcess` peer that owns the master fd of the spawned process (via erlexec `:pty` wrapper), and expose attach via `EsrWeb.AttachLive` LiveView with xterm.js. A new `/attach` slash returns a clickable URL.
- **Why:** Brings all of CC's lifecycle into BEAM's supervisor tree (zombie eliminated). Operator gets a better副驾 UX: browser-based, copy/paste, scrollback, shareable URL. Generic `PtyProcess` becomes the foundation for future TUI-backed agents (vim, htop, custom tools) — the first real "pty actor" abstraction in ESR.
- **Where it landed:** PR-22 (this spec → impl plan → ship).

## Goals

1. **Eliminate tmux entirely.** `TmuxProcess` deleted. No tmux dependency in production runtime.
2. **Generic `PtyProcess` peer.** Owns one OS process via erlexec PTY. Composable for future agents.
3. **xterm.js LiveView attach.** Operators visit `/attach/<sid>` in browser, see claude's TUI, type into it. Multiple browser tabs simultaneously = multi-attach.
4. **`/attach` slash** in Feishu returns the URL.
5. **Preserve esr-cc.sh.** Operator-tunable shell wrapper (proxy via `esr-cc.local.sh`, env munging) stays as the spawn target — only the wrapping layer (tmux → PtyProcess) changes.
6. **No auth in v1.** Tailscale network boundary is the ACL; user direction 2026-05-01: "tailnet 上都是可信用户". Public on the bound interface. Capability-based per-user auth (`session:default/attach` scope) and signed-token gating land in a follow-up PR when we open ESR beyond the trusted Tailnet.
7. **Attach URL uses `esr://` URI grammar.** The `/attach` slash returns an `esr://localhost/sessions/<sid>/attach` URI, rendered to a clickable HTTP URL via `Esr.Uri.to_http_url/1`. The HTTP path mirrors the URI segments — `http://<endpoint>/sessions/<sid>/attach` — so `Esr.Uri` stays the single source of truth for resource addressing across slash commands, channel sources, and now operator UI.

## Non-goals

1. **cc_mcp lifecycle decoupling.** That's `docs/issues/02-cc-mcp-decouple-from-claude.md` — separate PR. claude still spawns cc_mcp via stdio in this PR; restart story stays as-is (claude restart kills cc_mcp).
2. **session-ids.yaml write-side.** The `--resume` mechanism is half-built; out of scope. Future PR can add it on top of PtyProcess unchanged.
3. **Auth.** No tokens, no rate-limiting, no scope checks. Public on the bound interface.
4. **PtyProcess for non-CC agents.** Ship just for CC; the abstraction supports more, but no other agents get migrated in this PR.
5. **Performance / scrollback persistence.** xterm.js handles in-browser scrollback; server doesn't persist a separate buffer. **Late-joiner UX is a known regression vs `tmux attach`**: a new browser tab sees blank until claude next emits output. Documented operator workaround: type `Ctrl-L` to force claude to redraw. Server-side ANSI replay is a follow-up if v1 friction is real.

## Architecture

### Process tree (post-migration)

```
Esr.Session.<sid>  (Supervisor, :one_for_all)
├─ Esr.SessionProcess           (per-session metadata GenServer)
└─ peers DynamicSupervisor      (:one_for_one)
   ├─ FCP                        (Stateful peer)
   ├─ cc_process                 (Stateful peer)
   └─ PtyProcess                 ← new; replaces TmuxProcess
       └─ erlexec :pty
          └─ bash scripts/esr-cc.sh
             └─ exec claude --mcp-config .mcp.json ...
                └─ cc_mcp (Python stdio child of claude — issue 02 territory)
```

### Data flow

#### Stdout from claude → operator browser

```
claude stdout
  └─ erlexec → BEAM PtyProcess GenServer (handle_info {:stdout, …})
       └─ broadcast on Phoenix.PubSub topic "pty:<sid>"
          ├─ AttachLive #1 (browser tab A) → xterm.js renders bytes
          └─ AttachLive #2 (browser tab B) → xterm.js renders bytes

cc_process is **not** a PTY subscriber. The conversation path
(claude reply text → cc_process) flows independently via
cc_mcp → `cli:channel/<sid>` → cc_process (`handle_upstream({:text, ...})`).
This is current production reality: `cc_process.ex:165–174` explicitly
drops `{:tmux_output, _}` as `:tmux_diagnostic`. PR-22 keeps that
separation — PtyProcess only fans stdout out to LiveView attachers.
```

#### Stdin from operator → claude

```
xterm.js keydown/paste in browser
  └─ LiveView event "stdin" payload {data: <bytes>}
       └─ AttachLive.handle_event → cast PtyProcess
          └─ PtyProcess.handle_cast({:write, data}, state)
             └─ :exec.send(state.os_pid, data) → claude PTY master
```

#### PTY size sync

```
xterm.js `onResize` (window resize, font change)
  └─ LiveView event "resize" payload {cols, rows}
       └─ AttachLive.handle_event → cast PtyProcess
          └─ PtyProcess.handle_cast({:resize, cols, rows}, state)
             └─ :exec.winsz(state.os_pid, cols, rows) → SIGWINCH to claude
```

### `Esr.Peers.PtyProcess` shape

```elixir
defmodule Esr.Peers.PtyProcess do
  @moduledoc """
  Generic PTY-backed peer. Owns the master fd of an OS process spawned
  via erlexec's `:pty` wrapper. Fans stdout out to PubSub topic
  `"pty:<session_id>"` for AttachLive subscribers; accepts stdin via
  cast `{:write, bytes}`.

  Replaces `Esr.Peers.TmuxProcess` (PR-22, 2026-05-01). The tmux
  control-mode protocol layer is gone; claude's TUI runs directly
  under erlexec's PTY.
  """

  @behaviour Esr.Role.State
  use Esr.Peer.Stateful
  use Esr.OSProcess, kind: :pty, wrapper: :pty

  # spawn_args/1 produces the `os_cmd` argv: ["bash", "scripts/esr-cc.sh"]
  # plus per-session env (ESR_SESSION_ID, ESR_WORKSPACE, …) — copied
  # verbatim from TmuxProcess.os_env/1.
end
```

Key differences from `TmuxProcess`:
- No `tmux -C` framing → no `parse_event/1`
- No `send-keys` (xterm.js sends raw bytes via `:exec.send`)
- No `kill-session` cleanup (erlexec handles process exit)
- No `mcp_config_path` rendering inside this peer (esr-cc.sh already owns it — see "MCP config rendering" below)
- Adds: `handle_cast({:write, data}, state)` for keystroke pass-through
- Adds: `handle_cast({:resize, cols, rows}, state)` for window-size sync
- stdout fan-out broadcasts to `"pty:<sid>"` topic (new)
- T12a auto-confirm of claude trust dialogs: ports the existing 5s/8s/20s `["1", :enter]` send-keys schedule (`tmux_process.ex:354–371`) to raw `:exec.send(os_pid, "1\r")` calls. Same timing, just bypasses tmux's send-keys.

### PubSub broadcast contract

PtyProcess broadcasts raw stdout chunks directly to `"pty:<sid>"` — no line-splitting, no parsing. xterm.js needs ANSI escape sequences delivered intact, and erlexec chunk boundaries can split mid-escape:

```elixir
def handle_info({:stdout, _os_pid, raw_chunk}, state) do
  Phoenix.PubSub.broadcast(EsrWeb.PubSub, "pty:#{state.session_id}", {:pty_stdout, raw_chunk})
  {:noreply, state}
end
```

No need to keep a line-buffer for cc_process: the conversation path goes through cc_mcp, not PTY stdout. `cc_process.ex:165–174` already drops `{:tmux_output, _}` as `:tmux_diagnostic`. Removing the parsed `{:tmux_output, bytes}` upstream message in PR-22 is a clean net deletion.

On termination, broadcast a sentinel so attached LiveViews can render an "ended" overlay rather than silently freeze:

```elixir
def on_terminate(reason, state) do
  Phoenix.PubSub.broadcast(EsrWeb.PubSub, "pty:#{state.session_id}", {:pty_closed, reason})
  :ok
end
```

### Stdin write path

`PtyProcess.write/2` and `PtyProcess.resize/3` are public API on the peer module. They delegate to the worker (which holds the actual `os_pid` from `:exec.run_link/2`):

```elixir
def write(sid, data) do
  with {:ok, worker_pid} <- worker_pid_for(sid) do
    Esr.OSProcess.OSProcessWorker.write_stdin(worker_pid, data)
  end
end

def resize(sid, cols, rows) do
  with {:ok, worker_pid} <- worker_pid_for(sid) do
    GenServer.cast(worker_pid, {:winsz, cols, rows})  # new worker handler
  end
end
```

Mirrors `TmuxProcess.send_command/2` (line 138) and existing `OSProcessWorker.write_stdin/2`. The worker translates `{:winsz, cols, rows}` into `:exec.winsz(state.os_pid, cols, rows)` — small addition to `runtime/lib/esr/os_process.ex`.

### MCP config rendering

`.mcp.json` is rendered by `scripts/esr-cc.sh` (lines ~83–99) at session spawn — **not** by TmuxProcess in production. `TmuxProcess.render_mcp_config!/1` is dead code on the dev/prod boot path; deletion is safe. PR-22 deletes it along with the rest of TmuxProcess; no new home needed.

### Concurrent writers: documented behavior, no lock

Two operators typing simultaneously into the same `:exec.send` stream interleaves bytes character-by-character. v1 policy: **document the behavior, no enforcement.** Per Tailnet-trust model, operators are expected to coordinate informally ("I'll drive — you watch"). If concurrent-write friction shows up in real use, follow-up PR can add a `Phoenix.Tracker`-backed single-owner lock without changing the URL scheme. Read-only viewers and read/write attachers see identical stdout — the owner-vs-viewer distinction is purely a stdin gate.

### URL scheme: `esr://` URI as canonical, HTTP path mirrors

`/attach` slash returns a renderable string: the operator-friendly HTTP URL paired with the canonical `esr://` URI. URI grammar (PRD §7.5, `Esr.Uri`) is the source of truth:

```
canonical: esr://localhost/sessions/<sid>/attach
http:      http://<endpoint-host>:<port>/sessions/<sid>/attach
```

`Esr.Uri.to_http_url/2` (new helper) bridges them — pulls `host:port` from `EsrWeb.Endpoint.url/0` (or an explicit override), substitutes scheme + authority while keeping the path segments verbatim. Path-segment fidelity matters: future `esr` CLI / dashboard / TUI all parse `Esr.Uri` and will accept the same `/sessions/<sid>/attach` path without mapping tables.

The Router's `live "/sessions/:sid/attach", AttachLive` pattern makes `/sessions/<sid>/attach` the public web path — same shape as the URI's path segments. Going forward, anywhere ESR has an HTTP-resource view of an `esr://` resource, the rule is "HTTP path = URI path". (e.g. a future `/sessions/<sid>/transcript` LiveView would map from `esr://localhost/sessions/<sid>/transcript`.)

### `EsrWeb.AttachLive` shape

```elixir
defmodule EsrWeb.AttachLive do
  use Phoenix.LiveView

  def mount(%{"sid" => sid}, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(EsrWeb.PubSub, "pty:#{sid}")
    end

    {:ok, assign(socket, sid: sid, terminal_id: "term-#{sid}")}
  end

  def render(assigns), do: ~H"""
    <div id={@terminal_id} phx-hook="XtermAttach" data-sid={@sid}></div>
    """

  def handle_event("stdin", %{"data" => data}, socket) do
    Esr.Peers.PtyProcess.write(socket.assigns.sid, data)
    {:noreply, socket}
  end

  def handle_event("resize", %{"cols" => c, "rows" => r}, socket) do
    Esr.Peers.PtyProcess.resize(socket.assigns.sid, c, r)
    {:noreply, socket}
  end

  def handle_info({:pty_stdout, data}, socket) do
    {:noreply, push_event(socket, "stdout", %{data: data})}
  end

  def handle_info({:pty_closed, reason}, socket) do
    {:noreply, push_event(socket, "ended", %{reason: inspect(reason)})}
  end
end
```

### xterm.js client hook (`assets/js/hooks/xterm_attach.js`)

```javascript
import { Terminal } from "xterm";
import { FitAddon } from "xterm-addon-fit";

export const XtermAttach = {
  mounted() {
    this.term = new Terminal({ cursorBlink: true, fontFamily: "monospace" });
    const fitAddon = new FitAddon();
    this.term.loadAddon(fitAddon);
    this.term.open(this.el);
    fitAddon.fit();

    // server → client
    this.handleEvent("stdout", ({ data }) => this.term.write(data));

    // client → server
    this.term.onData((data) => this.pushEvent("stdin", { data }));

    // resize handling
    const sendResize = () => {
      const { cols, rows } = this.term;
      this.pushEvent("resize", { cols, rows });
    };
    window.addEventListener("resize", () => { fitAddon.fit(); sendResize(); });
    sendResize();
  },
};
```

### `/attach` slash command

slash-routes.yaml entry:
```yaml
"/attach":
  kind: attach
  permission: null              # PR-22 no auth; future: session:default/attach
  command_module: "Esr.Admin.Commands.Attach"
  requires_workspace_binding: true
  requires_user_binding: true
  category: "Sessions"
  description: "Get a browser link to attach to this session's claude TUI"
  args: []
```

Command module:
```elixir
defmodule Esr.Admin.Commands.Attach do
  @behaviour Esr.Role.Control

  def execute(%{"args" => args}) do
    chat_id = args["chat_id"] || ""
    app_id = args["app_id"] || ""
    thread_id = args["thread_id"] || ""

    case Esr.SessionRegistry.lookup_by_chat_thread(chat_id, app_id, thread_id) do
      {:ok, sid, _refs} ->
        uri = Esr.Uri.build_path(["sessions", sid, "attach"], "localhost")
        http_url = Esr.Uri.to_http_url(uri, EsrWeb.Endpoint)
        {:ok, %{"text" => "🖥 attach: [#{http_url}](#{http_url})\nuri: `#{uri}`"}}

      :not_found ->
        {:ok, %{"text" => "no live session in this chat. start one with /new-session first"}}
    end
  end
end
```

### Router

```elixir
# runtime/lib/esr_web/router.ex
scope "/", EsrWeb do
  pipe_through :browser
  live "/sessions/:sid/attach", AttachLive
end
```

HTTP path mirrors `Esr.Uri` segments — `/sessions/<sid>/attach` is the canonical resource path for both URI and HTTP views.

### Lifecycle

- `PtyProcess.on_os_exit(0, _) → {:stop, :claude_died_unexpectedly}` — same as PR-21ω''. Any claude exit triggers peers DynamicSupervisor's `:transient` restart. New PtyProcess gets a new pid; PR-21ω' rewire patches FCP/cc_process. AttachLive's PubSub subscription re-binds automatically (subscribers don't change with PtyProcess restart — topic is `"pty:<sid>"`, sid stable).
- AttachLive disconnect: LiveView closes → PubSub subscription dies → no impact on PtyProcess (no per-attach state held).
- Repeated PtyProcess crash: peers DynamicSupervisor max_restarts threshold → cascade up via existing :one_for_all → session terminated → next inbound auto-creates fresh.

## Migration

### Files added

- `runtime/lib/esr/peers/pty_process.ex` — new peer (~150 LOC; raw-stdout broadcast + `:winsz` cast + T12a auto-confirm port)
- `runtime/lib/esr_web/live/attach_live.ex` — LiveView (~80 LOC; subscribe + push raw stdout + ended overlay)
- `runtime/lib/esr_web/components/layouts.ex` + `root.html.heex` — minimal LiveView layout (~30 LOC; not currently in repo)
- `runtime/assets/js/hooks/xterm_attach.js` — client hook (~50 LOC; handles `stdout` + `ended` events)
- `runtime/assets/package.json` + esbuild config — xterm + xterm-addon-fit
- `runtime/lib/esr/admin/commands/attach.ex` — slash command (~30 LOC; `Esr.Uri.build` + `to_http_url`)
- `runtime/test/esr/peers/pty_process_test.exs` — unit tests (~80 LOC)
- `runtime/test/esr/admin/commands/attach_test.exs` — slash test (~30 LOC; asserts URI shape + HTTP renderer)
- `runtime/test/esr/uri_test.exs` — extend with `to_http_url/2` cases (~20 LOC)

### Files modified

- `runtime/lib/esr/uri.ex` — add `to_http_url/2` helper that pulls `host:port` from the given `Phoenix.Endpoint` and substitutes scheme/authority while preserving path segments (~15 LOC)
- `runtime/lib/esr/os_process.ex` — add `{:winsz, c, r}` cast in `OSProcessWorker` calling `:exec.winsz/3` (~10 LOC)
- `runtime/lib/esr_web/endpoint.ex` — uncomment `socket "/live", Phoenix.LiveView.Socket`; add `Plug.Static` entry for xterm.js bundle (~5 LOC). Currently the LiveView socket line is commented out — this is a real change, not a no-op.
- `runtime/lib/esr_web/router.ex` — add `:browser` pipeline (`accepts`, `fetch_session`, `protect_from_forgery`, `put_root_layout`) + `live "/sessions/:sid/attach", AttachLive` (~15 LOC). Today's router is a 6-line stub with no pipelines.
- `runtime/priv/slash-routes.default.yaml` — add `/attach` entry
- `runtime/priv/agents.yaml` (and dev/prod operator-installed copies) — `cc` agent's `pipeline.inbound` lists `pty_process` instead of `tmux_process`
- `scripts/esr-cc.sh` — update 5+ tmux references on lines 4, 63–67, 122 (the `pwd` fallback comment becomes inaccurate; underlying `pwd` fallback still works because erlexec sets `cwd` via `{:cd, …}` in `os_process.ex:316`)

### Files deleted

- `runtime/lib/esr/peers/tmux_process.ex` — entire file (~750 LOC)
- `runtime/test/esr/peers/tmux_process_test.exs` — tmux-specific tests (~600 LOC, 14 describe blocks). Many blocks (`parse_event/1`, `capture_pane`, `send_keys` token escaping, MCP config rendering) test tmux-specific concerns and don't translate.
- `runtime/test/esr/peers/tmux_rewire_test.exs` — port to `pty_rewire_test.exs` (rename only — same `:tmux_process` → `:pty_process` neighbor key swap, mechanical)
- `runtime/test/esr/integration/n2_tmux_test.exs` — needs **rewrite** as `n2_pty_test.exs` (asserts tmux output framing; rewrite for raw PTY bytes)

### Net LOC

- Added: ~480 LOC code + tests + frontend (rev 3: dropped Phoenix.Token + Tracker + Presence modules; cc_process line-buffer also gone)
- Deleted: ~1350 LOC TmuxProcess + tests
- **Net: -870 LOC** (rev 3 estimate; tmux protocol parsing, send_keys, capture-pane, MCP-config-render all gone)

### Compatibility

- workspaces.yaml's `start_cmd: scripts/esr-cc.sh` semantic preserved.
- esr-cc.sh / esr-cc.local.sh files unchanged (operator escape hatch preserved).
- agents.yaml's pipeline.inbound shape unchanged; just `tmux_process` peer name → `pty_process`.
- Existing FAA / SlashHandler / SessionRouter / cc_process / FCP all unchanged.
- BREAKING for operators: `tmux -S … attach` no longer works. Workflow → browser-based.

## Open questions for review

Resolved during rev 2 (subagent review pass):

- ~~Where does `attach_url_base` come from?~~ **Resolved**: rev 3 routes via `Esr.Uri.to_http_url/2` reading `EsrWeb.Endpoint.url/0`. No separate config.
- ~~Does MCP config rendering move into PtyProcess?~~ **Resolved**: production `.mcp.json` is already rendered by `scripts/esr-cc.sh:83–99`. `TmuxProcess.render_mcp_config!/1` is dead code — deleted along with the rest.
- ~~Late-joiner snapshot?~~ **Resolved**: live-tail only for v1; operator types `Ctrl-L` for redraw. Documented as a known regression vs `tmux attach`. Server-side replay is a follow-up.
- ~~T12a auto-confirm of trust dialogs?~~ **Resolved**: ports the existing `["1", :enter]` schedule to raw `:exec.send(os_pid, "1\r")`. Same timings.
- ~~Does PR-21ω' rewire generalize from `:tmux_process` to `:pty_process`?~~ **Resolved**: yes, mechanical rename. Callsites: `tmux_process.ex:799` (the rewire itself), plus `cc_process` and FCP state setters (verified by greps).

Resolved during rev 3 (user review):

- ~~Auth?~~ **Resolved**: dropped — Tailnet trust model. Cap-based auth is a follow-up PR (likely lands with `cc_mcp` decouple / channel abstraction).
- ~~Multi-writer race?~~ **Resolved**: documented behavior, no enforcement v1. Operators coordinate informally.
- ~~`cc_process` stdout consumption?~~ **Resolved**: cc_process does **not** consume PTY output today (`cc_process.ex:165–174` drops `:tmux_output` as `:tmux_diagnostic`). Conversation path is cc_mcp → `cli:channel/<sid>` → cc_process. PtyProcess only broadcasts raw bytes to LiveView; no line-buffer needed.
- ~~URL scheme?~~ **Resolved**: `esr://localhost/sessions/<sid>/attach` canonical URI, rendered to `http://<endpoint>/sessions/<sid>/attach` via `Esr.Uri.to_http_url/2`. HTTP path = URI path going forward.

Still open — minor; can be answered during plan-writing if no team objections:

1. **xterm.js bundling**: does `runtime/assets/` already have an esbuild pipeline (the repo has `mix esbuild` precedent in some assets), or do we add it from scratch in PR-22? Implementation plan can audit `runtime/assets/` as step 1.
2. **Endpoint LiveView socket preset**: currently `endpoint.ex:14–16` has the LiveView socket commented out. Standard Phoenix LiveView preset (`signing_salt`, `pubsub_server: EsrWeb.PubSub`) appears fine — the repo's `config/config.exs` already exposes `signing_salt`. Confirming during impl.
3. **Broadcast storm backpressure**: a claude TUI repaint is 4–16 KB; `push_event` fan-out has no explicit throttle. Plan: ship without, add `:throttle` only if real-world latency shows it's needed. Acceptable?
4. **session-end UX**: `{:pty_closed, _}` broadcast renders overlay in attached LiveViews. Should `/end-session` also DM "session closed" to operator? My take: overkill; LiveView overlay is enough. Flag if team disagrees.

## References

- `docs/issues/closed-01-tmux-vs-erlexec-pty.md` — earlier brainstorm that decided to keep tmux (now superseded by this spec — operator multi-attach needs are met by xterm.js, so the tmux justification falls away)
- `docs/issues/02-cc-mcp-decouple-from-claude.md` — separate concern, complementary
- PR-21β erlexec migration field notes (`docs/notes/erlexec-worker-lifecycle.md`)
- xterm.js: https://xtermjs.org/
- erlexec PTY mode: documented in PR-21β and erlexec hexdocs
