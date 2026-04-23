defmodule TmuxController do
  @moduledoc """
  A GenServer that owns a long-running `tmux -C` (control-mode) session.

  Responsibilities:

    * Starts `tmux -C new-session -s <name> -c <cwd>` as an OS process via
      `:erlexec`, so that BEAM teardown (even on SIGKILL) guarantees the
      tmux process is killed — `:erlexec` runs a dedicated port-program
      supervisor (`exec-port`) whose death triggers cleanup of all managed
      children.
    * Writes tmux control-protocol commands (plain text + `\n`) to the
      child's stdin.
    * Parses the line-oriented control-mode stream from stdout:

        %begin <time> <num> <flags>
          ... response lines ...
        %end   <time> <num> <flags>
        %error <time> <num> <flags>
          ... error lines ...
        %end   <time> <num> <flags>          (tmux uses %end to close errors too)
        %output %<pane-id> <data>
        %session-changed / %window-add / %unlinked-window-add / ...
        %exit [reason]

    * Correlates each submitted command with its `%begin`/`%end` block via
      the monotonically increasing command number tmux echoes in `%begin`.
    * Emits asynchronous control events (`:output`, `:exit`, `:notification`)
      to a subscriber pid supplied at start time.

  ## Lifecycle guarantees

  `:erlexec` is started with `:monitor` + `kill_timeout` so that:

    1. Normal `GenServer` stop -> we call `:exec.stop(pid)` which sends
       SIGTERM, waits `kill_timeout` seconds, then SIGKILL.
    2. GenServer crash -> the `{:DOWN, ...}` from `:exec`'s monitor is
       irrelevant; `:exec` also monitors *us* (the owner) because we
       started the child from this process, so when we die it kills the
       child automatically.
    3. BEAM SIGKILL / hard VM exit -> `exec-port` (the C supervisor)
       notices its controlling Erlang VM is gone (pipe EOF on stdin) and
       reaps every managed child before exiting. This is why we rely on
       `:erlexec` rather than `Port.open/2` + `:os.cmd/1`: raw ports give
       *no* such guarantee on SIGKILL.

  ## Example

      {:ok, pid} =
        TmuxController.start_link(
          session: "mysession",
          cwd: "/some/dir",
          subscriber: self()
        )

      {:ok, output} = TmuxController.command(pid, "list-windows")
      TmuxController.stop(pid)
  """

  use GenServer
  require Logger

  @default_kill_timeout 5
  @default_command_timeout 5_000

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @type start_opt ::
          {:session, String.t()}
          | {:cwd, String.t()}
          | {:subscriber, pid()}
          | {:tmux_bin, String.t()}
          | {:kill_timeout, non_neg_integer()}
          | {:name, GenServer.name()}

  @spec start_link([start_opt()]) :: GenServer.on_start()
  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name)
    if name, do: GenServer.start_link(__MODULE__, opts, name: name),
    else: GenServer.start_link(__MODULE__, opts)
  end

  @doc """
  Send a tmux control command and synchronously wait for its `%end` block.
  Returns `{:ok, [line]}` on success or `{:error, [line]}` on `%error`.
  """
  @spec command(GenServer.server(), String.t(), timeout()) ::
          {:ok, [String.t()]} | {:error, term()}
  def command(server, cmd, timeout \\ @default_command_timeout) do
    GenServer.call(server, {:command, cmd}, timeout)
  end

  @doc "Fire-and-forget variant — does not wait for the response block."
  @spec send(GenServer.server(), String.t()) :: :ok
  def send(server, cmd), do: GenServer.cast(server, {:send, cmd})

  @doc "Return the OS pid of the tmux process (useful for diagnostics)."
  @spec os_pid(GenServer.server()) :: {:ok, pos_integer()} | {:error, :not_started}
  def os_pid(server), do: GenServer.call(server, :os_pid)

  @doc "Gracefully stop the tmux session and the GenServer."
  @spec stop(GenServer.server(), timeout()) :: :ok
  def stop(server, timeout \\ 10_000), do: GenServer.stop(server, :normal, timeout)

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  defmodule State do
    @moduledoc false
    defstruct [
      :session,
      :cwd,
      :subscriber,
      :tmux_bin,
      :kill_timeout,
      # :erlexec handles
      :exec_pid,
      :os_pid,
      # stdout line-buffer (partial last line)
      buf: "",
      # FSM: :idle | {:in_block, kind, number, from, acc}
      #   kind :: :begin | :error
      mode: :idle,
      # queue of {from, cmd, number} awaiting responses, in FIFO order
      pending: :queue.new(),
      # next expected command number (tmux's own counter is authoritative,
      # we just trust the %begin line to tell us which call to resolve)
      # we keep a map by number for O(1) lookup when %end/%error arrive
      by_number: %{}
    ]
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    session      = Keyword.fetch!(opts, :session)
    cwd          = Keyword.fetch!(opts, :cwd)
    subscriber   = Keyword.get(opts, :subscriber)
    tmux_bin     = Keyword.get(opts, :tmux_bin, "tmux")
    kill_timeout = Keyword.get(opts, :kill_timeout, @default_kill_timeout)

    # Ensure :erlexec is running. It starts its own port-program supervisor
    # (`exec-port`) which is what guarantees child cleanup on BEAM SIGKILL.
    {:ok, _} = Application.ensure_all_started(:erlexec)

    args = [tmux_bin, "-C", "new-session", "-A", "-s", session, "-c", cwd]

    exec_opts = [
      :stdin,
      :stdout,
      :stderr,
      :monitor,
      {:kill_timeout, kill_timeout},
      # Belt-and-braces: send SIGKILL on timeout. `:erlexec` default already
      # escalates, but make it explicit.
      {:kill, "kill -KILL $CHILD_PID"},
      # Run tmux in its own process group so we can signal the whole group.
      :pty_echo,
      {:env, [{"TMUX", false}]}
    ]

    case :exec.run_link(args, exec_opts) do
      {:ok, exec_pid, os_pid} ->
        state = %State{
          session: session,
          cwd: cwd,
          subscriber: subscriber,
          tmux_bin: tmux_bin,
          kill_timeout: kill_timeout,
          exec_pid: exec_pid,
          os_pid: os_pid
        }

        {:ok, state}

      {:error, reason} ->
        {:stop, {:tmux_spawn_failed, reason}}
    end
  end

  @impl true
  def handle_call({:command, cmd}, from, state) do
    # We don't know the command number until tmux echoes %begin. Queue the
    # caller FIFO; the first unassigned entry claims the next %begin.
    new_pending = :queue.in({from, cmd}, state.pending)

    case :exec.send(state.exec_pid, cmd <> "\n") do
      :ok ->
        {:noreply, %State{state | pending: new_pending}}

      {:error, reason} ->
        {:reply, {:error, {:stdin_write_failed, reason}}, state}
    end
  end

  def handle_call(:os_pid, _from, %State{os_pid: nil} = state),
    do: {:reply, {:error, :not_started}, state}

  def handle_call(:os_pid, _from, state), do: {:reply, {:ok, state.os_pid}, state}

  @impl true
  def handle_cast({:send, cmd}, state) do
    _ = :exec.send(state.exec_pid, cmd <> "\n")
    {:noreply, state}
  end

  # ---------------- stdout from tmux -----------------------------------------

  @impl true
  def handle_info({:stdout, os_pid, chunk}, %State{os_pid: os_pid} = state) do
    {lines, rest} = split_lines(state.buf <> chunk)
    state = %State{state | buf: rest}
    state = Enum.reduce(lines, state, &process_line/2)
    {:noreply, state}
  end

  def handle_info({:stderr, os_pid, chunk}, %State{os_pid: os_pid} = state) do
    Logger.debug("tmux[#{state.session}] stderr: #{inspect(chunk)}")
    {:noreply, state}
  end

  # :erlexec monitor: child died
  def handle_info({:DOWN, os_pid, :process, _exec_pid, reason},
                  %State{os_pid: os_pid} = state) do
    notify(state, {:exit, reason})
    {:stop, {:tmux_exited, reason}, %State{state | exec_pid: nil, os_pid: nil}}
  end

  # :exec.run_link also links — if exec_pid dies we get an :EXIT
  def handle_info({:EXIT, exec_pid, reason}, %State{exec_pid: exec_pid} = state) do
    {:stop, {:exec_exited, reason}, %State{state | exec_pid: nil, os_pid: nil}}
  end

  def handle_info(msg, state) do
    Logger.debug("tmux[#{state.session}] unhandled: #{inspect(msg)}")
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, %State{exec_pid: nil}), do: :ok

  def terminate(_reason, %State{exec_pid: exec_pid, kill_timeout: kt}) do
    # Ask tmux to detach cleanly first, then let :erlexec escalate
    # SIGTERM -> SIGKILL per kill_timeout.
    _ = :exec.send(exec_pid, "kill-session\n")
    _ = :exec.stop_and_wait(exec_pid, :timer.seconds(kt + 2))
    :ok
  rescue
    _ -> :ok
  end

  # ---------------------------------------------------------------------------
  # Control-mode parser
  # ---------------------------------------------------------------------------

  # Split a binary into {complete_lines, trailing_partial}. Lines are
  # separated by "\n"; tmux control mode never emits "\r\n".
  defp split_lines(bin) do
    parts = :binary.split(bin, "\n", [:global])
    {complete, [last]} = Enum.split(parts, length(parts) - 1)
    {complete, last}
  end

  # State machine over control-mode lines.
  defp process_line(line, %State{mode: :idle} = state) do
    cond do
      match = parse_begin(line) ->
        {kind, number, _flags} = match
        {from, cmd, pending} = dequeue_caller(state.pending)

        by_number =
          if from do
            Map.put(state.by_number, number, {from, cmd})
          else
            # Unsolicited %begin (shouldn't happen, but be defensive)
            state.by_number
          end

        %State{
          state
          | mode: {:in_block, kind, number, []},
            pending: pending,
            by_number: by_number
        }

      String.starts_with?(line, "%output ") ->
        handle_output(line, state)
        state

      String.starts_with?(line, "%exit") ->
        notify(state, {:exit, String.trim_leading(line, "%exit")})
        state

      String.starts_with?(line, "%") ->
        # %session-changed, %window-add, %unlinked-window-add, etc.
        notify(state, {:notification, line})
        state

      true ->
        # Stray line outside any block — log and ignore.
        Logger.debug("tmux unexpected line: #{inspect(line)}")
        state
    end
  end

  defp process_line(line, %State{mode: {:in_block, kind, number, acc}} = state) do
    case parse_end(line) do
      {:end, ^number, _flags} ->
        reply_kind = if kind == :error, do: :error, else: :ok
        lines = Enum.reverse(acc)

        case Map.pop(state.by_number, number) do
          {{from, _cmd}, by_number} ->
            GenServer.reply(from, {reply_kind, lines})
            %State{state | mode: :idle, by_number: by_number}

          {nil, _} ->
            # No caller — probably an event-driven command. Surface it.
            notify(state, {reply_kind, number, lines})
            %State{state | mode: :idle}
        end

      _ ->
        %State{state | mode: {:in_block, kind, number, [line | acc]}}
    end
  end

  # %begin <time> <number> <flags>
  defp parse_begin(line) do
    with "%" <> rest <- line,
         [tag, _time, num_s, flags] <- String.split(rest, " ", parts: 4),
         tag when tag in ["begin", "error"] <- tag,
         {num, ""} <- Integer.parse(num_s) do
      kind = if tag == "begin", do: :begin, else: :error
      {kind, num, flags}
    else
      _ -> nil
    end
  end

  # %end <time> <number> <flags>    (also closes %error blocks)
  defp parse_end(line) do
    with "%end " <> rest <- line,
         [_time, num_s, flags] <- String.split(rest, " ", parts: 3),
         {num, ""} <- Integer.parse(num_s) do
      {:end, num, flags}
    else
      _ -> nil
    end
  end

  defp dequeue_caller(queue) do
    case :queue.out(queue) do
      {{:value, {from, cmd}}, rest} -> {from, cmd, rest}
      {:empty, _} -> {nil, nil, queue}
    end
  end

  defp handle_output(line, state) do
    # "%output %<pane-id> <data...>"
    case String.split(line, " ", parts: 3) do
      ["%output", pane, data] ->
        notify(state, {:output, pane, decode_output(data)})

      _ ->
        :ok
    end
  end

  # tmux escapes \ and non-printable bytes as \xxx octal.
  defp decode_output(bin), do: decode_output(bin, <<>>)
  defp decode_output(<<>>, acc), do: acc

  defp decode_output(<<?\\, a, b, c, rest::binary>>, acc)
       when a in ?0..?7 and b in ?0..?7 and c in ?0..?7 do
    byte = (a - ?0) * 64 + (b - ?0) * 8 + (c - ?0)
    decode_output(rest, <<acc::binary, byte>>)
  end

  defp decode_output(<<ch, rest::binary>>, acc),
    do: decode_output(rest, <<acc::binary, ch>>)

  defp notify(%State{subscriber: nil}, _msg), do: :ok
  defp notify(%State{subscriber: pid}, msg) when is_pid(pid), do: Kernel.send(pid, {:tmux, msg})
end
