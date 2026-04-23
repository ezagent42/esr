defmodule TmuxController do
  @moduledoc """
  GenServer wrapper around a long-running `tmux -C new-session` (control-mode)
  process.

  Responsibilities
  ---------------
    * Spawn `tmux -C new-session -s <name> -c <cwd>` under a PTY so the tmux
      client does not short-circuit on `isatty()` and immediately emit `%exit`.
    * Send control-protocol commands into tmux via stdin
      (`send_command/2`, `send_raw/2`).
    * Parse the control-mode line protocol on stdout — `%begin`, `%end`,
      `%error`, `%output`, `%exit`, `%session-changed`, `%window-...`,
      etc. — and forward structured events to a subscriber pid.
    * Guarantee the child `tmux` process dies when this GenServer (or the
      entire BEAM, including on SIGKILL) goes away. This is delegated to
      `:exec.run_link/2` + the bundled `exec-port` supervisor.

  See `approach.md` next to this file for why each erlexec option was
  picked.
  """

  use GenServer
  require Logger

  @type event ::
          {:begin, number :: integer(), time :: integer(), flags :: integer()}
          | {:end, number :: integer(), time :: integer(), flags :: integer(),
             payload :: [String.t()]}
          | {:error, number :: integer(), time :: integer(), flags :: integer(),
             payload :: [String.t()]}
          | {:output, pane_id :: String.t(), data :: String.t()}
          | {:exit, reason :: String.t() | nil}
          | {:notification, name :: String.t(), args :: [String.t()]}
          | {:raw, String.t()}

  # --------------------------------------------------------------------------
  # Public API
  # --------------------------------------------------------------------------

  @doc """
  Start a tmux control-mode session.

  Options:
    * `:session`    — tmux session name (required)
    * `:cwd`        — working directory for tmux (required)
    * `:subscriber` — pid to receive `{:tmux_event, ref, event()}` messages.
                     Defaults to the caller.
    * `:tmux`       — path to the tmux binary. Defaults to `"tmux"`.
    * `:env`        — extra `{binary, binary}` env pairs (converted to
                     charlists internally).
    * `:kill_timeout` — seconds between SIGTERM and SIGKILL on graceful
                     shutdown. Defaults to `5`.
    * `:name`       — optional registered name for the GenServer.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name)
    if name, do: GenServer.start_link(__MODULE__, opts, name: name),
             else: GenServer.start_link(__MODULE__, opts)
  end

  @doc """
  Send a tmux control-protocol command. A trailing `\\n` is appended if
  missing. Returns `:ok` (fire-and-forget; parse the `%begin/%end/%error`
  pair on the subscriber side to pair responses to commands).
  """
  @spec send_command(GenServer.server(), iodata()) :: :ok
  def send_command(server, command) do
    GenServer.cast(server, {:send_command, command})
  end

  @doc """
  Send arbitrary bytes on stdin with no framing. Useful for raw keystrokes
  or when you want full control over line endings.
  """
  @spec send_raw(GenServer.server(), iodata()) :: :ok
  def send_raw(server, bytes) do
    GenServer.cast(server, {:send_raw, bytes})
  end

  @doc """
  Return the OS pid of the tmux child. Handy for tests that need to poll
  `ps` after tearing the owner down.
  """
  @spec os_pid(GenServer.server()) :: {:ok, non_neg_integer()}
  def os_pid(server), do: GenServer.call(server, :os_pid)

  @doc """
  Ask tmux to shut down gracefully (sends `kill-session`, then lets
  `:exec.stop/1` follow up with SIGTERM → `kill_timeout` → SIGKILL).
  """
  @spec stop(GenServer.server()) :: :ok
  def stop(server), do: GenServer.stop(server, :normal)

  # --------------------------------------------------------------------------
  # GenServer callbacks
  # --------------------------------------------------------------------------

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    session = Keyword.fetch!(opts, :session)
    cwd = Keyword.fetch!(opts, :cwd)
    subscriber = Keyword.get(opts, :subscriber, self())
    tmux_bin = Keyword.get(opts, :tmux, "tmux")
    env = Keyword.get(opts, :env, [])
    kill_timeout = Keyword.get(opts, :kill_timeout, 5)

    # :exec.start/0 is idempotent — safe even if application already booted it.
    case :exec.start() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    cmd = build_cmd(tmux_bin, session, cwd)

    exec_opts = [
      :stdin,
      :stdout,
      {:stderr, :stdout},
      :monitor,
      :pty,
      {:kill_timeout, kill_timeout},
      {:env, env_to_charlists(env)}
    ]

    case :exec.run_link(cmd, exec_opts) do
      {:ok, exec_pid, os_pid} ->
        ref = make_ref()

        state = %{
          exec_pid: exec_pid,
          os_pid: os_pid,
          subscriber: subscriber,
          subscriber_ref: ref,
          session: session,
          buffer: "",
          # stack of %begin frames waiting for %end/%error payloads
          pending: []
        }

        # Hand the subscriber a ref they can match on.
        send(subscriber, {:tmux_ready, ref, os_pid})
        {:ok, state}

      {:error, reason} ->
        {:stop, {:exec_failed, reason}}
    end
  end

  @impl true
  def handle_call(:os_pid, _from, %{os_pid: os_pid} = state) do
    {:reply, {:ok, os_pid}, state}
  end

  @impl true
  def handle_cast({:send_command, command}, %{os_pid: os_pid} = state) do
    :ok = :exec.send(os_pid, ensure_trailing_newline(command))
    {:noreply, state}
  end

  def handle_cast({:send_raw, bytes}, %{os_pid: os_pid} = state) do
    :ok = :exec.send(os_pid, bytes)
    {:noreply, state}
  end

  @impl true
  def handle_info({:stdout, os_pid, bytes}, %{os_pid: os_pid, buffer: buf} = state) do
    {lines, rest} = split_lines(buf <> normalize_crlf(bytes))
    new_state = Enum.reduce(lines, %{state | buffer: rest}, &handle_line/2)
    {:noreply, new_state}
  end

  # erlexec posts both {:DOWN, os_pid, :process, pid, reason} (because we set
  # :monitor) and {:EXIT, exec_pid, reason} (because run_link links).
  # We handle both — whichever arrives first stops us.
  def handle_info({:DOWN, os_pid, :process, _pid, reason}, %{os_pid: os_pid} = state) do
    emit(state, {:exit, inspect(reason)})
    {:stop, {:child_exited, reason}, state}
  end

  def handle_info({:EXIT, exec_pid, reason}, %{exec_pid: exec_pid} = state) do
    emit(state, {:exit, inspect(reason)})
    {:stop, {:child_exited, reason}, state}
  end

  # Late / duplicate exec messages after we've started shutting down.
  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{os_pid: os_pid}) do
    # Best-effort graceful tmux shutdown. `run_link` already guarantees the
    # OS process will die with us via exec-port, but asking tmux to kill its
    # own session first is cleaner when clients are still attached.
    _ = try_send(os_pid, "kill-session\n")
    _ = safe_stop(os_pid)
    :ok
  end

  # --------------------------------------------------------------------------
  # Internal: command assembly
  # --------------------------------------------------------------------------

  # Pass the command as a single charlist — erlexec will run it via
  # `/bin/sh -c ...`, which means flag quoting is up to us. We keep the
  # inputs small and OS-path-like so naive quoting is safe.
  defp build_cmd(tmux_bin, session, cwd) do
    ~c"#{tmux_bin} -C new-session -A -s #{shell_quote(session)} -c #{shell_quote(cwd)}"
  end

  defp shell_quote(s) when is_binary(s) do
    # Single-quote and escape embedded quotes. Cheap + safe for normal
    # session names and paths.
    "'" <> String.replace(s, "'", ~S('\'')) <> "'"
  end

  defp env_to_charlists(env) do
    for {k, v} <- env, do: {to_charlist_safe(k), to_charlist_safe(v)}
  end

  defp to_charlist_safe(s) when is_binary(s), do: String.to_charlist(s)
  defp to_charlist_safe(s) when is_list(s), do: s

  defp ensure_trailing_newline(data) do
    bin = IO.iodata_to_binary(data)
    if String.ends_with?(bin, "\n"), do: bin, else: bin <> "\n"
  end

  # --------------------------------------------------------------------------
  # Internal: stdout framing
  # --------------------------------------------------------------------------

  defp normalize_crlf(bytes), do: String.replace(bytes, "\r\n", "\n")

  defp split_lines(buf) do
    case String.split(buf, "\n") do
      [only] -> {[], only}
      parts -> {Enum.drop(parts, -1), List.last(parts)}
    end
  end

  # --------------------------------------------------------------------------
  # Internal: tmux control-mode protocol parser
  #
  # Minimal parser for the documented event shapes. Anything we don't
  # recognise is forwarded as `{:raw, line}` so the subscriber still sees
  # the traffic.
  # --------------------------------------------------------------------------

  # %begin <number> <time> <flags>
  defp handle_line("%begin " <> rest, state) do
    case parse_header(rest) do
      {:ok, number, time, flags} ->
        frame = %{number: number, time: time, flags: flags, lines: [], tag: :begin}
        emit(state, {:begin, number, time, flags})
        %{state | pending: [frame | state.pending]}

      :error ->
        emit(state, {:raw, "%begin " <> rest})
        state
    end
  end

  defp handle_line("%end " <> rest, state), do: close_frame(:end, rest, state)
  defp handle_line("%error " <> rest, state), do: close_frame(:error, rest, state)

  # %output %<pane-id> <data...>
  defp handle_line("%output " <> rest, state) do
    case String.split(rest, " ", parts: 2) do
      [pane_id, data] ->
        emit(state, {:output, pane_id, unescape_output(data)})

      [pane_id] ->
        emit(state, {:output, pane_id, ""})
    end

    state
  end

  defp handle_line("%exit" <> rest, state) do
    reason =
      case String.trim_leading(rest) do
        "" -> nil
        other -> other
      end

    emit(state, {:exit, reason})
    state
  end

  # Generic `%notification arg1 arg2 ...` (session-changed, window-add,
  # window-close, unlinked-window-add, client-detached, etc.).
  defp handle_line("%" <> rest, state) do
    case String.split(rest, " ") do
      [name | args] -> emit(state, {:notification, name, args})
      [] -> emit(state, {:raw, "%" <> rest})
    end

    state
  end

  # Non-event lines land here only when they appear OUTSIDE a %begin/%end
  # block. Inside a block they're captured as payload (see payload accumulation
  # below).
  defp handle_line(line, %{pending: [frame | rest_pending]} = state) do
    frame = %{frame | lines: [line | frame.lines]}
    %{state | pending: [frame | rest_pending]}
  end

  defp handle_line(line, state) do
    emit(state, {:raw, line})
    state
  end

  defp close_frame(kind, rest, %{pending: [frame | rest_pending]} = state)
       when kind in [:end, :error] do
    payload = Enum.reverse(frame.lines)

    event =
      case parse_header(rest) do
        {:ok, number, time, flags} -> {kind, number, time, flags, payload}
        :error -> {kind, frame.number, frame.time, frame.flags, payload}
      end

    emit(state, event)
    %{state | pending: rest_pending}
  end

  defp close_frame(kind, rest, state) do
    # Unexpected close without a matching begin — surface it as raw.
    emit(state, {:raw, "%#{kind} " <> rest})
    state
  end

  defp parse_header(rest) do
    with [a, b, c] <- String.split(rest, " ", parts: 3),
         {n, ""} <- Integer.parse(a),
         {t, ""} <- Integer.parse(b),
         {f, ""} <- Integer.parse(String.trim(c)) do
      {:ok, n, t, f}
    else
      _ -> :error
    end
  end

  # tmux control mode escapes embedded \n / \r / \\ inside %output payloads
  # as octal sequences (\012, \015, \134). Decode them so subscribers see
  # the real bytes.
  defp unescape_output(data) do
    Regex.replace(~r/\\([0-7]{3})/, data, fn _, oct ->
      <<String.to_integer(oct, 8)>>
    end)
  end

  # --------------------------------------------------------------------------
  # Internal: subscriber I/O + defensive exec helpers
  # --------------------------------------------------------------------------

  defp emit(%{subscriber: sub, subscriber_ref: ref}, event) do
    send(sub, {:tmux_event, ref, event})
  end

  defp try_send(os_pid, bytes) do
    try do
      :exec.send(os_pid, bytes)
    catch
      _, _ -> :ok
    end
  end

  defp safe_stop(os_pid) do
    try do
      :exec.stop(os_pid)
    catch
      _, _ -> :ok
    end
  end
end
