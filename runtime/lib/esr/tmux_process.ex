defmodule Esr.TmuxProcess do
  @moduledoc """
  Peer + OSProcess composition that owns one tmux session in control mode (`-C`).

  Control mode gives a tagged, line-protocol output stream
  (`%output`, `%begin`, `%end`, `%exit`, `%session-changed`, etc.) so
  consumers don't need to parse raw ANSI.

  See spec §3.2 and §4.1 TmuxProcess card.
  """

  use Esr.Peer.Stateful
  # NOTE: wrapper: :none bypasses the MuonTrap binary. We cannot use muontrap
  # here because `--capture-output` (needed to receive tmux's `%begin/%end/...`
  # events on stdout) also makes muontrap consume its own stdin for ack bytes,
  # which means writes from Esr.TmuxProcess.send_command/2 would never reach
  # tmux's stdin. Tmux owns its own session lifecycle (`tmux kill-session`), so
  # BEAM-SIGKILL orphan protection is less critical than for arbitrary sidecars.
  use Esr.OSProcess, kind: :tmux, wrapper: :none

  @doc """
  Start a tmux control-mode peer.

  Args:
    * `:session_name` (required) — tmux session name.
    * `:dir` (required) — starting directory for the session.
    * `:subscriber` (optional) — pid that receives `{:tmux_event, _}`
      messages. Defaults to the caller of `start_link/1`.
  """
  def start_link(args) do
    args = Map.put_new(args, :subscriber, self())
    GenServer.start_link(__MODULE__.OSProcessWorker, args, name: name_for(args))
  end

  @doc """
  Write a tmux control-mode command to the session's stdin.

  The worker appends a newline if the command doesn't already end in one.
  """
  def send_command(pid, cmd) do
    line = if String.ends_with?(cmd, "\n"), do: cmd, else: cmd <> "\n"
    __MODULE__.OSProcessWorker.write_stdin(pid, line)
  end

  @impl Esr.Peer.Stateful
  def init(%{session_name: _, dir: _} = args) do
    {:ok,
     %{
       session_name: args.session_name,
       dir: args.dir,
       subscribers: [args[:subscriber] || self()]
     }}
  end

  @impl Esr.Peer.Stateful
  def handle_upstream({:os_stdout, line}, state) do
    event = parse_event(line)
    tuple = {:tmux_event, event}
    Enum.each(state.subscribers, &send(&1, tuple))
    {:forward, [tuple], state}
  end

  def handle_upstream(_msg, state), do: {:forward, [], state}

  @impl Esr.Peer.Stateful
  def handle_downstream({:send_keys, text}, state) do
    cmd = "send-keys -t #{state.session_name} \"#{escape(text)}\" Enter\n"
    __MODULE__.OSProcessWorker.write_stdin(self(), cmd)
    {:forward, [], state}
  end

  def handle_downstream(_msg, state), do: {:forward, [], state}

  @impl Esr.OSProcess
  def os_cmd(state) do
    # NOTE: plan originally specified `-d` (detached) after `new-session`, but that
    # causes the control-mode client to emit `%exit` immediately after session
    # creation — so `send_command/2` writes to an already-dead stdin and tmux
    # exits non-zero. For an interactive control-mode session we must stay
    # attached (no `-d`); the session itself is still non-interactive because
    # there is no controlling TTY.
    ["tmux", "-C", "new-session", "-s", state.session_name, "-c", state.dir]
  end

  @impl Esr.OSProcess
  def os_env(_state), do: []

  @impl Esr.OSProcess
  def on_os_exit(0, _state), do: {:stop, :normal}
  def on_os_exit(status, _state), do: {:stop, {:tmux_crashed, status}}

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
