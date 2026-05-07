defmodule Esr.Plugins.ClaudeCode.LauncherTest do
  use ExUnit.Case, async: true
  alias Esr.Plugins.ClaudeCode.Launcher

  @session_id "a1b2c3d4-e5f6-4a7b-8c9d-e0f1a2b3c4d5"

  describe "build_env/1" do
    test "includes http_proxy from plugin config" do
      opts = [
        plugin_config: %{
          "http_proxy"  => "http://test-proxy:3128",
          "https_proxy" => "http://test-proxy:3128",
          "no_proxy"    => "localhost,127.0.0.1",
          "esrd_url"    => "ws://127.0.0.1:4001"
        },
        session_id: @session_id
      ]

      env = Launcher.build_env(opts)
      assert Keyword.get(env, :http_proxy)  == "http://test-proxy:3128"
      assert Keyword.get(env, :https_proxy) == "http://test-proxy:3128"
      assert Keyword.get(env, :no_proxy)    == "localhost,127.0.0.1"
    end

    test "empty http_proxy does not inject env var" do
      opts = [
        plugin_config: %{
          "http_proxy"  => "",
          "https_proxy" => "",
          "no_proxy"    => "",
          "esrd_url"    => "ws://127.0.0.1:4001"
        },
        session_id: @session_id
      ]

      env = Launcher.build_env(opts)
      refute Keyword.has_key?(env, :http_proxy),
             "empty http_proxy must not be injected"
    end

    test "includes ESR_ESRD_URL from plugin config esrd_url" do
      opts = [
        plugin_config: %{
          "http_proxy"  => "",
          "https_proxy" => "",
          "no_proxy"    => "",
          "esrd_url"    => "ws://10.0.0.1:4001"
        },
        session_id: @session_id
      ]

      env = Launcher.build_env(opts)
      assert Keyword.get(env, :ESR_ESRD_URL) == "ws://10.0.0.1:4001"
    end

    test "always injects ESR_SESSION_ID" do
      opts = [
        plugin_config: %{
          "http_proxy"  => "",
          "https_proxy" => "",
          "no_proxy"    => "",
          "esrd_url"    => ""
        },
        session_id: @session_id
      ]

      env = Launcher.build_env(opts)
      assert Keyword.get(env, :ESR_SESSION_ID) == @session_id
    end
  end

  describe "write_mcp_json/1" do
    test "writes .mcp.json to workspace cwd" do
      tmp =
        System.tmp_dir!()
        |> Path.join("launcher-test-#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp)
      on_exit(fn -> File.rm_rf!(tmp) end)

      :ok =
        Launcher.write_mcp_json(
          cwd: tmp,
          esrd_url: "ws://127.0.0.1:4001",
          session_id: @session_id
        )

      mcp_path = Path.join(tmp, ".mcp.json")
      assert File.exists?(mcp_path)
      {:ok, body} = File.read(mcp_path)
      decoded = Jason.decode!(body)
      assert is_map(decoded["mcpServers"])
    end

    test "written .mcp.json contains esr-channel server entry" do
      tmp =
        System.tmp_dir!()
        |> Path.join("launcher-test-#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp)
      on_exit(fn -> File.rm_rf!(tmp) end)

      :ok =
        Launcher.write_mcp_json(
          cwd: tmp,
          esrd_url: "ws://127.0.0.1:4001",
          session_id: @session_id
        )

      {:ok, body} = File.read(Path.join(tmp, ".mcp.json"))
      decoded = Jason.decode!(body)
      assert Map.has_key?(decoded["mcpServers"], "esr-channel"),
             "mcpServers must contain esr-channel key"
    end
  end

  describe "spawn_cmd/1" do
    test "returns a non-empty list" do
      cmd = Launcher.spawn_cmd([])
      assert is_list(cmd)
      assert length(cmd) >= 1
    end

    test "first element references the claude binary" do
      [binary | _] = Launcher.spawn_cmd([])
      assert String.contains?(binary, "claude"),
             "spawn_cmd must reference the claude binary, got: #{inspect(binary)}"
    end

    test "claude_binary option overrides the default binary" do
      [binary | _] = Launcher.spawn_cmd(claude_binary: "/tmp/mock-claude.sh")
      assert binary == "/tmp/mock-claude.sh",
             "claude_binary opt must override default, got: #{inspect(binary)}"
    end

    test "empty string claude_binary falls back to default" do
      [default | _] = Launcher.spawn_cmd([])
      [via_empty | _] = Launcher.spawn_cmd(claude_binary: "")
      assert via_empty == default,
             "empty claude_binary must fall back to default binary"
    end
  end
end
