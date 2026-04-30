defmodule Esr.Workers.AdapterProcessTest do
  # async: false because this test mutates `Application.put_env(:esr,
  # :spawn_token, _)` which is global; concurrent tests would race.
  use ExUnit.Case, async: false

  alias Esr.Workers.AdapterProcess

  setup do
    Application.put_env(:esr, :spawn_token, "test-token-abc")
    on_exit(fn -> Application.delete_env(:esr, :spawn_token) end)
    :ok
  end

  describe "os_cmd/1" do
    test "uses the venv python (bypassing uv run) and resolves sidecar by adapter name" do
      state = %{
        adapter: "feishu",
        instance_id: "esr_helper",
        url: "ws://127.0.0.1:4002/adapter_hub/socket/websocket?vsn=2.0.0",
        config_json: ~s({"app_id":"cli_x","app_secret":"y"})
      }

      cmd = AdapterProcess.os_cmd(state)

      assert [python_bin, "-m", "feishu_adapter_runner" | _] = cmd
      assert String.ends_with?(python_bin, "py/.venv/bin/python")
      refute Enum.member?(cmd, "uv"), "must not invoke `uv run` (pid drift bug repro)"

      assert "--adapter" in cmd
      assert "feishu" in cmd
      assert "--instance-id" in cmd
      assert "esr_helper" in cmd
      assert "--url" in cmd
      assert "--config-json" in cmd
    end

    test "unknown adapter falls back to generic_adapter_runner" do
      state = %{adapter: "unknown_kind", instance_id: "i", url: "x", config_json: "{}"}
      cmd = AdapterProcess.os_cmd(state)
      assert "generic_adapter_runner" in cmd
    end
  end

  describe "os_env/1" do
    test "includes ESR_SPAWN_TOKEN from app env + PYTHONUNBUFFERED" do
      env = AdapterProcess.os_env(%{adapter: "x", instance_id: "y"})
      assert {"ESR_SPAWN_TOKEN", "test-token-abc"} in env
      assert {"PYTHONUNBUFFERED", "1"} in env
    end

    test "ESR_SPAWN_TOKEN defaults to empty string when app env unset" do
      Application.delete_env(:esr, :spawn_token)
      env = AdapterProcess.os_env(%{})
      assert {"ESR_SPAWN_TOKEN", ""} in env
    end
  end

  describe "os_cwd/1" do
    test "returns the py project directory" do
      cwd = AdapterProcess.os_cwd(%{})
      assert String.ends_with?(cwd, "/py")
      assert File.dir?(cwd)
    end
  end

  describe "on_os_exit/2" do
    test "status 0 → :stop :normal" do
      assert {:stop, :normal} = AdapterProcess.on_os_exit(0, %{})
    end

    test "non-zero status → :stop {:py_crashed, status}" do
      assert {:stop, {:py_crashed, 137}} = AdapterProcess.on_os_exit(137, %{})
    end
  end
end
