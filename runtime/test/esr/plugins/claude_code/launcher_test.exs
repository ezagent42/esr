defmodule Esr.Plugins.ClaudeCode.LauncherTest do
  use ExUnit.Case, async: false
  alias Esr.Plugins.ClaudeCode.Launcher

  @session_id "a1b2c3d4-e5f6-4a7b-8c9d-e0f1a2b3c4d5"

  setup do
    # Snapshot + isolate ESRD_HOME / ESR_INSTANCE so each test gets its
    # own session_mcp_json/1 root. PR-2 (2026-05-11): the .mcp.json now
    # lives at $ESRD_HOME/<inst>/sessions/<sid>/mcp.json, not at <cwd>/.mcp.json,
    # so we must point ESRD_HOME at a per-test tmp dir.
    saved_home = System.get_env("ESRD_HOME")
    saved_inst = System.get_env("ESR_INSTANCE")

    tmp =
      Path.join(
        System.tmp_dir!(),
        "launcher_test_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp)
    System.put_env("ESRD_HOME", tmp)
    System.put_env("ESR_INSTANCE", "test")

    on_exit(fn ->
      File.rm_rf!(tmp)

      if saved_home,
        do: System.put_env("ESRD_HOME", saved_home),
        else: System.delete_env("ESRD_HOME")

      if saved_inst,
        do: System.put_env("ESR_INSTANCE", saved_inst),
        else: System.delete_env("ESR_INSTANCE")
    end)

    {:ok, tmp: tmp}
  end

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
    test "writes .mcp.json at session-scoped path under ESRD_HOME" do
      {:ok, mcp_path} =
        Launcher.write_mcp_json(
          session_id: @session_id,
          esrd_url: "ws://127.0.0.1:4001"
        )

      assert mcp_path == Esr.Paths.session_mcp_json(@session_id)
      assert File.exists?(mcp_path)
      {:ok, body} = File.read(mcp_path)
      decoded = Jason.decode!(body)
      assert is_map(decoded["mcpServers"])
    end

    test "written .mcp.json contains esr-channel server entry" do
      {:ok, mcp_path} =
        Launcher.write_mcp_json(
          session_id: @session_id,
          esrd_url: "ws://127.0.0.1:4001"
        )

      {:ok, body} = File.read(mcp_path)
      decoded = Jason.decode!(body)
      assert Map.has_key?(decoded["mcpServers"], "esr-channel"),
             "mcpServers must contain esr-channel key"

      # URL flips ws:// → http:// for the HTTP MCP transport.
      assert decoded["mcpServers"]["esr-channel"]["url"] ==
               "http://127.0.0.1:4001/mcp/#{@session_id}"
    end
  end

  describe "prepare_spawn/1 — sole entry (PR-2)" do
    setup do
      cwd =
        System.tmp_dir!()
        |> Path.join("prepare-spawn-test-#{System.unique_integer([:positive])}")

      File.mkdir_p!(cwd)
      on_exit(fn -> File.rm_rf!(cwd) end)
      {:ok, cwd: cwd}
    end

    test "returns {:ok, %{cmd: _, env: _}} on happy path", %{cwd: cwd} do
      assert {:ok, %{cmd: cmd, env: env}} =
               Launcher.prepare_spawn(
                 session_id: @session_id,
                 dir: cwd,
                 plugin_config: %{"esrd_url" => "ws://127.0.0.1:4001"},
                 claude_binary: "/tmp/mock-claude.sh"
               )

      assert is_list(cmd)
      assert is_list(env)
      [bin | _] = cmd
      assert bin == "/tmp/mock-claude.sh"
      assert Keyword.get(env, :ESR_SESSION_ID) == @session_id
    end

    test "writes .mcp.json at the ESRD-rooted absolute path", %{cwd: cwd} do
      {:ok, _} =
        Launcher.prepare_spawn(
          session_id: @session_id,
          dir: cwd,
          plugin_config: %{"esrd_url" => "ws://127.0.0.1:4001"},
          claude_binary: "/tmp/mock-claude.sh"
        )

      assert File.exists?(Esr.Paths.session_mcp_json(@session_id))
    end

    test "argv contains --mcp-config <abs_path> threading the written file", %{cwd: cwd} do
      {:ok, %{cmd: cmd}} =
        Launcher.prepare_spawn(
          session_id: @session_id,
          dir: cwd,
          plugin_config: %{"esrd_url" => "ws://127.0.0.1:4001"},
          claude_binary: "/tmp/mock-claude.sh"
        )

      expected_path = Esr.Paths.session_mcp_json(@session_id)
      # Find the --mcp-config flag and assert it points to the absolute
      # session-scoped path (no `.mcp.json` relative shorthand).
      idx = Enum.find_index(cmd, &(&1 == "--mcp-config"))
      assert is_integer(idx)
      assert Enum.at(cmd, idx + 1) == expected_path
    end

    test "argv contains --add-dir <cwd> when dir provided", %{cwd: cwd} do
      {:ok, %{cmd: cmd}} =
        Launcher.prepare_spawn(
          session_id: @session_id,
          dir: cwd,
          plugin_config: %{"esrd_url" => "ws://127.0.0.1:4001"},
          claude_binary: "/tmp/mock-claude.sh"
        )

      idx = Enum.find_index(cmd, &(&1 == "--add-dir"))
      assert is_integer(idx)
      assert Enum.at(cmd, idx + 1) == cwd
    end

    test "returns {:error, :missing_dir} when dir is nil" do
      assert {:error, :missing_dir} =
               Launcher.prepare_spawn(
                 session_id: @session_id,
                 dir: nil,
                 plugin_config: %{"esrd_url" => ""},
                 claude_binary: "/tmp/mock-claude.sh"
               )
    end

    test "returns {:error, :missing_dir} when dir is empty string" do
      assert {:error, :missing_dir} =
               Launcher.prepare_spawn(
                 session_id: @session_id,
                 dir: "",
                 plugin_config: %{"esrd_url" => ""},
                 claude_binary: "/tmp/mock-claude.sh"
               )
    end

    test "returns {:error, :missing_session_id} when session_id is absent", %{cwd: cwd} do
      assert {:error, :missing_session_id} =
               Launcher.prepare_spawn(
                 dir: cwd,
                 plugin_config: %{"esrd_url" => ""},
                 claude_binary: "/tmp/mock-claude.sh"
               )
    end

    test "accepts a state map (PtyProcess production caller)", %{cwd: cwd} do
      state = %{
        session_id: @session_id,
        dir: cwd,
        workspace_role: "dev"
      }

      assert {:ok, %{cmd: cmd, env: _env}} = Launcher.prepare_spawn(state)
      assert is_list(cmd)
    end
  end
end
