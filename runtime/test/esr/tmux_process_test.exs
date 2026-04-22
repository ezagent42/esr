defmodule Esr.TmuxProcessTest do
  use ExUnit.Case, async: false
  @moduletag :integration

  @session_name "esr-test-tmux-#{System.system_time(:millisecond)}"

  setup do
    on_exit(fn -> System.cmd("tmux", ["kill-session", "-t", @session_name]) end)
    :ok
  end

  test "starts tmux in -C mode and receives %begin/%end output markers" do
    {:ok, pid} = Esr.TmuxProcess.start_link(%{session_name: @session_name, dir: "/tmp"})
    {:ok, _os_pid} = GenServer.call(pid, :os_pid)

    # Send a simple command via the control-mode protocol
    :ok = Esr.TmuxProcess.send_command(pid, "list-windows")

    # Expect a %begin ... %end envelope back
    assert_receive {:tmux_event, {:begin, _time, _num, _flags}}, 2000
    assert_receive {:tmux_event, {:end, _time, _num, _flags}}, 2000

    GenServer.stop(pid)
  end
end
