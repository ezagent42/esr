defmodule Esr.Peers.TmuxProcess do
  @moduledoc """
  Peer + OSProcess composition that owns one tmux session in control mode (`-C`).

  Control mode gives a tagged, line-protocol output stream
  (`%output`, `%begin`, `%end`, `%exit`, `%session-changed`, etc.) so
  consumers don't need to parse raw ANSI.

  ## Role in the CC chain (PR-3)

  `Esr.Peers.TmuxProcess` sits immediately downstream of
  `Esr.Peers.CCProcess`. Two wiring points matter:

    * **Downstream from CCProcess** — `handle_downstream({:send_input,
      text}, state)` writes `send-keys -t <session> "<escaped>" Enter\\n`
      to tmux's stdin via the generated `OSProcessWorker.write_stdin/2`.
      A legacy `{:send_keys, text}` clause remains for PR-1 callers.

    * **Upstream to CCProcess** — when the worker forwards a
      `{:os_stdout, line}` event, we parse it with `parse_event/1`,
      broadcast `{:tmux_event, _}` to subscribers, and — for
      `{:output, _pane, bytes}` events specifically — also send
      `{:tmux_output, bytes}` to the `cc_process` neighbor so
      `CCProcess.handle_upstream/2` can feed it into the Python handler.

  ## Cleanup

  Tmux owns its own session lifecycle. `on_terminate/1` — called from
  `OSProcessWorker.terminate/2` — runs `tmux kill-session -t <name>`
  when the peer stops normally. The erlexec port program supplements
  this by reaping the `tmux -C` client on BEAM hard-crash.

  ## Wrapper mode: `:pty`

  Uses `wrapper: :pty` (erlexec with pseudo-terminal). `tmux -C`
  (control mode) on macOS exits immediately if spawned without a
  controlling TTY — empirically this was the cause of the
  `tmux_process_test` integration flakes pre-PR-3. erlexec's native
  PTY support fixes this without needing `script(1)` or a shell
  wrapper. See `docs/notes/erlexec-migration.md`.

  ## PR-9 T11b.3 — claude CLI + cc_mcp launch

  When spawned as part of a real CC session pipeline, TmuxProcess:

    1. Renders a per-session MCP config to `/tmp/esr-mcp-<session_id>.json`
       pointing at `<repo>/adapters/cc_mcp` (the stdio MCP server claude
       spawns as a subprocess).
    2. Injects `ESR_SESSION_ID`, `ESR_WORKSPACE`, `ESR_CHAT_IDS`,
       `ESR_ESRD_URL` as the spawned tmux process's environment, so they
       propagate to claude and through to cc_mcp.
    3. Launches the claude CLI as the pane's initial process via
       `tmux new-session … "<claude …>"` — tmux hands the trailing
       positional to `/bin/sh -c`.

  See spec `docs/superpowers/specs/2026-04-24-pr9-t11b-cc-cli-mcp.md` §4.2 A
  and `docs/notes/claude-code-channels-reference.md` for why
  `--dangerously-load-development-channels server:esr-channel` is required.

  See spec §3.2 and §4.1 TmuxProcess card; expansion P3-3.
  """

  use Esr.Peer.Stateful
  use Esr.OSProcess, kind: :tmux, wrapper: :pty

  @doc """
  Start a tmux control-mode peer.

  Args:
    * `:session_name` (required) — tmux session name.
    * `:dir` (required) — starting directory for the session.
    * `:subscriber` (optional) — pid that receives `{:tmux_event, _}`
      messages. Defaults to the caller of `start_link/1`.
    * `:neighbors` (optional, keyword) — other peers in the chain.
      Currently recognised key: `:cc_process`.
    * `:proxy_ctx` (optional, map) — shared context snapshot threaded
      through the Peer.Proxy hooks (unused in PR-3 but kept for chain
      consistency).
  """
  def start_link(args) do
    args = Map.put_new(args, :subscriber, self())
    GenServer.start_link(__MODULE__.OSProcessWorker, args, name: name_for(args))
  end

  @impl Esr.Peer
  def spawn_args(params) do
    # Optional tmux_socket for test isolation: if caller passes
    # `tmux_socket: "/tmp/…"`, TmuxProcess runs under that socket; if
    # the application env `:esr, :tmux_socket_override` is set (J1 —
    # driven by ESR_E2E_TMUX_SOCK at boot), use that as a fallback.
    name = "esr_cc_#{:erlang.unique_integer([:positive])}"

    base =
      %{
        session_name: name,
        dir: Esr.Peer.get_param(params, :dir) || "/tmp",
        # PR-9 T11b.3: session context needed to render the per-session
        # MCP config + build the claude CLI invocation. All optional —
        # SessionRouter.enrich_params/2 populates them, but legacy/tests
        # may call spawn_args/1 without. `os_env/1` / `os_cmd/1` treat
        # `nil` as "skip this var" / "use default".
        session_id: Esr.Peer.get_param(params, :session_id),
        workspace_name: Esr.Peer.get_param(params, :workspace_name),
        chat_id: Esr.Peer.get_param(params, :chat_id),
        app_id: Esr.Peer.get_param(params, :app_id),
        start_cmd: Esr.Peer.get_param(params, :start_cmd)
      }

    case Esr.Peer.get_param(params, :tmux_socket) ||
           Application.get_env(:esr, :tmux_socket_override) do
      nil -> base
      path when is_binary(path) -> Map.put(base, :tmux_socket, path)
    end
  end

  # Added by P3-6: the full CC-chain `cc` agent in `simple.yaml` now
  # lists `tmux_process` in `pipeline.inbound`, so SessionRouter spawns
  # it via `DynamicSupervisor.start_child(sup, {TmuxProcess, args})`.
  # The `use Esr.Peer.Stateful` / `use Esr.OSProcess` macros don't
  # inject a GenServer-style `child_spec/1`, so we provide one.
  def child_spec(args) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [args]},
      type: :worker,
      restart: :transient,
      shutdown: 5_000
    }
  end

  @doc """
  Write a tmux control-mode command to the session's stdin.

  The worker appends a newline if the command doesn't already end in one.
  """
  def send_command(pid, cmd) do
    line = if String.ends_with?(cmd, "\n"), do: cmd, else: cmd <> "\n"
    __MODULE__.OSProcessWorker.write_stdin(pid, line)
  end

  # Called by the generated OSProcessWorker.init/1 (not a GenServer
  # callback — this module doesn't `use GenServer` directly; the
  # generated OSProcessWorker child module does). Returns the initial
  # peer state.
  def init(%{session_name: _, dir: _} = args) do
    state = %{
      session_name: args.session_name,
      dir: args.dir,
      subscribers: [args[:subscriber] || self()],
      neighbors: Map.get(args, :neighbors, []),
      proxy_ctx: Map.get(args, :proxy_ctx, %{}),
      tmux_socket: Map.get(args, :tmux_socket),
      # PR-9 T11b.3 — session context for claude + cc_mcp.
      session_id: Map.get(args, :session_id),
      workspace_name: Map.get(args, :workspace_name),
      chat_id: Map.get(args, :chat_id),
      app_id: Map.get(args, :app_id),
      start_cmd: Map.get(args, :start_cmd),
      mcp_config_path: nil
    }

    # Render per-session MCP config file when we have a session_id.
    state =
      case state.session_id do
        sid when is_binary(sid) and sid != "" ->
          path = mcp_config_path_for(sid)
          :ok = render_mcp_config!(path)
          %{state | mcp_config_path: path}

        _ ->
          state
      end

    {:ok, state}
  end

  @impl Esr.Peer.Stateful
  def handle_upstream({:os_stdout, line}, state) do
    event = parse_event(line)
    tuple = {:tmux_event, event}
    Enum.each(state.subscribers, &send(&1, tuple))

    case event do
      {:output, _pane_id, bytes} ->
        case Keyword.get(state.neighbors, :cc_process) do
          pid when is_pid(pid) -> send(pid, {:tmux_output, bytes})
          _ -> :ok
        end

      _ ->
        :ok
    end

    {:forward, [tuple], state}
  end

  def handle_upstream(_msg, state), do: {:forward, [], state}

  @impl Esr.Peer.Stateful
  def handle_downstream({:send_input, text}, state) do
    cmd = "send-keys -t #{state.session_name} \"#{escape(text)}\" Enter\n"
    __MODULE__.OSProcessWorker.write_stdin(self(), cmd)
    {:forward, [], state}
  end

  # Keep the PR-1 `{:send_keys, text}` clause for backward compat with
  # existing tmux callers; new code in PR-3 uses `{:send_input, text}`.
  def handle_downstream({:send_keys, text}, state) do
    handle_downstream({:send_input, text}, state)
  end

  def handle_downstream(_msg, state), do: {:forward, [], state}

  @impl Esr.OSProcess
  def os_cmd(state) do
    # No `-d` flag — see docs/notes/tmux-socket-isolation.md
    socket_args =
      case Map.get(state, :tmux_socket) do
        nil -> []
        path -> ["-S", path]
      end

    base =
      ["tmux"] ++
        socket_args ++ ["-C", "new-session", "-s", state.session_name, "-c", state.dir]

    # PR-9 T11b.3 — if we have the session context, append a claude
    # invocation as a single shell-command positional (tmux hands it
    # to `/bin/sh -c`). Pre-T11b.3 callers (unit tests, the J1
    # override-env test) don't pass session_id; keep the idle-pane
    # behaviour for those.
    case claude_argv(state) do
      nil -> base
      argv when is_list(argv) -> base ++ [Enum.join(argv, " ")]
    end
  end

  @impl Esr.OSProcess
  def os_env(state) do
    case Map.get(state, :session_id) do
      sid when is_binary(sid) and sid != "" ->
        ws = Map.get(state, :workspace_name) || "default"
        chat_id = Map.get(state, :chat_id) || ""
        app_id = Map.get(state, :app_id) || ""

        chat_ids_json =
          Jason.encode!([%{chat_id: chat_id, app_id: app_id, kind: "feishu"}])

        [
          {"ESR_SESSION_ID", sid},
          {"ESR_WORKSPACE", ws},
          {"ESR_CHAT_IDS", chat_ids_json},
          {"ESR_ESRD_URL", channel_ws_url()}
        ]

      _ ->
        []
    end
  end

  @impl Esr.OSProcess
  def on_os_exit(0, _state), do: {:stop, :normal}
  def on_os_exit(status, _state), do: {:stop, {:tmux_crashed, status}}

  @impl Esr.OSProcess
  def on_terminate(%{session_name: name} = state) do
    # Per-socket `kill-server` is simpler + more robust than per-session
    # kill (session may have subshell children). With an isolated
    # `-S <path>` socket we also `File.rm/1` it to keep /tmp tidy.
    case Map.get(state, :tmux_socket) do
      nil ->
        _ = System.cmd("tmux", ["kill-session", "-t", name], stderr_to_stdout: true)

      path ->
        _ = System.cmd("tmux", ["-S", path, "kill-session", "-t", name], stderr_to_stdout: true)
        _ = System.cmd("tmux", ["-S", path, "kill-server"], stderr_to_stdout: true)
        _ = File.rm(path)
    end

    # Clean up per-session MCP config — best-effort; tests also assert
    # contents so they unlink their own.
    case Map.get(state, :mcp_config_path) do
      nil -> :ok
      "" -> :ok
      path when is_binary(path) -> _ = File.rm(path)
    end

    :ok
  end

  @doc """
  Parse a single tmux control-mode output line into a structured event.

  Recognised prefixes: `%begin`, `%end`, `%output`, `%exit`. Any other
  line is returned as `{:unknown, line}`.
  """
  def parse_event("%begin " <> rest) do
    case String.split(String.trim_trailing(rest), " ", parts: 3) do
      [time, num, flags] -> {:begin, time, num, flags}
      [time, num] -> {:begin, time, num, ""}
      other -> {:unknown, "%begin " <> Enum.join(other, " ")}
    end
  end

  def parse_event("%end " <> rest) do
    case String.split(String.trim_trailing(rest), " ", parts: 3) do
      [time, num, flags] -> {:end, time, num, flags}
      [time, num] -> {:end, time, num, ""}
      other -> {:unknown, "%end " <> Enum.join(other, " ")}
    end
  end

  def parse_event("%output " <> rest) do
    case String.split(String.trim_trailing(rest), " ", parts: 2) do
      [pane_id, bytes] -> {:output, pane_id, bytes}
      [pane_id] -> {:output, pane_id, ""}
    end
  end

  def parse_event("%exit" <> _), do: {:exit}

  def parse_event(other), do: {:unknown, other}

  # ------------------------------------------------------------------
  # PR-9 T11b.3 helpers — exposed to the test module as public fns so
  # the unit tests can assert shape without having to start a real pane.
  # ------------------------------------------------------------------

  @doc """
  Build the claude CLI invocation (argv list) from the peer state.

  Returns `nil` when session context isn't available — callers use that
  as the signal to keep the pre-T11b.3 idle-pane behaviour.
  """
  @spec claude_argv(map()) :: [String.t()] | nil
  def claude_argv(%{session_id: sid} = state) when is_binary(sid) and sid != "" do
    case Map.get(state, :start_cmd) do
      custom when is_binary(custom) and custom != "" ->
        # Caller provided a custom start_cmd (from workspace.yaml) —
        # honour it verbatim; they own the claude invocation shape.
        String.split(custom, " ", trim: true)

      _ ->
        # PR-9 T11b.8 leak fix: in :test env the default MUST be a no-op
        # that keeps the pane alive but does NOT fork real claude
        # processes. Without this guard, every `SessionRouter.create_session`
        # in unit tests leaks a real claude process — the test suite on
        # 2026-04-24 spawned 8+ zombie claude CLIs across one `mix test`
        # run. Tests that want to exercise the real production argv shape
        # set `Application.put_env(:esr, :tmux_force_claude_launch, true)`
        # in their setup.
        if Mix.env() == :test and
             not Application.get_env(:esr, :tmux_force_claude_launch, false) do
          ["sh", "-c", "while :; do sleep 1; done"]
        else
          mcp_path = Map.get(state, :mcp_config_path) || mcp_config_path_for(sid)
          dir = Map.get(state, :dir) || "/tmp"

          [
            "claude",
            "--permission-mode",
            "bypassPermissions",
            "--dangerously-load-development-channels",
            "server:esr-channel",
            "--mcp-config",
            mcp_path,
            "--add-dir",
            dir
          ]
        end
    end
  end

  def claude_argv(_state), do: nil

  @doc """
  Render the per-session MCP config JSON to `path`. Exposed so tests
  can exercise the file shape without a real spawn.

  JSON shape (single `esr-channel` server entry):

      {"mcpServers": {"esr-channel": {
        "command": "uv",
        "args": ["run", "--project", "<repo>/adapters/cc_mcp",
                 "python", "-m", "esr_cc_mcp.channel"]
      }}}
  """
  @spec render_mcp_config!(Path.t()) :: :ok
  def render_mcp_config!(path) when is_binary(path) do
    project = Path.join(repo_root(), "adapters/cc_mcp")

    config = %{
      "mcpServers" => %{
        "esr-channel" => %{
          "command" => "uv",
          "args" => [
            "run",
            "--project",
            project,
            "python",
            "-m",
            "esr_cc_mcp.channel"
          ]
        }
      }
    }

    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(config))
    :ok
  end

  @doc """
  Per-session MCP config path — `/tmp/esr-mcp-<session_id>.json`.
  """
  @spec mcp_config_path_for(String.t()) :: Path.t()
  def mcp_config_path_for(session_id) when is_binary(session_id) do
    Path.join(System.tmp_dir!(), "esr-mcp-#{session_id}.json")
  end

  # ws://127.0.0.1:<port>/channel/socket/websocket?vsn=2.0.0 — mirrors
  # the shape Esr.Application.ws_url_for/1 uses for other sockets.
  defp channel_ws_url do
    port =
      case EsrWeb.Endpoint.config(:http) do
        opts when is_list(opts) -> Keyword.get(opts, :port, 4001)
        _ -> 4001
      end

    "ws://127.0.0.1:" <> Integer.to_string(port) <> "/channel/socket/websocket?vsn=2.0.0"
  end

  # Best-effort: honour ESR_REPO_DIR (set by cc-openclaw + dev scripts),
  # else ask git for the toplevel, else fall back to cwd. Mirrors the
  # pattern in Esr.WorkerSupervisor.repo_root/0.
  defp repo_root do
    cond do
      dir = System.get_env("ESR_REPO_DIR") ->
        dir

      true ->
        case System.cmd("git", ["rev-parse", "--show-toplevel"], stderr_to_stdout: true) do
          {path, 0} -> String.trim(path)
          _ -> File.cwd!()
        end
    end
  end

  defp escape(text), do: String.replace(text, ~S("), ~S(\"))

  defp name_for(%{session_name: n}), do: String.to_atom("esr_tmux_#{n}")
end
