defmodule VoiceAsrSidecar do
  @moduledoc """
  GenServer wrapper around `python -m my_app.voice_asr` using erlexec (~> 2.2).

  Protocol
  --------
  * stdin:  line-delimited JSON requests (one JSON object per `\\n`-terminated line).
  * stdout: line-delimited JSON replies (same framing).
  * stderr: merged into stdout for simpler log capture; parse errors on stdout
    lines that are not valid JSON are logged and dropped.

  Lifecycle
  ---------
  * Started via `:exec.run_link/2`, so the child OS process is linked to this
    GenServer's Erlang-side exec pid. When the GenServer exits (normal, crash,
    or `Process.exit(pid, :kill)`), erlexec's `exec-port` helper reaps the
    child: SIGTERM → `kill_timeout` seconds → SIGKILL.
  * When the BEAM itself is SIGKILL-ed, `exec-port` (child of the BEAM) notices
    the parent death and reaps every child it spawned. No orphans, even on
    macOS where `PR_SET_PDEATHSIG` is unavailable.
  * `:monitor` is set so we also get `{:DOWN, os_pid, :process, _, reason}` if
    the child dies on its own — we translate that into a GenServer `:stop` so
    supervisors can decide what to do.

  Caller API
  ----------
  * `start_link/1` — keyword opts:
      * `:name`        — optional GenServer name.
      * `:subscriber`  — pid that receives `{:asr_reply, map}` messages.
                        Defaults to the starter pid.
      * `:python`      — executable (default `"python"`); override to pin
                        a venv interpreter.
      * `:module`      — python `-m` target (default `"my_app.voice_asr"`).
      * `:extra_args`  — list of additional argv strings appended after `-m <module>`.
      * `:env`         — list of `{binary, binary}` env overrides.
      * `:cd`          — working directory (binary path) or `nil`.
      * `:kill_timeout` — seconds for SIGTERM→SIGKILL. Default 5.
  * `send_request/2` — cast a map; it is JSON-encoded and written with a
    trailing `\\n`.
  * `os_pid/1` — returns the kernel-level pid (useful for `ps` assertions in
    tests).

  Why no `:pty`
  -------------
  The Python sidecar is a line-oriented JSON protocol, not an interactive
  tool that calls `isatty()`. Allocating a PTY would translate `\\n` to
  `\\r\\n` on stdout (making line parsing fragile) and buffer oddly. Plain
  pipes are correct here — we just need Python to flush (see `PYTHONUNBUFFERED`
  below).
  """

  use GenServer
  require Logger

  @type reply :: map()

  # ---------- Public API ----------

  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name)
    gen_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @doc """
  Send a JSON-encodable map to the sidecar's stdin as a single line.
  """
  @spec send_request(GenServer.server(), map()) :: :ok
  def send_request(server, %{} = request) do
    GenServer.cast(server, {:send_request, request})
  end

  @doc "Return `{:ok, os_pid}` — the kernel-level PID of the python child."
  @spec os_pid(GenServer.server()) :: {:ok, non_neg_integer()}
  def os_pid(server), do: GenServer.call(server, :os_pid)

  # ---------- GenServer callbacks ----------

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    # :exec.start/0 is idempotent. Safe even if :erlexec is already started
    # via `extra_applications` in mix.exs.
    case :exec.start() do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    python       = Keyword.get(opts, :python, "python")
    module       = Keyword.get(opts, :module, "my_app.voice_asr")
    extra_args   = Keyword.get(opts, :extra_args, [])
    env          = Keyword.get(opts, :env, [])
    cd           = Keyword.get(opts, :cd)
    kill_timeout = Keyword.get(opts, :kill_timeout, 5)
    subscriber   = Keyword.get(opts, :subscriber, self())

    # erlexec accepts either a single charlist command or a list of argv
    # charlists. Argv form avoids shell quoting issues.
    cmd =
      [python, "-m", module | extra_args]
      |> Enum.map(&String.to_charlist/1)

    exec_opts =
      [
        :stdin,
        :stdout,
        {:stderr, :stdout},
        :monitor,
        {:kill_timeout, kill_timeout},
        # Force Python to flush on every newline. Without this the child can
        # buffer stdout in 4 KiB chunks and replies arrive late — or only at
        # child exit. Charlists required by erlexec.
        {:env, build_env(env)}
      ]
      |> maybe_put_cd(cd)

    case :exec.run_link(cmd, exec_opts) do
      {:ok, exec_pid, os_pid} ->
        state = %{
          exec_pid: exec_pid,
          os_pid: os_pid,
          subscriber: subscriber,
          buffer: ""
        }

        Logger.info(
          "VoiceAsrSidecar started os_pid=#{os_pid} cmd=#{inspect(cmd)}"
        )

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
  def handle_cast({:send_request, request}, %{os_pid: os_pid} = state) do
    case Jason.encode(request) do
      {:ok, json} ->
        # erlexec takes iodata. Append a newline for line framing.
        :ok = :exec.send(os_pid, [json, ?\n])
        {:noreply, state}

      {:error, reason} ->
        Logger.error(
          "VoiceAsrSidecar: failed to encode request: #{inspect(reason)}"
        )

        {:noreply, state}
    end
  end

  @impl true
  def handle_info(
        {:stdout, os_pid, bytes},
        %{os_pid: os_pid, buffer: buf} = state
      ) do
    {lines, new_buf} = split_lines(buf <> bytes)
    Enum.each(lines, &dispatch_line(&1, state))
    {:noreply, %{state | buffer: new_buf}}
  end

  # Stderr was merged into stdout via `{:stderr, :stdout}`, but guard anyway
  # in case that option is ever removed.
  def handle_info({:stderr, os_pid, bytes}, %{os_pid: os_pid} = state) do
    Logger.warning("VoiceAsrSidecar[#{os_pid}] stderr: #{inspect(bytes)}")
    {:noreply, state}
  end

  def handle_info(
        {:DOWN, os_pid, :process, _pid, reason},
        %{os_pid: os_pid} = state
      ) do
    Logger.info("VoiceAsrSidecar: child os_pid=#{os_pid} exited: #{inspect(reason)}")
    {:stop, normalize_reason(reason), state}
  end

  # `run_link` also delivers an :EXIT from the exec-side Erlang pid on child
  # death. Swallow it — we already handle :DOWN.
  def handle_info({:EXIT, exec_pid, _reason}, %{exec_pid: exec_pid} = state) do
    {:noreply, state}
  end

  def handle_info(msg, state) do
    Logger.debug("VoiceAsrSidecar: unhandled info #{inspect(msg)}")
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, %{os_pid: os_pid}) do
    # Best-effort graceful stop. `run_link` guarantees eventual reaping, but
    # calling :exec.stop here speeds it up and lets the child respond to
    # SIGTERM (flush buffers, etc.) before SIGKILL after kill_timeout.
    _ = :exec.stop(os_pid)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  # ---------- Helpers ----------

  defp build_env(user_env) do
    # PYTHONUNBUFFERED=1 is critical; without it Python block-buffers stdout
    # when stdout is not a TTY and replies arrive in bursts or never.
    defaults = [{"PYTHONUNBUFFERED", "1"}]

    (defaults ++ user_env)
    # Later entries override earlier ones by rebuilding via a map.
    |> Enum.reduce(%{}, fn {k, v}, acc -> Map.put(acc, to_string(k), to_string(v)) end)
    |> Enum.map(fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)
  end

  defp maybe_put_cd(opts, nil), do: opts
  defp maybe_put_cd(opts, cd) when is_binary(cd), do: [{:cd, String.to_charlist(cd)} | opts]

  defp split_lines(bytes) do
    case String.split(bytes, "\n") do
      [only] -> {[], only}
      parts -> {Enum.drop(parts, -1), List.last(parts)}
    end
  end

  defp dispatch_line("", _state), do: :ok

  defp dispatch_line(line, %{subscriber: subscriber}) do
    # Strip a trailing \r in case the child emits CRLF.
    trimmed = String.trim_trailing(line, "\r")

    case Jason.decode(trimmed) do
      {:ok, %{} = reply} ->
        send(subscriber, {:asr_reply, reply})

      {:ok, other} ->
        Logger.warning(
          "VoiceAsrSidecar: non-object JSON line: #{inspect(other)}"
        )

      {:error, reason} ->
        Logger.warning(
          "VoiceAsrSidecar: non-JSON stdout line " <>
            "(#{inspect(reason)}): #{inspect(trimmed)}"
        )
    end
  end

  defp normalize_reason(:normal), do: :normal
  defp normalize_reason({:exit_status, 0}), do: :normal
  defp normalize_reason(other), do: {:child_exited, other}
end
