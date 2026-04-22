defmodule Esr.OSProcess do
  @moduledoc """
  Composition底座 for Peers that wrap one OS process.

  A Peer that uses `Esr.OSProcess` gains an embedded worker module
  (`<PeerModule>.OSProcessWorker`) which opens a `Port` to the
  `muontrap` wrapper binary. The wrapper executes the Peer's target
  command and guarantees cleanup on BEAM exit (cgroup on Linux,
  equivalent mechanism on macOS).

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

    quote do
      @behaviour Esr.OSProcess
      @os_process_kind unquote(kind)

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

          muontrap_bin = MuonTrap.muontrap_path()

          port =
            Port.open(
              {:spawn_executable, muontrap_bin},
              [
                :binary,
                :exit_status,
                :stderr_to_stdout,
                {:line, 4096},
                {:env, to_env_charlists(env)},
                {:args, ["--delay-to-sigkill", "5000", "--"] ++ [exe | args]}
              ]
            )

          os_pid =
            case Port.info(port, :os_pid) do
              {:os_pid, pid} -> pid
              _ -> nil
            end

          {:ok, %{parent: parent, state: state, port: port, os_pid: os_pid}}
        end

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
end
