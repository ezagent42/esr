defmodule Esr.Entity.PtyProcessTest do
  @moduledoc """
  PR-22 — PtyProcess unit tests.

  - on_raw_stdout/2 broadcasts to PubSub topic pty:<sid> as raw bytes
    (no line-splitting; xterm.js needs ANSI escapes intact).
  - on_terminate/1 broadcasts a bare :pty_closed sentinel so attached
    LiveViews can render an "ended" overlay.

  Live spawn of the OS process (erlexec :pty + claude) is exercised by
  the e2e scenario `tests/e2e/scenarios/06_pty_attach.sh`, not here.
  """

  use ExUnit.Case, async: false

  alias Esr.Entity.PtyProcess

  setup do
    sid = "test-pty-#{System.unique_integer([:positive])}"
    :ok = Phoenix.PubSub.subscribe(EsrWeb.PubSub, "pty:" <> sid)
    {:ok, sid: sid}
  end

  describe "on_raw_stdout/2" do
    test "broadcasts raw chunk as {:pty_stdout, chunk} on pty:<sid>", %{sid: sid} do
      state = %{session_id: sid}
      chunk = "\e[31mhello\e[0m"

      assert :ok = PtyProcess.on_raw_stdout(chunk, state)
      assert_receive {:pty_stdout, ^chunk}, 200
    end

    test "no-op when session_id is missing or empty" do
      assert :ok = PtyProcess.on_raw_stdout("data", %{session_id: nil})
      assert :ok = PtyProcess.on_raw_stdout("data", %{session_id: ""})
      assert :ok = PtyProcess.on_raw_stdout("data", %{})
      refute_receive {:pty_stdout, _}, 50
    end
  end

  describe "on_terminate/1" do
    test "broadcasts bare :pty_closed when session_id is present", %{sid: sid} do
      state = %{session_id: sid}
      assert :ok = PtyProcess.on_terminate(state)
      assert_receive :pty_closed, 200
    end

    test "no-op when session_id is missing" do
      assert :ok = PtyProcess.on_terminate(%{session_id: nil})
      refute_receive :pty_closed, 50
    end
  end

  describe "on_os_exit/2" do
    test "any exit code stops with a reason (triggers DynamicSupervisor restart)" do
      state = %{session_id: "x"}
      assert {:stop, :pty_died_unexpectedly} = PtyProcess.on_os_exit(0, state)
      assert {:stop, {:pty_crashed, 137}} = PtyProcess.on_os_exit(137, state)
    end
  end

end

defmodule Esr.Entity.PtyProcessIsolationTest do
  use ExUnit.Case, async: false

  alias Phoenix.PubSub

  setup do
    case Process.whereis(EsrWeb.PubSub) do
      nil -> start_supervised!({Phoenix.PubSub, name: EsrWeb.PubSub})
      _ -> :ok
    end

    case Process.whereis(Esr.Entity.Registry) do
      nil -> start_supervised!(Esr.Entity.Registry)
      _ -> :ok
    end

    :ok
  end

  test "two PtyProcesses with same session_id register under distinct actor_id keys" do
    sid = "55555555-5555-4555-8555-555555555555"
    aid_a = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    aid_b = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"

    parent = self()

    # Simulate the post-fix init/1 contract: each PtyProcess registers
    # itself (self()) under its actor_id, not session_id. Registry only
    # accepts self-registration, mirroring how PtyProcess.init/1 calls it.
    pid_a =
      spawn_link(fn ->
        {:ok, _} = Esr.Entity.Registry.register("pty:" <> aid_a, self())
        send(parent, {:registered, :a, self()})
        receive do
          :stop -> :ok
        end
      end)

    pid_b =
      spawn_link(fn ->
        {:ok, _} = Esr.Entity.Registry.register("pty:" <> aid_b, self())
        send(parent, {:registered, :b, self()})
        receive do
          :stop -> :ok
        end
      end)

    assert_receive {:registered, :a, ^pid_a}, 500
    assert_receive {:registered, :b, ^pid_b}, 500

    assert {:ok, ^pid_a} = Esr.Entity.Registry.lookup("pty:" <> aid_a)
    assert {:ok, ^pid_b} = Esr.Entity.Registry.lookup("pty:" <> aid_b)
    assert pid_a != pid_b

    send(pid_a, :stop)
    send(pid_b, :stop)

    _ = sid
  end

  test "broadcast on pty:<actor_id> reaches only the matching subscriber" do
    aid_a = "aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa"
    aid_b = "bbbbbbbb-2222-4222-8222-bbbbbbbbbbbb"

    parent = self()

    _sub_a = spawn_link(fn ->
      :ok = PubSub.subscribe(EsrWeb.PubSub, "pty:" <> aid_a)
      receive do
        {:pty_stdout, data} -> send(parent, {:a, data})
      after 500 -> send(parent, {:a, :timeout})
      end
    end)

    _sub_b = spawn_link(fn ->
      :ok = PubSub.subscribe(EsrWeb.PubSub, "pty:" <> aid_b)
      receive do
        {:pty_stdout, data} -> send(parent, {:b, data})
      after 500 -> send(parent, {:b, :timeout})
      end
    end)

    Process.sleep(50)

    PubSub.broadcast(EsrWeb.PubSub, "pty:" <> aid_a, {:pty_stdout, "alice-output"})

    assert_receive {:a, "alice-output"}, 1_000
    assert_receive {:b, :timeout}, 1_000
  end
end
