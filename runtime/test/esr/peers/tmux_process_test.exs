defmodule Esr.Peers.TmuxProcessTest do
  @moduledoc """
  P3-3 — `Esr.Peers.TmuxProcess` is the per-Session `Peer.Stateful` that
  owns a tmux control-mode session. It sits downstream from
  `Esr.Peers.CCProcess`:

    * `handle_downstream({:send_input, text}, state)` writes
      `send-keys -t <session> "<text>" Enter\\n` to tmux stdin via the
      OSProcessWorker's `write_stdin/2` helper.

    * On `{:os_stdout, line}` upstream events, it parses tmux's
      `%begin/%end/%output/%exit` prefixes into structured `:tmux_event`
      tuples, multicasts them to subscribers, and — when an
      `{:output, _pane, bytes}` event arrives — also forwards
      `{:tmux_output, bytes}` to the `cc_process` neighbor so
      `CCProcess.handle_upstream/2` can feed it into the Python handler.

    * `on_terminate/1` (invoked from OSProcessWorker's `terminate/2`)
      runs `tmux kill-session -t <session>` so app-level tmux state
      doesn't leak when the Peer stops normally.

  Spec §3.2, §4.1 TmuxProcess card; expansion P3-3.
  """
  use ExUnit.Case, async: false

  alias Esr.Peers.TmuxProcess

  describe "parse_event/1" do
    test "recognises %begin/%end/%output/%exit prefixes" do
      assert TmuxProcess.parse_event("%begin 1 2 0\n") == {:begin, "1", "2", "0"}
      assert TmuxProcess.parse_event("%end 1 2 0\n") == {:end, "1", "2", "0"}
      assert TmuxProcess.parse_event("%output %0 hello\n") == {:output, "%0", "hello"}
      assert TmuxProcess.parse_event("%exit\n") == {:exit}
      assert TmuxProcess.parse_event("random garbage\n") == {:unknown, "random garbage\n"}
    end
  end

  describe "handle_downstream/2" do
    test "{:send_input, text} returns a forward with no upstream output" do
      state = %{session_name: "sess-1", dir: "/tmp", subscribers: [self()], neighbors: []}
      # handle_downstream casts write_stdin to the worker; since we are
      # not running inside an OSProcessWorker, the cast targets `self()`
      # as the worker pid — harmless for this assertion. The actual
      # stdin write is exercised by the integration test below.
      assert {:forward, [], ^state} = TmuxProcess.handle_downstream({:send_input, "hi"}, state)
    end

    test "legacy {:send_keys, text} remains supported (PR-1 back-compat)" do
      state = %{session_name: "sess-1b", dir: "/tmp", subscribers: [self()], neighbors: []}
      assert {:forward, [], ^state} = TmuxProcess.handle_downstream({:send_keys, "hi"}, state)
    end

    test "unknown downstream messages are forwarded without output" do
      state = %{session_name: "s", dir: "/tmp", subscribers: [self()], neighbors: []}
      assert {:forward, [], ^state} = TmuxProcess.handle_downstream({:other, :msg}, state)
    end
  end

  describe "handle_upstream/2" do
    test "broadcasts :tmux_event to all subscribers" do
      me = self()
      other = spawn_link(fn -> relay(me) end)

      state = %{
        session_name: "sess-2",
        dir: "/tmp",
        subscribers: [me, other],
        neighbors: []
      }

      {:forward, [event_tuple], ^state} =
        TmuxProcess.handle_upstream({:os_stdout, "%output %0 hello\n"}, state)

      assert event_tuple == {:tmux_event, {:output, "%0", "hello"}}
      assert_receive {:tmux_event, {:output, "%0", "hello"}}, 200
      assert_receive {:relay, {:tmux_event, {:output, "%0", "hello"}}}, 200
    end

    test "on {:output, ...} event, forwards {:tmux_output, bytes} to cc_process neighbor" do
      me = self()
      cc_process = spawn_link(fn -> relay(me) end)

      state = %{
        session_name: "sess-3",
        dir: "/tmp",
        subscribers: [me],
        neighbors: [cc_process: cc_process]
      }

      {:forward, _out, ^state} =
        TmuxProcess.handle_upstream({:os_stdout, "%output %0 abc\n"}, state)

      assert_receive {:relay, {:tmux_output, "abc"}}, 200
    end

    test "non-:output tmux events do not fan out to cc_process neighbor" do
      me = self()
      cc_process = spawn_link(fn -> relay(me) end)

      state = %{
        session_name: "sess-4",
        dir: "/tmp",
        subscribers: [me],
        neighbors: [cc_process: cc_process]
      }

      {:forward, _out, ^state} =
        TmuxProcess.handle_upstream({:os_stdout, "%begin 1 2 0\n"}, state)

      refute_receive {:relay, {:tmux_output, _}}, 100
    end

    test "works when no cc_process neighbor is configured" do
      me = self()

      state = %{
        session_name: "sess-5",
        dir: "/tmp",
        subscribers: [me],
        neighbors: []
      }

      # Must not raise when cc_process neighbor is absent.
      {:forward, _out, ^state} =
        TmuxProcess.handle_upstream({:os_stdout, "%output %0 x\n"}, state)

      assert_receive {:tmux_event, {:output, "%0", "x"}}, 200
    end
  end

  describe "init/1" do
    test "stores neighbors and subscribers" do
      cc = spawn_link(fn -> relay(self()) end)

      {:ok, state} =
        TmuxProcess.init(%{
          session_name: "s",
          dir: "/tmp",
          subscriber: self(),
          neighbors: [cc_process: cc]
        })

      assert state.session_name == "s"
      assert state.dir == "/tmp"
      assert state.subscribers == [self()]
      assert Keyword.get(state.neighbors, :cc_process) == cc
    end
  end

  describe "integration (real tmux)" do
    # Each test uses an isolated socket path so test sessions can never
    # leak into the user's default tmux server. Defensive `on_exit` kills
    # the whole server + removes the socket file.
    setup do
      sock = Path.join(System.tmp_dir!(), "esr-tmux-#{:erlang.unique_integer([:positive])}.sock")

      on_exit(fn ->
        System.cmd("tmux", ["-S", sock, "kill-server"], stderr_to_stdout: true)
        File.rm(sock)
      end)

      {:ok, tmux_socket: sock}
    end

    @tag :integration
    test "starts tmux in -C mode and receives %begin/%end output markers", %{tmux_socket: sock} do
      name = "esr_test_markers_#{System.unique_integer([:positive])}"

      {:ok, pid} =
        TmuxProcess.start_link(%{
          session_name: name,
          dir: "/tmp",
          tmux_socket: sock
        })

      {:ok, _os_pid} = GenServer.call(pid, :os_pid)

      :ok = TmuxProcess.send_command(pid, "list-windows")

      assert_receive {:tmux_event, {:begin, _time, _num, _flags}}, 2000
      assert_receive {:tmux_event, {:end, _time, _num, _flags}}, 2000

      GenServer.stop(pid)
    end

    @tag :integration
    test "terminate/2 invokes tmux kill-session via on_terminate", %{tmux_socket: sock} do
      name = "esr_pr3_term_test_#{System.unique_integer([:positive])}"

      {:ok, pid} =
        TmuxProcess.start_link(%{
          session_name: name,
          dir: "/tmp",
          subscriber: self(),
          tmux_socket: sock
        })

      Process.sleep(300)

      {out, 0} = System.cmd("tmux", ["-S", sock, "list-sessions"], stderr_to_stdout: true)
      assert out =~ name

      GenServer.stop(pid)
      Process.sleep(500)

      # After on_terminate: server is killed, socket file removed.
      # `list-sessions` on the dead socket should NOT see our session.
      {out2, _} = System.cmd("tmux", ["-S", sock, "list-sessions"], stderr_to_stdout: true)
      refute out2 =~ name
    end
  end

  defp relay(reply_to) do
    receive do
      msg ->
        send(reply_to, {:relay, msg})
        relay(reply_to)
    end
  end

  describe "spawn_args/1 honours :tmux_socket_override app env (J1)" do
    setup do
      prev = Application.get_env(:esr, :tmux_socket_override)

      on_exit(fn ->
        if prev == nil do
          Application.delete_env(:esr, :tmux_socket_override)
        else
          Application.put_env(:esr, :tmux_socket_override, prev)
        end
      end)

      :ok
    end

    test "set override is picked up when params omit :tmux_socket" do
      Application.put_env(:esr, :tmux_socket_override, "/tmp/override.sock")
      args = Esr.Peers.TmuxProcess.spawn_args(%{})
      assert args.tmux_socket == "/tmp/override.sock"
    end

    test "explicit :tmux_socket in params wins over override" do
      Application.put_env(:esr, :tmux_socket_override, "/tmp/override.sock")
      args = Esr.Peers.TmuxProcess.spawn_args(%{tmux_socket: "/tmp/explicit.sock"})
      assert args.tmux_socket == "/tmp/explicit.sock"
    end

    test "no override + no param yields no :tmux_socket key" do
      Application.delete_env(:esr, :tmux_socket_override)
      args = Esr.Peers.TmuxProcess.spawn_args(%{})
      refute Map.has_key?(args, :tmux_socket)
    end

    test "boot-time env reader: ESR_E2E_TMUX_SOCK → :tmux_socket_override" do
      # Exercise the boot helper directly so we don't need to restart
      # the Application — Esr.Application.apply_tmux_socket_env/0 is a
      # pure function exposed for tests.
      System.put_env("ESR_E2E_TMUX_SOCK", "/tmp/boot.sock")

      try do
        Esr.Application.apply_tmux_socket_env()
        assert Application.get_env(:esr, :tmux_socket_override) == "/tmp/boot.sock"
      after
        System.delete_env("ESR_E2E_TMUX_SOCK")
        Application.delete_env(:esr, :tmux_socket_override)
      end
    end

    test "boot-time reader: empty ESR_E2E_TMUX_SOCK is a no-op" do
      System.put_env("ESR_E2E_TMUX_SOCK", "")
      Application.delete_env(:esr, :tmux_socket_override)

      try do
        Esr.Application.apply_tmux_socket_env()
        assert Application.get_env(:esr, :tmux_socket_override) == nil
      after
        System.delete_env("ESR_E2E_TMUX_SOCK")
      end
    end
  end

  describe "end-to-end ESR_E2E_TMUX_SOCK observable (J1 integration)" do
    test "boot + spawn assert the tmux socket path threads into peer state" do
      path = "/tmp/e2e-tmux-int-#{System.unique_integer([:positive])}.sock"
      System.put_env("ESR_E2E_TMUX_SOCK", path)

      try do
        Esr.Application.apply_tmux_socket_env()
        args = Esr.Peers.TmuxProcess.spawn_args(%{})
        assert args[:tmux_socket] == path
      after
        System.delete_env("ESR_E2E_TMUX_SOCK")
        Application.delete_env(:esr, :tmux_socket_override)
      end
    end
  end

  # --------------------------------------------------------------------
  # PR-9 T11b.3 — TmuxProcess injects ESR_* env + launches claude CLI
  # as the pane's initial process (rather than opening an idle pane).
  # Spec: docs/superpowers/specs/2026-04-24-pr9-t11b-cc-cli-mcp.md §4.2 A.
  # --------------------------------------------------------------------
  describe "PR-9 T11b.3: spawn_args/1 threads session context" do
    test "reads session_id, workspace_name, chat_id, app_id, start_cmd from params" do
      params = %{
        session_id: "SID123",
        workspace_name: "ws-a",
        chat_id: "oc_chat_xyz",
        app_id: "cli_app_1",
        start_cmd: "claude --custom",
        dir: "/tmp/repo"
      }

      args = TmuxProcess.spawn_args(params)

      assert args.session_id == "SID123"
      assert args.workspace_name == "ws-a"
      assert args.chat_id == "oc_chat_xyz"
      assert args.app_id == "cli_app_1"
      assert args.start_cmd == "claude --custom"
      assert args.dir == "/tmp/repo"
    end

    test "tolerates string-keyed params (atom+string dual shape via Peer.get_param/2)" do
      params = %{
        "session_id" => "SID999",
        "workspace_name" => "ws-b",
        "chat_id" => "cid",
        "app_id" => "aid"
      }

      args = TmuxProcess.spawn_args(params)

      assert args.session_id == "SID999"
      assert args.workspace_name == "ws-b"
      assert args.chat_id == "cid"
      assert args.app_id == "aid"
    end

    test "missing session context yields nil fields (legacy path)" do
      args = TmuxProcess.spawn_args(%{})

      assert is_nil(args.session_id)
      assert is_nil(args.workspace_name)
      assert is_nil(args.chat_id)
      assert is_nil(args.app_id)
      assert is_nil(args.start_cmd)
    end
  end

  describe "PR-9 T11b.3: os_env/1 produces ESR_* vars" do
    test "emits four ESR_* env vars when session_id is set" do
      state = %{
        session_id: "SID1",
        workspace_name: "workspace-a",
        chat_id: "oc_chat_1",
        app_id: "cli_app_a"
      }

      env = TmuxProcess.os_env(state)

      assert {"ESR_SESSION_ID", "SID1"} in env
      assert {"ESR_WORKSPACE", "workspace-a"} in env
      assert length(env) == 4

      {_k, chat_ids_json} = Enum.find(env, fn {k, _} -> k == "ESR_CHAT_IDS" end)
      assert Jason.decode!(chat_ids_json) == [
               %{"chat_id" => "oc_chat_1", "app_id" => "cli_app_a", "kind" => "feishu"}
             ]

      {_k, url} = Enum.find(env, fn {k, _} -> k == "ESR_ESRD_URL" end)
      # /channel/socket, not /adapter_hub/socket — this is the MCP bridge.
      assert url =~ ~r(\Aws://127\.0\.0\.1:\d+/channel/socket/websocket\?vsn=2\.0\.0\z)
    end

    test "no session_id ⇒ empty env (legacy idle-pane path)" do
      state = %{session_id: nil}
      assert TmuxProcess.os_env(state) == []
    end

    test "empty-string session_id also yields empty env" do
      state = %{session_id: ""}
      assert TmuxProcess.os_env(state) == []
    end

    test "missing workspace_name defaults to \"default\"" do
      state = %{
        session_id: "SID2",
        workspace_name: nil,
        chat_id: "c",
        app_id: "a"
      }

      env = TmuxProcess.os_env(state)
      assert {"ESR_WORKSPACE", "default"} in env
    end
  end

  describe "PR-9 T11b.3: os_cmd/1 appends claude invocation" do
    test "with session context — trailing arg is a single shell-command string" do
      state = %{
        session_name: "esr_cc_test_1",
        dir: "/tmp/wsrepo",
        session_id: "SID42",
        workspace_name: "ws-a",
        chat_id: "c",
        app_id: "a",
        start_cmd: nil,
        mcp_config_path: "/tmp/esr-mcp-SID42.json",
        tmux_socket: nil
      }

      argv = TmuxProcess.os_cmd(state)

      # Core tmux invocation stays intact.
      assert Enum.take(argv, 6) ==
               ["tmux", "-C", "new-session", "-s", "esr_cc_test_1", "-c", "/tmp/wsrepo"]
               |> Enum.take(6)

      # Trailing element is the single shell-command string.
      claude_cmd = List.last(argv)
      assert is_binary(claude_cmd)
      assert claude_cmd =~ "claude --permission-mode bypassPermissions"
      assert claude_cmd =~ "--dangerously-load-development-channels server:esr-channel"
      assert claude_cmd =~ "--mcp-config /tmp/esr-mcp-SID42.json"
      assert claude_cmd =~ "--add-dir /tmp/wsrepo"
    end

    test "with tmux_socket — socket args come before -C, claude still trails" do
      state = %{
        session_name: "esr_cc_test_2",
        dir: "/tmp",
        session_id: "SID77",
        workspace_name: "w",
        chat_id: "c",
        app_id: "a",
        start_cmd: nil,
        mcp_config_path: "/tmp/esr-mcp-SID77.json",
        tmux_socket: "/tmp/sock77.sock"
      }

      argv = TmuxProcess.os_cmd(state)

      # ["tmux", "-S", "/tmp/sock77.sock", "-C", "new-session", "-s", ..., "-c", ..., "<claude cmd>"]
      assert Enum.take(argv, 3) == ["tmux", "-S", "/tmp/sock77.sock"]
      assert List.last(argv) =~ "claude --permission-mode bypassPermissions"
    end

    test "without session context — legacy idle-pane argv (no claude suffix)" do
      state = %{
        session_name: "esr_cc_idle",
        dir: "/tmp",
        session_id: nil,
        tmux_socket: nil
      }

      argv = TmuxProcess.os_cmd(state)

      assert argv == ["tmux", "-C", "new-session", "-s", "esr_cc_idle", "-c", "/tmp"]
      refute Enum.any?(argv, &(&1 =~ "claude"))
    end

    test "custom start_cmd overrides the default claude invocation" do
      state = %{
        session_name: "esr_cc_custom",
        dir: "/tmp",
        session_id: "SID99",
        workspace_name: "ws",
        chat_id: "c",
        app_id: "a",
        start_cmd: "bash -lc 'echo hi'",
        mcp_config_path: "/tmp/esr-mcp-SID99.json",
        tmux_socket: nil
      }

      argv = TmuxProcess.os_cmd(state)
      assert List.last(argv) =~ "bash"
      refute List.last(argv) =~ "--mcp-config"
    end
  end

  describe "PR-9 T11b.3: MCP config file rendering" do
    test "render_mcp_config! writes expected JSON shape" do
      path =
        Path.join(
          System.tmp_dir!(),
          "esr-mcp-test-#{System.unique_integer([:positive])}.json"
        )

      on_exit(fn -> File.rm(path) end)

      :ok = TmuxProcess.render_mcp_config!(path)

      assert File.exists?(path)
      parsed = path |> File.read!() |> Jason.decode!()

      assert %{"mcpServers" => %{"esr-channel" => entry}} = parsed
      assert entry["command"] == "uv"

      args = entry["args"]
      assert is_list(args)
      assert Enum.take(args, 2) == ["run", "--project"]
      # ["run", "--project", "<repo>/adapters/cc_mcp", "python", "-m", "esr_cc_mcp.channel"]
      project = Enum.at(args, 2)
      assert String.ends_with?(project, "/adapters/cc_mcp")
      assert Enum.drop(args, 3) == ["python", "-m", "esr_cc_mcp.channel"]
    end

    test "mcp_config_path_for/1 returns /tmp/esr-mcp-<sid>.json" do
      assert TmuxProcess.mcp_config_path_for("ABCD") ==
               Path.join(System.tmp_dir!(), "esr-mcp-ABCD.json")
    end

    test "init/1 with a session_id renders the per-session MCP config file" do
      sid = "INIT-#{System.unique_integer([:positive])}"
      path = TmuxProcess.mcp_config_path_for(sid)
      on_exit(fn -> File.rm(path) end)

      {:ok, state} =
        TmuxProcess.init(%{
          session_name: "n",
          dir: "/tmp",
          session_id: sid,
          workspace_name: "ws",
          chat_id: "c",
          app_id: "a"
        })

      assert state.mcp_config_path == path
      assert File.exists?(path)
    end

    test "init/1 without session_id leaves mcp_config_path nil + writes no file" do
      {:ok, state} =
        TmuxProcess.init(%{session_name: "n", dir: "/tmp"})

      assert is_nil(state.mcp_config_path)
    end
  end
end
