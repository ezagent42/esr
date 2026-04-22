defmodule Esr.PyProcessTest do
  use ExUnit.Case, async: false
  @moduletag :integration

  @fixture Path.expand("../fixtures/py/echo_sidecar.py", __DIR__)

  test "JSON-line round-trip with echo sidecar" do
    {:ok, pid} =
      Esr.PyProcess.start_link(%{
        entry_point: {:script, @fixture},
        subscriber: self()
      })

    :ok = Esr.PyProcess.send_request(pid, %{id: "req-1", payload: %{hello: "world"}})

    assert_receive {:py_reply,
                    %{"id" => "req-1", "kind" => "reply", "payload" => %{"hello" => "world"}}},
                   3000

    GenServer.stop(pid)
  end

  test "cleanup: killing the owner causes the Python sidecar to exit within 10s" do
    {:ok, pid} =
      Esr.PyProcess.start_link(%{
        entry_point: {:script, @fixture},
        subscriber: self()
      })

    {:ok, os_pid} = GenServer.call(pid, :os_pid)
    assert is_integer(os_pid)

    # Sanity: the sidecar is alive before kill.
    assert_sidecar_alive(os_pid)

    # Closing the Port by stopping the worker will close the child's stdin,
    # which the Python fixture treats as EOF → clean exit.
    GenServer.stop(pid)

    assert wait_for_exit(os_pid, 10_000),
           "sidecar os_pid=#{os_pid} still alive 10s after owner stop"
  end

  defp assert_sidecar_alive(os_pid) do
    # `kill -0` returns 0 if the pid exists.
    {_, status} = System.cmd("kill", ["-0", Integer.to_string(os_pid)], stderr_to_stdout: true)
    assert status == 0
  end

  defp wait_for_exit(os_pid, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    wait_loop(os_pid, deadline)
  end

  defp wait_loop(os_pid, deadline) do
    {_, status} = System.cmd("kill", ["-0", Integer.to_string(os_pid)], stderr_to_stdout: true)

    cond do
      status != 0 -> true
      System.monotonic_time(:millisecond) >= deadline -> false
      true ->
        Process.sleep(100)
        wait_loop(os_pid, deadline)
    end
  end
end
