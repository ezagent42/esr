defmodule Esr.OSProcessTest do
  use ExUnit.Case, async: false

  @moduletag :integration

  defmodule SleepPeer do
    use Esr.Peer.Stateful
    use Esr.OSProcess, kind: :test_sleep

    @impl Esr.Peer.Stateful
    def init(%{} = args), do: {:ok, %{dur: args[:dur] || 30}}

    @impl Esr.Peer.Stateful
    def handle_upstream(_, state), do: {:forward, [], state}
    @impl Esr.Peer.Stateful
    def handle_downstream(_, state), do: {:forward, [], state}

    @impl Esr.OSProcess
    def os_cmd(state), do: ["sleep", Integer.to_string(state.dur)]
    @impl Esr.OSProcess
    def os_env(_state), do: []
    @impl Esr.OSProcess
    def on_os_exit(0, _state), do: {:stop, :normal}
    def on_os_exit(status, _state), do: {:stop, {:exited, status}}
  end

  test "os_cmd wraps the OS process via MuonTrap and returns pid/os_pid" do
    {:ok, pid} = GenServer.start_link(SleepPeer.OSProcessWorker, %{dur: 5})
    {:ok, os_pid} = GenServer.call(pid, :os_pid)
    assert is_integer(os_pid) and os_pid > 0

    # Confirm the process exists
    assert {_, 0} = System.cmd("ps", ["-p", Integer.to_string(os_pid)])
    GenServer.stop(pid, :normal)
  end

  test "killing the Elixir GenServer cleans up the OS process within 10s" do
    # Trap exits so the test process survives the linked worker being killed.
    Process.flag(:trap_exit, true)
    {:ok, pid} = GenServer.start_link(SleepPeer.OSProcessWorker, %{dur: 60})
    {:ok, os_pid} = GenServer.call(pid, :os_pid)

    Process.exit(pid, :kill)
    assert_receive {:EXIT, ^pid, :killed}, 1_000

    # Poll up to 10s
    Enum.reduce_while(1..20, nil, fn _i, _ ->
      case System.cmd("ps", ["-p", Integer.to_string(os_pid)]) do
        {_, 0} -> :timer.sleep(500); {:cont, nil}
        {_, _} -> {:halt, :gone}
      end
    end)
    |> case do
      :gone -> :ok
      _     -> flunk("OS process #{os_pid} still alive after 10s")
    end
  end
end
