defmodule Esr.OSProcess do
  @moduledoc """
  Composition底座 for Peers that wrap one OS process.

  A Peer that uses `Esr.OSProcess` gains an embedded worker module
  (`<PeerModule>.OSProcessWorker`) which opens a `Port` to the target
  program. By default the Port is wrapped through the `muontrap` binary
  for guaranteed cleanup on BEAM exit (cgroup on Linux, equivalent
  mechanism on macOS).

  ## Wrapper mode

  Pass `wrapper: :muontrap` (default) or `wrapper: :none` to `use Esr.OSProcess`.

    * `:muontrap` — long-running daemon; stdout captured via flow-controlled
      pipe. Cleanup guaranteed. Not suitable when the Peer needs to write
      application data to the child's stdin — muontrap's `--capture-output`
      consumes its own stdin for byte acknowledgments (see muontrap c_src/
      muontrap.c). If you need stdin + stdout, use `:none`.

    * `:none` — plain `Port.open/2` on the target binary. Supports stdin
      writes and line-buffered stdout. Does NOT guarantee cleanup on BEAM
      SIGKILL (the child may orphan). Appropriate for children that own
      their own supervision (e.g. `tmux` sessions whose lifecycle is managed
      by `tmux kill-session`, or sidecars with their own health-checks).

  The worker exposes:
  - `os_pid/1` — fetch the child OS pid
  - `write_stdin/2` — write bytes to child's stdin
  - automatic forwarding of child stdout lines to the Peer via
    `handle_upstream({:os_stdout, line}, state)`

  See spec §3.2.
  """

  @callback os_cmd(state :: term()) :: [String.t()]
  @callback os_env(state :: term()) :: [{String.t(), String.t()}]
  @callback on_os_exit(exit_status :: non_neg_integer(), state :: term()) ::
              {:stop, reason :: term()} | {:restart, new_state :: term()}

  defmacro __using__(opts) do
    kind = Keyword.fetch!(opts, :kind)
    wrapper = Keyword.get(opts, :wrapper, :muontrap)

    unless wrapper in [:muontrap, :none] do
      raise ArgumentError,
            "Esr.OSProcess: :wrapper must be :muontrap or :none, got #{inspect(wrapper)}"
    end

    open_port_ast = open_port_ast(wrapper)
    resolve_exe_ast = resolve_exe_ast(wrapper)

    quote do
      @behaviour Esr.OSProcess
      @os_process_kind unquote(kind)
      @os_process_wrapper unquote(wrapper)

      defmodule OSProcessWorker do
        @moduledoc false
        use GenServer

        def start_link(init_args), do: GenServer.start_link(__MODULE__, init_args)

        def os_pid(pid), do: GenServer.call(pid, :os_pid)
        def write_stdin(pid, bytes), do: GenServer.cast(pid, {:write_stdin, bytes})

        @impl true
        def init(init_args) do
          parent = __MODULE__ |> Module.split() |> Enum.drop(-1) |> Module.concat()
          {:ok, state} = parent.init(init_args)

          [exe | args] = parent.os_cmd(state)
          env = parent.os_env(state)

          port = open_port(exe, args, env)

          os_pid =
            case Port.info(port, :os_pid) do
              {:os_pid, pid} -> pid
              _ -> nil
            end

          {:ok, %{parent: parent, state: state, port: port, os_pid: os_pid}}
        end

        unquote(open_port_ast)
        unquote(resolve_exe_ast)

        @impl true
        def handle_call(:os_pid, _from, s), do: {:reply, {:ok, s.os_pid}, s}

        @impl true
        def handle_cast({:write_stdin, bytes}, s) do
          true = Port.command(s.port, bytes)
          {:noreply, s}
        end

        @impl true
        def handle_info({port, {:data, {_eol, line}}}, %{port: port} = s) do
          # Forward stdout line to Peer's handle_upstream
          new_state = dispatch_stdout(s, line)
          {:noreply, new_state}
        end

        def handle_info({port, {:exit_status, status}}, %{port: port} = s) do
          case s.parent.on_os_exit(status, s.state) do
            {:stop, reason} -> {:stop, reason, s}
            {:restart, _new_state} -> {:stop, :restart_not_yet_implemented, s}
          end
        end

        defp dispatch_stdout(s, line) do
          case s.parent.handle_upstream({:os_stdout, line}, s.state) do
            {:forward, _msgs, new_state} -> %{s | state: new_state}
            {:reply, _msg, new_state} -> %{s | state: new_state}
            {:drop, _reason, new_state} -> %{s | state: new_state}
          end
        end

        defp to_env_charlists(env) do
          for {k, v} <- env, do: {String.to_charlist(k), String.to_charlist(v)}
        end
      end
    end
  end

  @doc false
  # Compile-time selection of the open_port/3 implementation. Only the chosen
  # clause is emitted into the worker module, so there are no "unused clause"
  # warnings.
  def open_port_ast(:muontrap) do
    quote do
      defp open_port(exe, args, env) do
        muontrap_bin = MuonTrap.muontrap_path()

        Port.open(
          {:spawn_executable, muontrap_bin},
          [
            :binary,
            :exit_status,
            :stderr_to_stdout,
            {:line, 4096},
            {:env, to_env_charlists(env)},
            {:args,
             ["--capture-output", "--delay-to-sigkill", "5000", "--"] ++ [exe | args]}
          ]
        )
      end
    end
  end

  def open_port_ast(:none) do
    quote do
      defp open_port(exe, args, env) do
        exe_path = resolve_exe(exe)

        Port.open(
          {:spawn_executable, exe_path},
          [
            :binary,
            :exit_status,
            :stderr_to_stdout,
            {:line, 4096},
            {:env, to_env_charlists(env)},
            {:args, args}
          ]
        )
      end
    end
  end

  @doc false
  def resolve_exe_ast(:muontrap), do: quote(do: nil)

  def resolve_exe_ast(:none) do
    quote do
      defp resolve_exe(exe) do
        cond do
          Path.type(exe) == :absolute ->
            exe

          path = System.find_executable(exe) ->
            path

          true ->
            raise "Esr.OSProcess: executable #{inspect(exe)} not found on PATH"
        end
      end
    end
  end
end
