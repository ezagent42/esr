defmodule Esr.OSProcess do
  @moduledoc """
  Composition 底座 for Peers that wrap one OS process.

  **PR-3 migration (2026-04-22):** this module now uses
  [`:erlexec`](https://hexdocs.pm/erlexec/) under the hood. The previous
  `Port.open + muontrap binary wrapper` pattern was replaced because
  erlexec simultaneously provides:

    1. **Native pseudo-terminal (PTY) support** — required by
       `tmux -C` control mode, which on macOS exits immediately when
       spawned without a controlling TTY.
    2. **Bidirectional stdin/stdout** — `:exec.send/2` writes to the
       child's stdin without the muontrap `--capture-output` ack-channel
       constraint (see the historical skill
       `.claude/skills/muontrap-elixir/SKILL.md`).
    3. **BEAM-exit cleanup** — the erlexec C++ port program (`exec-port`)
       kills its children when the BEAM dies, the same way the MuonTrap
       binary did.

  See `docs/notes/erlexec-migration.md` for full rationale.

  ## Wrapper mode

  Pass `wrapper: :pty` or `wrapper: :plain` to `use Esr.OSProcess`.

    * `:pty` — child is spawned with a pseudo-terminal attached. Use
      this for programs that require a controlling TTY (tmux control
      mode, interactive shells, anything that calls `isatty(0)` and
      changes behavior based on it). PTY output is line-buffered with
      `\\r\\n` terminators; we normalize to `\\n` before dispatching.

    * `:plain` — child is spawned without a PTY. Use for pure
      stdin/stdout line-protocol sidecars (JSON-lines, Python RPC,
      anything that already line-buffers its own output). Faster path;
      no terminal state to worry about.

  Both modes support `write_stdin/2`, `os_pid/1`, and `on_terminate/1`
  callbacks. Cleanup on normal termination is handled via
  `:exec.stop/1` (SIGTERM, then SIGKILL after `kill_timeout`).
  Cleanup on BEAM hard-crash is handled by the erlexec port program.

  The worker exposes:
  - `os_pid/1` — fetch the child OS pid
  - `write_stdin/2` — write bytes to child's stdin
  - automatic forwarding of child stdout lines to the Peer via
    `handle_upstream({:os_stdout, line}, state)`

  See spec §3.2.
  """

  @behaviour Esr.Role.State

  @callback os_cmd(state :: term()) :: [String.t()]
  @callback os_env(state :: term()) :: [{String.t(), String.t()}]
  @callback on_os_exit(exit_status :: non_neg_integer(), state :: term()) ::
              {:stop, reason :: term()} | {:restart, new_state :: term()}
  @callback on_terminate(state :: term()) :: :ok
  @callback os_cwd(state :: term()) :: Path.t() | nil

  @optional_callbacks on_terminate: 1, os_cwd: 1

  # Graceful-shutdown window (ms) before erlexec escalates SIGTERM → SIGKILL.
  # Matches the previous muontrap `--delay-to-sigkill 5000` value.
  @default_kill_timeout_ms 5_000

  defmacro __using__(opts) do
    kind = Keyword.fetch!(opts, :kind)
    wrapper = Keyword.get(opts, :wrapper, :plain)

    unless wrapper in [:pty, :plain] do
      raise ArgumentError,
            "Esr.OSProcess: :wrapper must be :pty or :plain, got #{inspect(wrapper)}"
    end

    quote do
      @behaviour Esr.OSProcess
      @os_process_kind unquote(kind)
      @os_process_wrapper unquote(wrapper)

      defmodule OSProcessWorker do
        @moduledoc false
        use GenServer

        def start_link(init_args), do: GenServer.start_link(__MODULE__, init_args)

        def os_pid(pid), do: GenServer.call(pid, :os_pid)
        # 2026-04-30 — exposed for tests / diagnostics in
        # `Esr.Workers.AdapterProcess` / `Esr.Workers.HandlerProcess`,
        # which need to assert "this exec port is dead after BEAM stop".
        def exec_pid(pid), do: GenServer.call(pid, :exec_pid)
        def write_stdin(pid, bytes), do: GenServer.cast(pid, {:write_stdin, bytes})

        @wrapper unquote(wrapper)

        @impl true
        def init(init_args) do
          # T12-comms-3m (2026-04-25): trap exits so the supervisor's
          # shutdown signal reaches our terminate/2 callback, which is
          # what invokes the parent peer's on_terminate (e.g.
          # TmuxProcess.on_terminate → `tmux kill-session`). Without
          # this flag, supervisors terminate us with a plain
          # Process.exit(:shutdown) and terminate/2 never runs —
          # leaving tmux sessions + mcp-config files orphaned after
          # session_end.
          Process.flag(:trap_exit, true)

          parent = __MODULE__ |> Module.split() |> Enum.drop(-1) |> Module.concat()
          {:ok, state} = parent.init(init_args)

          [exe | args] = parent.os_cmd(state)
          env = parent.os_env(state)

          cwd =
            if function_exported?(parent, :os_cwd, 1) do
              parent.os_cwd(state)
            else
              nil
            end

          case Esr.OSProcess.spawn_child(exe, args, env, @wrapper, cwd) do
            {:ok, exec_pid, os_pid} ->
              {:ok,
               %{
                 parent: parent,
                 state: state,
                 exec_pid: exec_pid,
                 os_pid: os_pid,
                 # Line accumulator for stdout. erlexec does not frame
                 # lines for us the way `Port.open` + `{:line, N}` did.
                 stdout_buf: ""
               }}

            {:error, reason} ->
              {:stop, {:os_process_spawn_failed, reason}}
          end
        end

        @impl true
        def handle_call(:os_pid, _from, s), do: {:reply, {:ok, s.os_pid}, s}
        def handle_call(:exec_pid, _from, s), do: {:reply, {:ok, s.exec_pid}, s}

        @impl true
        def handle_cast({:write_stdin, bytes}, s) do
          :ok = :exec.send(s.os_pid, bytes)
          {:noreply, s}
        end

        # ------------------------------------------------------------------
        # erlexec stdout/stderr messages.
        # ------------------------------------------------------------------
        @impl true
        def handle_info({:stdout, os_pid, data}, %{os_pid: os_pid} = s) do
          {lines, rest} = Esr.OSProcess.split_lines(s.stdout_buf <> data)

          new_state =
            Enum.reduce(lines, s, fn line, acc ->
              dispatch_stdout(acc, line)
            end)

          {:noreply, %{new_state | stdout_buf: rest}}
        end

        # erlexec merges stderr into stdout when we pass `{:stderr, :stdout}`;
        # we still catch the bare message shape defensively.
        def handle_info({:stderr, os_pid, data}, %{os_pid: os_pid} = s) do
          {lines, rest} = Esr.OSProcess.split_lines(s.stdout_buf <> data)

          new_state =
            Enum.reduce(lines, s, fn line, acc ->
              dispatch_stdout(acc, line)
            end)

          {:noreply, %{new_state | stdout_buf: rest}}
        end

        # Process exit (monitor option). erlexec encodes the exit reason
        # as `{:exit_status, status}` for abnormal exits or `:normal` for
        # exit code 0.
        def handle_info({:DOWN, os_pid, :process, _pid, reason}, %{os_pid: os_pid} = s) do
          # Flush any trailing buffered line.
          tail = String.trim_trailing(s.stdout_buf, "\n")

          s =
            if tail == "" do
              s
            else
              dispatch_stdout(%{s | stdout_buf: ""}, tail)
            end

          status = Esr.OSProcess.reason_to_status(reason)

          case s.parent.on_os_exit(status, s.state) do
            {:stop, stop_reason} -> {:stop, stop_reason, s}
            {:restart, _new_state} -> {:stop, :restart_not_yet_implemented, s}
          end
        end

        # When using `run_link/2` the owning pid gets an EXIT on abnormal
        # termination instead of (or in addition to) a DOWN. We handle
        # both for resilience.
        def handle_info({:EXIT, exec_pid, reason}, %{exec_pid: exec_pid} = s) do
          status = Esr.OSProcess.reason_to_status(reason)

          case s.parent.on_os_exit(status, s.state) do
            {:stop, stop_reason} -> {:stop, stop_reason, s}
            {:restart, _new_state} -> {:stop, :restart_not_yet_implemented, s}
          end
        end

        # Any other message is treated as a downstream peer event and
        # routed through the parent's `handle_downstream/2` callback.
        # This is the integration path used by upstream peers (e.g.
        # `Esr.Peers.CCProcess`'s `:send_input` action targeted at
        # `Esr.Peers.TmuxProcess`): the upstream peer calls
        # `send(tmux_pid, {:send_input, text})`, and the wrapping
        # OSProcessWorker dispatches the message into
        # `TmuxProcess.handle_downstream/2`, which writes to the child
        # process's stdin. Introduced in P3-10 to unblock the full E2E
        # integration test (and to make the Peer.Stateful contract
        # hold for every OSProcess-backed peer, not just TmuxProcess).
        def handle_info(msg, s) do
          if function_exported?(s.parent, :handle_downstream, 2) do
            case s.parent.handle_downstream(msg, s.state) do
              {:forward, _msgs, new_state} -> {:noreply, %{s | state: new_state}}
              {:drop, _reason, new_state} -> {:noreply, %{s | state: new_state}}
              _other -> {:noreply, s}
            end
          else
            {:noreply, s}
          end
        end

        @impl true
        def terminate(_reason, %{parent: parent, state: state, os_pid: os_pid}) do
          if function_exported?(parent, :on_terminate, 1) do
            try do
              parent.on_terminate(state)
            rescue
              _ -> :ok
            catch
              _, _ -> :ok
            end
          end

          # `:exec.stop/1` does SIGTERM → wait kill_timeout → SIGKILL.
          # We swallow errors because the child may already be gone
          # (e.g. `on_terminate` ran `tmux kill-session` which also
          # kills the client).
          try do
            _ = :exec.stop(os_pid)
          rescue
            _ -> :ok
          catch
            _, _ -> :ok
          end

          :ok
        end

        defp dispatch_stdout(s, line) do
          case s.parent.handle_upstream({:os_stdout, line}, s.state) do
            {:forward, _msgs, new_state} -> %{s | state: new_state}
            {:reply, _msg, new_state} -> %{s | state: new_state}
            {:drop, _reason, new_state} -> %{s | state: new_state}
          end
        end
      end
    end
  end

  # --------------------------------------------------------------------
  # Helpers shared by every generated OSProcessWorker.
  # --------------------------------------------------------------------

  @doc false
  # Build the erlexec options list and spawn. We use `run_link/2` so
  # that if the exec-manager Erlang pid dies abnormally, the owning
  # OSProcessWorker also dies (and vice versa, via the link) —
  # erlexec's built-in OS-process cleanup relies on that linked pid
  # being the lifetime anchor.
  #
  # The command is passed as a list-of-charlists (no shell), which
  # avoids quoting / shell-injection surprises.
  def spawn_child(exe, args, env, wrapper, cwd \\ nil) do
    abs_exe = resolve_exe(exe)

    cmd = [String.to_charlist(abs_exe) | Enum.map(args, &String.to_charlist/1)]

    opts =
      [
        :stdin,
        {:stdout, self()},
        {:stderr, :stdout},
        :monitor,
        {:kill_timeout, div(@default_kill_timeout_ms, 1000)},
        {:env, to_exec_env(env)}
      ]
      |> maybe_add_pty(wrapper)
      |> maybe_add_cwd(cwd)

    case :exec.run_link(cmd, opts) do
      {:ok, pid, os_pid} when is_integer(os_pid) ->
        {:ok, pid, os_pid}

      {:error, _} = err ->
        err
    end
  end

  defp maybe_add_pty(opts, :pty), do: [:pty | opts]
  defp maybe_add_pty(opts, :plain), do: opts

  defp maybe_add_cwd(opts, nil), do: opts

  defp maybe_add_cwd(opts, cwd) when is_binary(cwd) do
    [{:cd, String.to_charlist(cwd)} | opts]
  end

  defp to_exec_env(env) do
    for {k, v} <- env, do: {String.to_charlist(k), String.to_charlist(v)}
  end

  @doc false
  def resolve_exe(exe) do
    cond do
      Path.type(exe) == :absolute ->
        exe

      path = System.find_executable(exe) ->
        path

      true ->
        raise "Esr.OSProcess: executable #{inspect(exe)} not found on PATH"
    end
  end

  @doc """
  Split a chunk of stdout bytes into `{complete_lines, trailing_partial}`.

  Lines include their terminating `\\n`. PTY-origin `\\r\\n` sequences
  are normalized to plain `\\n` (the parser in `TmuxProcess.parse_event/1`
  handles either form, but normalizing keeps logs tidy).

  Used by the generated `OSProcessWorker.handle_info/2` to emulate the
  `{:line, 4096}` framing the old `Port.open` pipeline provided for free.
  """
  @spec split_lines(binary()) :: {[binary()], binary()}
  def split_lines(buf) do
    buf
    |> String.replace("\r\n", "\n")
    |> do_split_lines([], "")
  end

  defp do_split_lines("", acc, rest) do
    {Enum.reverse(acc), rest}
  end

  defp do_split_lines(bin, acc, _rest) do
    case :binary.split(bin, "\n") do
      [last] -> {Enum.reverse(acc), last}
      [line, tail] -> do_split_lines(tail, [line <> "\n" | acc], "")
    end
  end

  @doc """
  Normalize an erlexec DOWN/EXIT `reason` into an integer exit status.

    * `:normal` → `0`
    * `{:exit_status, n}` → `n`
    * anything else → `1` (treated as crash)
  """
  @spec reason_to_status(term()) :: non_neg_integer()
  def reason_to_status(:normal), do: 0
  def reason_to_status({:exit_status, n}) when is_integer(n), do: n
  def reason_to_status(_), do: 1
end
