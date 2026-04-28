defmodule EsrWeb.CliChannelTest do
  @moduledoc """
  Tests for EsrWeb.CliChannel — Phase 8c Elixir side of the CLI → runtime
  RPC path. Joins on ``cli:*`` topics, handles ``cli_call`` events with
  a synchronous reply.
  """

  use ExUnit.Case, async: true

  import Phoenix.ChannelTest

  @endpoint EsrWeb.Endpoint

  setup do
    {:ok, _, socket} =
      EsrWeb.HandlerSocket
      |> socket("cli-test", %{})
      |> subscribe_and_join(EsrWeb.CliChannel, "cli:probe")

    %{socket: socket}
  end

  test "joins on cli:* topic", %{socket: socket} do
    assert socket.topic == "cli:probe"
  end

  test "unknown cli:* topic returns structured error (reviewer C2)",
       %{socket: socket} do
    ref = push(socket, "cli_call", %{"hello" => "world"})
    assert_reply ref, :ok, response
    assert response["data"]["error"] == "unknown_topic: cli:probe"
  end

  test "unknown event returns :error reply", %{socket: socket} do
    ref = push(socket, "something_else", %{})
    assert_reply ref, :error, reason
    assert reason.reason =~ "unhandled"
  end

  describe "cli:actors/list" do
    setup do
      {:ok, _, socket} =
        EsrWeb.HandlerSocket
        |> socket("cli-test-actors", %{})
        |> subscribe_and_join(EsrWeb.CliChannel, "cli:actors/list")

      %{actors_socket: socket}
    end

    test "cli_call returns the peer registry contents", %{actors_socket: socket} do
      ref = push(socket, "cli_call", %{})
      assert_reply ref, :ok, response
      assert is_list(response["data"])

      for entry <- response["data"] do
        assert is_map(entry)
        assert Map.has_key?(entry, "actor_id")
        assert Map.has_key?(entry, "pid")
      end
    end
  end

  describe "cli:actors/tree (post P3-13)" do
    # P3-13: Topology module deleted. cli:actors/tree now returns an
    # empty topologies list + a migration error string (Option B
    # polite degradation, per expansion §P3-13.5).
    setup do
      {:ok, _, socket} =
        EsrWeb.HandlerSocket
        |> socket("cli-tree", %{})
        |> subscribe_and_join(EsrWeb.CliChannel, "cli:actors/tree")

      %{tree_socket: socket}
    end

    test "returns empty topologies + migration error", %{tree_socket: socket} do
      ref = push(socket, "cli_call", %{})
      assert_reply ref, :ok, response
      data = response["data"]
      assert data["topologies"] == []
      assert data["error"] =~ "topology module removed"
    end
  end

  describe "cli:actors/inspect" do
    setup do
      actor_id = "thread:inspect-test-#{System.unique_integer([:positive])}"
      {:ok, _pid} = start_supervised({Esr.PeerServer,
        actor_id: actor_id,
        actor_type: "feishu_thread_proxy",
        handler_module: "noop",
        initial_state: %{"hello" => "world"}
      })

      {:ok, _, socket} =
        EsrWeb.HandlerSocket
        |> socket("cli-test-inspect", %{})
        |> subscribe_and_join(EsrWeb.CliChannel, "cli:actors/inspect")

      %{inspect_socket: socket, actor_id: actor_id}
    end

    test "returns state of the named actor", %{inspect_socket: socket, actor_id: actor_id} do
      ref = push(socket, "cli_call", %{"arg" => actor_id})
      assert_reply ref, :ok, response
      info = response["data"]
      assert is_map(info)
      assert info["actor_id"] == actor_id
      assert info["actor_type"] == "feishu_thread_proxy"
      assert info["paused"] == false
      assert is_map(info["state"])
    end

    test "missing actor returns error response", %{inspect_socket: socket} do
      ref = push(socket, "cli_call", %{"arg" => "nonexistent:actor"})
      assert_reply ref, :ok, response
      # We reply :ok with a structured error so the CLI surfaces
      # "actor not found" as a user-friendly message rather than a
      # transport error.
      assert response["data"]["error"] == "actor not found"
      assert response["data"]["actor_id"] == "nonexistent:actor"
    end
  end

  describe "cli:run/<name> (post P3-13)" do
    # P3-13: Topology module deleted. cli:run/* now returns a
    # migration error; session creation goes through /new-session.
    setup do
      {:ok, _, socket} =
        EsrWeb.HandlerSocket
        |> socket("cli-run", %{})
        |> subscribe_and_join(EsrWeb.CliChannel, "cli:run/simple-session")

      %{run_socket: socket}
    end

    test "returns migration error regardless of payload",
         %{run_socket: socket} do
      ref =
        push(socket, "cli_call", %{
          "artifact" => %{"name" => "simple-session"},
          "params" => %{"thread_id" => "run-a"}
        })

      assert_reply ref, :ok, response
      assert response["data"]["error"] =~ "topology module removed"
      assert response["data"]["name"] == "simple-session"
      assert response["data"]["peer_ids"] == []
    end
  end

  describe "cli:adapters/refresh (PR-K)" do
    setup do
      {:ok, _, socket} =
        EsrWeb.HandlerSocket
        |> socket("cli-refresh", %{})
        |> subscribe_and_join(EsrWeb.CliChannel, "cli:adapters/refresh")

      %{refresh_socket: socket}
    end

    test "returns ok=true (idempotent — wraps bootstrap_feishu_app_adapters)",
         %{refresh_socket: socket} do
      ref = push(socket, "cli_call", %{})
      assert_reply ref, :ok, response
      assert response["data"]["ok"] == true
    end
  end

  describe "cli:stop/<name> (post P3-13)" do
    setup do
      {:ok, _, socket} =
        EsrWeb.HandlerSocket
        |> socket("cli-stop", %{})
        |> subscribe_and_join(EsrWeb.CliChannel, "cli:stop/feishu-thread-session")

      %{stop_socket: socket}
    end

    test "returns migration error", %{stop_socket: socket} do
      ref =
        push(socket, "cli_call", %{
          "name" => "feishu-thread-session",
          "params" => %{"thread_id" => "a"}
        })

      assert_reply ref, :ok, response
      assert response["data"]["error"] =~ "topology module removed"
      assert response["data"]["name"] == "feishu-thread-session"
      assert response["data"]["stopped_peer_ids"] == []
    end
  end

  describe "cli:drain (post P3-13)" do
    setup do
      {:ok, _, socket} =
        EsrWeb.HandlerSocket
        |> socket("cli-drain", %{})
        |> subscribe_and_join(EsrWeb.CliChannel, "cli:drain")

      %{drain_socket: socket}
    end

    test "returns migration error + empty drained list", %{drain_socket: socket} do
      ref = push(socket, "cli_call", %{})
      assert_reply ref, :ok, response

      data = response["data"]
      assert data["error"] =~ "topology module removed"
      assert data["drained"] == []
      assert data["stopped_peer_ids"] == []
      assert data["timeouts"] == []
    end
  end

  describe "cli:debug/pause and /resume" do
    setup do
      actor_id = "thread:debug-#{System.unique_integer([:positive])}"
      {:ok, _pid} = start_supervised({Esr.PeerServer,
        actor_id: actor_id,
        actor_type: "feishu_thread_proxy",
        handler_module: "noop"
      })

      {:ok, _, pause_socket} =
        EsrWeb.HandlerSocket
        |> socket("cli-pause", %{})
        |> subscribe_and_join(EsrWeb.CliChannel, "cli:debug/pause")

      {:ok, _, resume_socket} =
        EsrWeb.HandlerSocket
        |> socket("cli-resume", %{})
        |> subscribe_and_join(EsrWeb.CliChannel, "cli:debug/resume")

      %{pause_socket: pause_socket, resume_socket: resume_socket, actor_id: actor_id}
    end

    test "pause flips paused=true on the target", ctx do
      ref = push(ctx.pause_socket, "cli_call", %{"actor_id" => ctx.actor_id})
      assert_reply ref, :ok, response
      assert response["data"]["paused"] == true
      assert response["data"]["actor_id"] == ctx.actor_id
      assert Esr.PeerServer.describe(ctx.actor_id).paused == true
    end

    test "resume flips paused=false", ctx do
      :ok = Esr.PeerServer.pause(ctx.actor_id)
      ref = push(ctx.resume_socket, "cli_call", %{"actor_id" => ctx.actor_id})
      assert_reply ref, :ok, response
      assert response["data"]["paused"] == false
      assert Esr.PeerServer.describe(ctx.actor_id).paused == false
    end

    test "pause on missing actor returns structured error", ctx do
      ref = push(ctx.pause_socket, "cli_call", %{"actor_id" => "ghost:missing"})
      assert_reply ref, :ok, response
      assert response["data"]["error"] == "actor not found"
    end
  end

  describe "cli:deadletter/list" do
    setup do
      Esr.DeadLetter.clear(Esr.DeadLetter)
      {:ok, _, socket} =
        EsrWeb.HandlerSocket
        |> socket("cli-test-dl", %{})
        |> subscribe_and_join(EsrWeb.CliChannel, "cli:deadletter/list")

      %{dl_socket: socket}
    end

    test "returns empty list when queue is empty", %{dl_socket: socket} do
      ref = push(socket, "cli_call", %{})
      assert_reply ref, :ok, response
      assert response["data"] == []
    end

    test "returns serialised entries after enqueue", %{dl_socket: socket} do
      Esr.DeadLetter.enqueue(Esr.DeadLetter, %{
        reason: :unknown_target,
        target: "ghost:42",
        msg: %{hello: "world"},
        source: "adapter:feishu/inst1",
        metadata: %{}
      })
      # DeadLetter is a cast; let it settle.
      Process.sleep(20)

      ref = push(socket, "cli_call", %{})
      assert_reply ref, :ok, response
      data = response["data"]
      assert is_list(data)
      assert length(data) == 1
      [entry] = data
      assert entry["reason"] == "unknown_target"
      assert entry["target"] == "ghost:42"
    end
  end

  describe "cli:trace" do
    alias Esr.Telemetry.Buffer

    setup do
      Buffer.record(:default,
        [:esr, :handler, :called],
        %{duration_us: 42},
        %{actor_id: "thread:test", session: "s1"}
      )

      {:ok, _, socket} =
        EsrWeb.HandlerSocket
        |> socket("cli-test-trace", %{})
        |> subscribe_and_join(EsrWeb.CliChannel, "cli:trace")

      %{trace_socket: socket}
    end

    test "returns recent telemetry events", %{trace_socket: socket} do
      ref = push(socket, "cli_call", %{"duration_seconds" => 900})
      assert_reply ref, :ok, response
      entries = response["entries"]
      assert is_list(entries)
      refute entries == []

      matching = Enum.find(entries, fn e ->
        e["event"] == ["esr", "handler", "called"]
      end)
      assert matching != nil
      assert matching["measurements"]["duration_us"] == 42
    end
  end

  describe "cli:deadletter/flush" do
    setup do
      Esr.DeadLetter.clear(Esr.DeadLetter)
      # prime the queue with one entry
      Esr.DeadLetter.enqueue(Esr.DeadLetter, %{
        reason: :test_prime,
        target: "ghost:flush"
      })
      Process.sleep(20)

      {:ok, _, socket} =
        EsrWeb.HandlerSocket
        |> socket("cli-test-flush", %{})
        |> subscribe_and_join(EsrWeb.CliChannel, "cli:deadletter/flush")

      %{flush_socket: socket}
    end

    test "empties the queue and reports count", %{flush_socket: socket} do
      ref = push(socket, "cli_call", %{})
      assert_reply ref, :ok, response
      assert response["data"]["flushed"] == 1
      assert Esr.DeadLetter.list(Esr.DeadLetter) == []
    end
  end

  describe "cli:workspaces/describe" do
    alias Esr.Workspaces.Registry, as: WS

    setup do
      # Clean ETS between tests; the registry GenServer is app-level.
      for {name, _} <- :ets.tab2list(:esr_workspaces), do: :ets.delete(:esr_workspaces, name)

      on_exit(fn ->
        for {name, _} <- :ets.tab2list(:esr_workspaces), do: :ets.delete(:esr_workspaces, name)
      end)

      {:ok, _, socket} =
        EsrWeb.HandlerSocket
        |> socket("cli-test-workspaces-describe", %{})
        |> subscribe_and_join(EsrWeb.CliChannel, "cli:workspaces/describe")

      %{describe_socket: socket}
    end

    test "returns current workspace + 1-hop neighbour metadata", %{describe_socket: socket} do
      :ok =
        WS.put(%WS.Workspace{
          name: "ws_translator",
          cwd: "/tmp/translator",
          start_cmd: "irrelevant_to_LLM",
          role: "dev",
          chats: [
            %{
              "chat_id" => "oc_t",
              "app_id" => "cli_t",
              "kind" => "dm",
              "name" => "translator-room"
            }
          ],
          env: %{"OPENAI_API_KEY" => "should_never_appear_in_response"},
          neighbors: ["workspace:ws_processor"],
          metadata: %{
            "purpose" => "Translate Chinese to English",
            "pipeline_position" => 1
          }
        })

      :ok =
        WS.put(%WS.Workspace{
          name: "ws_processor",
          cwd: "/tmp/processor",
          start_cmd: "irrelevant",
          role: "dev",
          chats: [%{"chat_id" => "oc_p", "app_id" => "cli_p", "kind" => "dm"}],
          env: %{"SECRET" => "filtered"},
          neighbors: [],
          metadata: %{"purpose" => "Structure translated text"}
        })

      ref = push(socket, "cli_call", %{"arg" => "ws_translator"})
      assert_reply ref, :ok, response

      data = response["data"]
      cur = data["current_workspace"]
      assert cur["name"] == "ws_translator"
      assert cur["role"] == "dev"
      assert cur["metadata"]["purpose"] == "Translate Chinese to English"
      assert cur["metadata"]["pipeline_position"] == 1
      assert cur["neighbors_declared"] == ["workspace:ws_processor"]
      [chat] = cur["chats"]
      assert chat["chat_id"] == "oc_t"
      assert chat["name"] == "translator-room"

      # operational fields filtered out
      refute Map.has_key?(cur, "cwd")
      refute Map.has_key?(cur, "start_cmd")
      refute Map.has_key?(cur, "env")

      # neighbour expanded
      [nbr] = data["neighbor_workspaces"]
      assert nbr["name"] == "ws_processor"
      assert nbr["metadata"]["purpose"] == "Structure translated text"
      refute Map.has_key?(nbr, "cwd")
      refute Map.has_key?(nbr, "env")
    end

    test "unknown workspace returns structured error", %{describe_socket: socket} do
      ref = push(socket, "cli_call", %{"arg" => "ws_does_not_exist"})
      assert_reply ref, :ok, response
      assert response["data"]["error"] =~ "unknown_workspace"
    end

    test "missing arg returns structured error", %{describe_socket: socket} do
      ref = push(socket, "cli_call", %{})
      assert_reply ref, :ok, response
      assert response["data"]["error"] =~ "missing arg"
    end

    test "non-workspace neighbours stay raw in neighbors_declared", %{describe_socket: socket} do
      :ok =
        WS.put(%WS.Workspace{
          name: "ws_mixed",
          chats: [%{"chat_id" => "oc_m", "app_id" => "cli_m", "kind" => "group"}],
          neighbors: [
            "workspace:ws_other",
            "user:ou_admin",
            "chat:oc_legal",
            "adapter:feishu:app_x"
          ],
          metadata: %{}
        })

      ref = push(socket, "cli_call", %{"arg" => "ws_mixed"})
      assert_reply ref, :ok, response

      cur = response["data"]["current_workspace"]
      # all four entries stay in neighbors_declared as raw strings
      assert "user:ou_admin" in cur["neighbors_declared"]
      assert "chat:oc_legal" in cur["neighbors_declared"]
      assert "adapter:feishu:app_x" in cur["neighbors_declared"]
      assert "workspace:ws_other" in cur["neighbors_declared"]

      # only workspace:<name> would expand into neighbor_workspaces;
      # ws_other isn't registered, so it drops silently
      assert response["data"]["neighbor_workspaces"] == []
    end

    test "register dispatch round-trips metadata + neighbors (PR-F)" do
      {:ok, _, register_sock} =
        EsrWeb.HandlerSocket
        |> socket("cli-test-ws-register", %{})
        |> subscribe_and_join(EsrWeb.CliChannel, "cli:workspace/register")

      payload = %{
        "name" => "ws_round_trip",
        "role" => "dev",
        "chats" => [%{"chat_id" => "oc_rt", "app_id" => "cli_rt"}],
        "neighbors" => ["workspace:ws_other"],
        "metadata" => %{"purpose" => "round-trip test"}
      }

      ref = push(register_sock, "cli_call", payload)
      assert_reply ref, :ok, register_resp
      assert register_resp["data"]["ok"] == true

      # registered workspace should round-trip metadata + neighbors
      {:ok, ws} = WS.get("ws_round_trip")
      assert ws.metadata == %{"purpose" => "round-trip test"}
      assert ws.neighbors == ["workspace:ws_other"]
    end
  end
end
