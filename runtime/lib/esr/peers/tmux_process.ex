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
    # `tmux_socket: "/tmp/esr-test-N.sock"`, TmuxProcess runs under that
    # socket (no leaks into user's default tmux server). In production,
    # omit the param → tmux uses the default socket.
    name = "esr_cc_#{:erlang.unique_integer([:positive])}"
    base = %{session_name: name, dir: Esr.Peer.get_param(params, :dir) || "/tmp"}

    case Esr.Peer.get_param(params, :tmux_socket) do
      nil -> base
      path -> Map.put(base, :tmux_socket, path)
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
    {:ok,
     %{
       session_name: args.session_name,
       dir: args.dir,
       subscribers: [args[:subscriber] || self()],
       neighbors: Map.get(args, :neighbors, []),
       proxy_ctx: Map.get(args, :proxy_ctx, %{}),
       tmux_socket: Map.get(args, :tmux_socket)
     }}
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

    ["tmux"] ++ socket_args ++ ["-C", "new-session", "-s", state.session_name, "-c", state.dir]
  end

  @impl Esr.OSProcess
  def os_env(_state), do: []

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

  defp escape(text), do: String.replace(text, ~S("), ~S(\"))

  defp name_for(%{session_name: n}), do: String.to_atom("esr_tmux_#{n}")
end
