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

  describe "cli:actors/tree" do
    setup do
      {:ok, _handle1} =
        Esr.Topology.Registry.register(
          "feishu-thread-session",
          %{"thread_id" => "tree-a"},
          ["thread:tree-a", "tmux:tree-a", "cc:tree-a"]
        )

      {:ok, _handle2} =
        Esr.Topology.Registry.register(
          "feishu-app-session",
          %{"app_id" => "tree-b"},
          ["feishu-app:tree-b"]
        )

      on_exit(fn ->
        Esr.Topology.Registry.list_all()
        |> Enum.each(&Esr.Topology.Registry.deactivate/1)
      end)

      {:ok, _, socket} =
        EsrWeb.HandlerSocket
        |> socket("cli-tree", %{})
        |> subscribe_and_join(EsrWeb.CliChannel, "cli:actors/tree")

      %{tree_socket: socket}
    end

    test "groups actors by their topology instantiation", %{tree_socket: socket} do
      ref = push(socket, "cli_call", %{})
      assert_reply ref, :ok, response
      data = response["data"]
      assert is_list(data["topologies"])

      thread = Enum.find(data["topologies"], &(&1["name"] == "feishu-thread-session"))
      app = Enum.find(data["topologies"], &(&1["name"] == "feishu-app-session"))

      assert thread["params"] == %{"thread_id" => "tree-a"}
      assert Enum.sort(thread["peer_ids"]) == ["cc:tree-a", "thread:tree-a", "tmux:tree-a"]
      assert app["params"] == %{"app_id" => "tree-b"}
      assert app["peer_ids"] == ["feishu-app:tree-b"]
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

  describe "cli:run/<name>" do
    setup do
      on_exit(fn ->
        Esr.Topology.Registry.list_all()
        |> Enum.each(&Esr.Topology.Registry.deactivate/1)
      end)

      {:ok, _, socket} =
        EsrWeb.HandlerSocket
        |> socket("cli-run", %{})
        |> subscribe_and_join(EsrWeb.CliChannel, "cli:run/simple-session")

      %{run_socket: socket}
    end

    test "instantiates a one-node artifact and returns the handle",
         %{run_socket: socket} do
      artifact = %{
        "name" => "simple-session",
        "params" => ["thread_id"],
        "nodes" => [
          %{
            "id" => "thread:{{thread_id}}",
            "actor_type" => "feishu_thread_proxy",
            "handler" => "feishu_thread.on_msg",
            "depends_on" => []
          }
        ]
      }

      ref =
        push(socket, "cli_call", %{
          "artifact" => artifact,
          "params" => %{"thread_id" => "run-a"}
        })

      assert_reply ref, :ok, response
      assert response["data"]["name"] == "simple-session"
      assert response["data"]["peer_ids"] == ["thread:run-a"]
      assert match?({:ok, _}, Esr.Topology.Registry.lookup("simple-session",
                                                           %{"thread_id" => "run-a"}))
    end

    test "missing required param returns structured error",
         %{run_socket: socket} do
      artifact = %{
        "name" => "simple-session",
        "params" => ["thread_id"],
        "nodes" => [
          %{
            "id" => "thread:{{thread_id}}",
            "actor_type" => "feishu_thread_proxy",
            "handler" => "feishu_thread.on_msg",
            "depends_on" => []
          }
        ]
      }

      ref = push(socket, "cli_call", %{"artifact" => artifact, "params" => %{}})
      assert_reply ref, :ok, response
      assert response["data"]["error"] =~ "missing_params"
      assert response["data"]["peer_ids"] == []
    end
  end

  describe "cli:stop/<name>" do
    setup do
      peer_ids = ["thread:stop-a", "tmux:stop-a", "cc:stop-a"]

      {:ok, _handle} =
        Esr.Topology.Registry.register(
          "feishu-thread-session",
          %{"thread_id" => "a"},
          peer_ids
        )

      on_exit(fn ->
        Esr.Topology.Registry.list_all()
        |> Enum.each(&Esr.Topology.Registry.deactivate/1)
      end)

      {:ok, _, socket} =
        EsrWeb.HandlerSocket
        |> socket("cli-stop", %{})
        |> subscribe_and_join(EsrWeb.CliChannel, "cli:stop/feishu-thread-session")

      %{stop_socket: socket, peer_ids: peer_ids}
    end

    test "deactivates the named topology and returns its stopped peer ids",
         %{stop_socket: socket, peer_ids: expected_ids} do
      ref =
        push(socket, "cli_call", %{
          "name" => "feishu-thread-session",
          "params" => %{"thread_id" => "a"}
        })

      assert_reply ref, :ok, response

      assert response["data"]["name"] == "feishu-thread-session"
      assert Enum.sort(response["data"]["stopped_peer_ids"]) == Enum.sort(expected_ids)

      refute Enum.any?(
               Esr.Topology.Registry.list_all(),
               fn h -> h.name == "feishu-thread-session" end
             )
    end

    test "stopping a non-existent instantiation returns structured error",
         %{stop_socket: socket} do
      ref =
        push(socket, "cli_call", %{
          "name" => "feishu-thread-session",
          "params" => %{"thread_id" => "does-not-exist"}
        })

      assert_reply ref, :ok, response
      assert response["data"]["error"] == "instantiation not found"
      assert response["data"]["stopped_peer_ids"] == []
    end
  end

  describe "cli:drain" do
    setup do
      # register two topology instantiations so drain has work to do
      :ok =
        Enum.each(
          [
            {"feishu-thread-session", %{"thread_id" => "a"}, ["thread:a", "tmux:a", "cc:a"]},
            {"feishu-app-session", %{"app_id" => "b"}, ["feishu-app:b"]}
          ],
          fn {name, params, peer_ids} ->
            {:ok, _handle} = Esr.Topology.Registry.register(name, params, peer_ids)
          end
        )

      on_exit(fn ->
        # clear everything the test inserted
        Esr.Topology.Registry.list_all()
        |> Enum.each(&Esr.Topology.Registry.deactivate/1)
      end)

      {:ok, _, socket} =
        EsrWeb.HandlerSocket
        |> socket("cli-drain", %{})
        |> subscribe_and_join(EsrWeb.CliChannel, "cli:drain")

      %{drain_socket: socket}
    end

    test "drain deactivates every registered topology", %{drain_socket: socket} do
      initial = length(Esr.Topology.Registry.list_all())
      assert initial >= 2

      ref = push(socket, "cli_call", %{})
      assert_reply ref, :ok, response

      data = response["data"]
      assert data["drained"] == initial
      assert data["timeouts"] == []
      assert Esr.Topology.Registry.list_all() == []
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
end
