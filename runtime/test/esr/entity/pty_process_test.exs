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
