defmodule Esr.TopologyIntegrationTest do
  @moduledoc """
  Spec 2026-04-27 actor-topology-routing — end-to-end-ish integration
  test exercising the C1→C5 chain on a single CC peer:

      yaml seed → Workspaces.Registry → Topology.initial_seed
        → CC peer state → inbound (FCP-style) → BGP learn
        → build_channel_notification renders <reachable> in tag

  Higher fidelity than the per-module unit tests (it composes the
  real stack) but lighter than scenario 04 (no Python, no claude
  round-trip). Intended as the post-merge regression pin for the
  full topology routing chain. The scenario-level e2e — exercising
  cross-app routing through topology with a real claude turn — is
  scenario 05 (deferred to PR-D, see issue #57 follow-up).
  """
  use ExUnit.Case, async: false

  alias Esr.Entities.CCProcess
  alias Esr.Topology
  alias Esr.Workspaces.Registry, as: WS

  setup do
    for {name, _} <- :ets.tab2list(:esr_workspaces), do: :ets.delete(:esr_workspaces, name)

    on_exit(fn ->
      for {name, _} <- :ets.tab2list(:esr_workspaces), do: :ets.delete(:esr_workspaces, name)
    end)

    :ok
  end

  test "yaml topology → initial_seed → CC peer reachable_set → tag renders <reachable>" do
    # 1. Seed workspaces.yaml shape — ws_dev with ws_kanban as neighbour.
    :ok =
      WS.put(%WS.Workspace{
        name: "ws_dev",
        chats: [%{"chat_id" => "oc_dev_room", "app_id" => "cli_dev", "name" => "dev-room"}],
        neighbors: ["workspace:ws_kanban", "user:ou_admin"]
      })

    :ok =
      WS.put(%WS.Workspace{
        name: "ws_kanban",
        chats: [%{"chat_id" => "oc_kanban_room", "app_id" => "cli_kanban", "name" => "kanban-room"}],
        neighbors: []
      })

    # 2. Sanity-check the topology layer.
    seed =
      Topology.initial_seed(
        "ws_dev",
        Topology.chat_uri("ws_dev", "oc_dev_room"),
        Topology.adapter_uri("feishu", "cli_dev")
      )

    assert MapSet.member?(seed, "esr://localhost/workspaces/ws_dev/chats/oc_dev_room")
    assert MapSet.member?(seed, "esr://localhost/workspaces/ws_kanban/chats/oc_kanban_room")
    assert MapSet.member?(seed, "esr://localhost/users/ou_admin")
    assert MapSet.member?(seed, "esr://localhost/adapters/feishu/cli_dev")

    # 3. Boot a CC peer carrying that proxy_ctx so init/1 picks up the
    #    same seed via build_initial_reachable_set/1.
    me = self()
    pty = spawn_link(fn -> relay(me) end)
    cc_proxy = spawn_link(fn -> relay(me) end)

    {:ok, pid} =
      CCProcess.start_link(%{
        session_id: "topo_int_session",
        handler_module: "cc_adapter_runner",
        neighbors: [pty_process: pty, cc_proxy: cc_proxy],
        proxy_ctx: %{
          "channel_adapter" => "feishu",
          workspace_name: "ws_dev",
          chat_id: "oc_dev_room",
          app_id: "cli_dev"
        }
      })

    state = :sys.get_state(pid)
    assert MapSet.size(state.reachable_set) == 4

    # 4. Stash a meta map so build_channel_notification has data
    #    (mimicking what stash_upstream_meta would do on real inbound).
    state =
      Map.put(state, :last_meta, %{
        chat_id: "oc_dev_room",
        app_id: "cli_dev",
        thread_id: "",
        message_id: "om_int",
        sender_id: "ou_admin"
      })

    env = CCProcess.build_channel_notification(state, "hello")

    # 5. Tag content assertions per spec §8.
    assert env["chat_id"] == "oc_dev_room"
    assert env["app_id"] == "cli_dev"
    assert env["user_id"] == "ou_admin"
    assert env["workspace"] == "ws_dev"
    # PR-D D2: reachable encoded as JSON-string attribute.
    assert is_binary(env["reachable"])
    decoded = Jason.decode!(env["reachable"])

    uris = Enum.map(decoded, & &1["uri"])
    assert "esr://localhost/workspaces/ws_kanban/chats/oc_kanban_room" in uris
    assert "esr://localhost/users/ou_admin" in uris

    # 6. The kanban chat URI's display name resolves from yaml (chats[].name).
    kanban_actor =
      Enum.find(
        decoded,
        &(&1["uri"] == "esr://localhost/workspaces/ws_kanban/chats/oc_kanban_room")
      )

    assert kanban_actor["name"] == "kanban-room"

    # 7. BGP learn — simulate a cross-app inbound delivering a NEW URI.
    new_meta = %{
      chat_id: "oc_dev_room",
      app_id: "cli_dev",
      sender_id: "ou_visitor",
      message_id: "om_int_2",
      thread_id: "",
      source: "esr://localhost/adapters/feishu/cli_other_app",
      principal_id: "ou_visitor"
    }

    send(pid, {:text, "follow-up", new_meta})

    # The handler-router timeout is 5s default; we don't have a router
    # running so wait briefly to allow the learning hook to fire before
    # it errors out.
    Process.sleep(80)

    state2 = :sys.get_state(pid)
    assert MapSet.member?(state2.reachable_set, "esr://localhost/adapters/feishu/cli_other_app")
    assert MapSet.member?(state2.reachable_set, "esr://localhost/users/ou_visitor")
  end

  defp relay(reply_to) do
    receive do
      msg ->
        send(reply_to, {:relay, msg})
        relay(reply_to)
    end
  end
end
