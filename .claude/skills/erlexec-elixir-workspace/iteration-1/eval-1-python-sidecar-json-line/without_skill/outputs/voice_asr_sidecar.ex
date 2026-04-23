defmodule VoiceAsrSidecar do
  @moduledoc """
  GenServer that wraps a Python sidecar (`python -m my_app.voice_asr`) using
  erlexec. Provides line-delimited JSON request/response over the sidecar's
  stdin/stdout.

  Key properties:

    * Requests are queued FIFO and correlated to replies in order of arrival
      (the sidecar is assumed to reply once per request in order). If the
      sidecar supports request ids, pass them in the payload and prefer the
      `call_with_id/2` variant.
    * stderr from the sidecar is captured and logged at `:warn` level.
    * OS-level lifetime is tied to the BEAM process via erlexec's port program
      (`exec-port`), which is the parent of the child and kills it when the
      BEAM dies — including SIGKILL of the BEAM. See erlexec's "pid file" and
      port-driver guarantees.
    * On normal GenServer termination we send SIGTERM, then SIGKILL after a
      grace period.

  ## mix.exs

      defp deps do
        [
          {:erlexec, "~> 2.2"},
          {:jason, "~> 1.4"}
        ]
      end

  ## Usage

      {:ok, pid} = VoiceAsrSidecar.start_link(name: :asr)
      {:ok, %{"text" => "..."}} = VoiceAsrSidecar.call(:asr, %{op: "transcribe", audio: "..."})
      :ok = GenServer.stop(:asr)
  """

  use GenServer
  require Logger

  @type request :: map()
  @type response :: {:ok, map()} | {:error, term()}

  # ---------------------------------------------------------------------------
  # Client API
  # ---------------------------------------------------------------------------

  @doc """
  Start the sidecar supervisor-friendly.

  Options:

    * `:name`          - GenServer name (default: `__MODULE__`)
    * `:cmd`           - command list (default: `["python", "-m", "my_app.voice_asr"]`)
    * `:cd`            - working directory for the child (optional)
    * `:env`           - list of `{"KEY", "VALUE"}` env pairs (optional)
    * `:call_timeout`  - default 5_000 ms
    * `:stop_grace_ms` - SIGTERM-before-SIGKILL grace (default: 2_000)
  """
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Send a JSON request and await the next JSON reply.
  """
  @spec call(GenServer.server(), request(), timeout()) :: response()
  def call(server \\ __MODULE__, payload, timeout \\ 5_000) when is_map(payload) do
    GenServer.call(server, {:request, payload}, timeout)
  end

  @doc """
  Fire-and-forget: send a JSON line to the sidecar, don't wait for reply.
  """
  @spec cast(GenServer.server(), request()) :: :ok
  def cast(server \\ __MODULE__, payload) when is_map(payload) do
    GenServer.cast(server, {:push, payload})
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(opts) do
    # Trap exits so terminate/2 runs and we can shut the child down cleanly.
    Process.flag(:trap_exit, true)

    # Make sure erlexec is started. When used under a real supervision tree,
    # include :erlexec in your application's extra_applications — this is a
    # belt-and-braces fallback.
    {:ok, _} = ensure_erlexec_started()

    cmd         = Keyword.get(opts, :cmd, ["python", "-m", "my_app.voice_asr"])
    cd          = Keyword.get(opts, :cd)
    env         = Keyword.get(opts, :env, [])
    grace_ms    = Keyword.get(opts, :stop_grace_ms, 2_000)

    exec_opts =
      [
        :stdin,             # we will write to child's stdin
        :stdout,            # capture child's stdout, delivered as messages
        :stderr,            # capture child's stderr, delivered as messages
        :monitor,           # get a {:DOWN, ...} when the child dies
        # Critical for lifecycle: when the BEAM/owner dies, SIGTERM the child
        # then SIGKILL after `kill_timeout` seconds. erlexec's port program
        # (exec-port) is the child's parent and survives BEAM SIGKILL long
        # enough to reap. Setting `kill_timeout` bounds that.
        {:kill_timeout, max(div(grace_ms, 1000), 1)},
        # If Python ignores SIGTERM, erlexec will SIGKILL it after the timeout.
        # (no custom :kill script — default behavior is SIGTERM then SIGKILL.)
        :pty_echo  # harmless; omit if you see issues. Remove if Python is confused by a tty.
      ]
      |> maybe_put(cd && {:cd, to_charlist(cd)})
      |> maybe_put(env != [] && {:env, Enum.map(env, fn {k, v} -> {to_charlist(k), to_charlist(v)} end)})
      # Remove :pty_echo — we want raw pipe semantics for line-delimited JSON.
      |> List.delete(:pty_echo)

    # erlexec expects a charlist command or an argv list of charlists.
    cmd_argv = Enum.map(cmd, &to_charlist/1)

    case :exec.run_link(cmd_argv, exec_opts) do
      {:ok, pid, os_pid} ->
        Logger.info("voice_asr sidecar started pid=#{inspect(pid)} os_pid=#{os_pid}")

        state = %{
          exec_pid:      pid,
          os_pid:        os_pid,
          pending:       :queue.new(),  # FIFO of {from, monotonic_ms}
          stdout_buf:    "",
          stderr_buf:    "",
          grace_ms:      grace_ms,
          shutting_down: false
        }

        {:ok, state}

      {:error, reason} ->
        {:stop, {:sidecar_spawn_failed, reason}}
    end
  end

  # ---- synchronous request ---------------------------------------------------

  @impl true
  def handle_call({:request, payload}, from, state) do
    case encode_line(payload) do
      {:ok, line} ->
        case :exec.send(state.exec_pid, line) do
          :ok ->
            pending = :queue.in(from, state.pending)
            {:noreply, %{state | pending: pending}}

          {:error, reason} ->
            {:reply, {:error, {:stdin_send_failed, reason}}, state}
        end

      {:error, reason} ->
        {:reply, {:error, {:encode_failed, reason}}, state}
    end
  end

  # ---- fire-and-forget -------------------------------------------------------

  @impl true
  def handle_cast({:push, payload}, state) do
    case encode_line(payload) do
      {:ok, line} ->
        _ = :exec.send(state.exec_pid, line)
        {:noreply, state}

      {:error, reason} ->
        Logger.warning("voice_asr encode failed: #{inspect(reason)}")
        {:noreply, state}
    end
  end

  # ---- stdout from child (line-delimited JSON) ------------------------------

  @impl true
  def handle_info({:stdout, os_pid, data}, %{os_pid: os_pid} = state) do
    {lines, rest} = split_lines(state.stdout_buf <> data)
    state = Enum.reduce(lines, state, &deliver_line/2)
    {:noreply, %{state | stdout_buf: rest}}
  end

  # ---- stderr from child ----------------------------------------------------

  def handle_info({:stderr, os_pid, data}, %{os_pid: os_pid} = state) do
    {lines, rest} = split_lines(state.stderr_buf <> data)
    Enum.each(lines, fn line ->
      Logger.warning("[voice_asr stderr] #{line}")
    end)
    {:noreply, %{state | stderr_buf: rest}}
  end

  # ---- child process exited --------------------------------------------------

  def handle_info({:DOWN, os_pid, :process, _exec_pid, reason}, %{os_pid: os_pid} = state) do
    # Fail any in-flight callers so they don't hang.
    fail_pending(state.pending, {:sidecar_down, reason})
    {:stop, normal_or_error(reason, state), %{state | pending: :queue.new()}}
  end

  # erlexec may also deliver an {:EXIT, ...} or a plain :EXIT when :monitor is set;
  # handle defensively.
  def handle_info({:EXIT, pid, reason}, %{exec_pid: pid} = state) do
    fail_pending(state.pending, {:sidecar_exit, reason})
    {:stop, normal_or_error(reason, state), state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ---- clean shutdown --------------------------------------------------------

  @impl true
  def terminate(_reason, %{shutting_down: true}), do: :ok

  def terminate(_reason, state) do
    # Tell the child to exit cleanly: close stdin, then SIGTERM, fall back to
    # SIGKILL. erlexec's :exec.stop/1 performs the escalation using the
    # kill_timeout we set at spawn time.
    _ = :exec.send(state.exec_pid, :eof)
    _ = :exec.stop(state.exec_pid)
    fail_pending(state.pending, :shutdown)
    :ok
  end

  # ---------------------------------------------------------------------------
  # Internals
  # ---------------------------------------------------------------------------

  defp encode_line(payload) do
    case Jason.encode(payload) do
      {:ok, json}     -> {:ok, json <> "\n"}
      {:error, _} = e -> e
    end
  end

  # Split a binary buffer into complete "\n"-terminated lines + remainder.
  defp split_lines(buf) do
    parts = :binary.split(buf, "\n", [:global])
    # Last element is the incomplete tail (or "" when buf ended with "\n").
    {complete, [rest]} = Enum.split(parts, length(parts) - 1)
    {complete, rest}
  end

  defp deliver_line(line, %{pending: pending} = state) do
    case Jason.decode(line) do
      {:ok, msg} ->
        case :queue.out(pending) do
          {{:value, from}, rest} ->
            GenServer.reply(from, {:ok, msg})
            %{state | pending: rest}

          {:empty, _} ->
            # Unsolicited event from the sidecar. Log it. A real impl might
            # forward via PubSub or to a registered subscriber process.
            Logger.info("[voice_asr unsolicited] #{inspect(msg)}")
            state
        end

      {:error, reason} ->
        Logger.warning("[voice_asr bad json] #{inspect(reason)}: #{inspect(line)}")
        state
    end
  end

  defp fail_pending(pending, reason) do
    pending
    |> :queue.to_list()
    |> Enum.each(&GenServer.reply(&1, {:error, reason}))
  end

  defp normal_or_error({:exit_status, 0}, _),        do: :normal
  defp normal_or_error(:normal, _),                  do: :normal
  defp normal_or_error(other, _state),               do: {:sidecar_terminated, other}

  defp maybe_put(list, false),     do: list
  defp maybe_put(list, nil),       do: list
  defp maybe_put(list, kv),        do: [kv | list]

  defp ensure_erlexec_started do
    case Application.ensure_all_started(:erlexec) do
      {:ok, _} = ok -> ok
      {:error, _} = err -> err
    end
  end
end
