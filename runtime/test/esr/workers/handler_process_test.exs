defmodule Esr.Workers.HandlerProcessTest do
  use ExUnit.Case, async: true

  alias Esr.Workers.HandlerProcess

  setup do
    Application.put_env(:esr, :spawn_token, "test-token-xyz")
    on_exit(fn -> Application.delete_env(:esr, :spawn_token) end)
    :ok
  end

  describe "os_cmd/1" do
    test "invokes esr.ipc.handler_worker via venv python" do
      state = %{
        module: "noop_module",
        worker_id: "default",
        url: "ws://127.0.0.1:4002/handler_hub/socket/websocket?vsn=2.0.0"
      }

      cmd = HandlerProcess.os_cmd(state)

      assert [python_bin, "-m", "esr.ipc.handler_worker" | _] = cmd
      assert String.ends_with?(python_bin, "py/.venv/bin/python")
      refute Enum.member?(cmd, "uv")

      assert "--module" in cmd
      assert "noop_module" in cmd
      assert "--worker-id" in cmd
      assert "default" in cmd
      assert "--url" in cmd
    end
  end

  describe "os_env/1" do
    test "includes ESR_SPAWN_TOKEN + PYTHONUNBUFFERED" do
      env = HandlerProcess.os_env(%{module: "x", worker_id: "y"})
      assert {"ESR_SPAWN_TOKEN", "test-token-xyz"} in env
      assert {"PYTHONUNBUFFERED", "1"} in env
    end
  end

  describe "os_cwd/1" do
    test "returns the py project directory" do
      cwd = HandlerProcess.os_cwd(%{})
      assert String.ends_with?(cwd, "/py")
    end
  end

  describe "on_os_exit/2" do
    test "status 0 → :stop :normal" do
      assert {:stop, :normal} = HandlerProcess.on_os_exit(0, %{})
    end

    test "non-zero status → :stop {:py_crashed, status}" do
      assert {:stop, {:py_crashed, 1}} = HandlerProcess.on_os_exit(1, %{})
    end
  end
end
