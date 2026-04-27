defmodule Esr.TopologyTest do
  @moduledoc """
  Spec 2026-04-27 actor-topology-routing §4 + §6.

  Covers:
   - chat_uri / user_uri / adapter_uri builders match path-style
     RESTful shape and `Esr.Uri.parse` round-trips them.
   - symmetric_closure/0: workspace:X edge produces reverse-direction
     reachability for each chat under ws_A and ws_X.
   - neighbour_set/1: returns the closed set; unknown workspace
     yields empty set.
   - initial_seed/3: own chat + adapter + neighbours; nil adapter
     omitted; unknown workspace seeds with own chat alone.
   - resolve_neighbour_entry: chat: / user: / adapter: forms expand;
     malformed entries dropped silently (warn-logged).
  """
  use ExUnit.Case, async: false

  alias Esr.Topology
  alias Esr.Workspaces.Registry, as: WS

  setup do
    # Clean any existing workspaces; ETS table is shared across tests.
    for {name, _} <- :ets.tab2list(:esr_workspaces), do: :ets.delete(:esr_workspaces, name)

    on_exit(fn ->
      for {name, _} <- :ets.tab2list(:esr_workspaces), do: :ets.delete(:esr_workspaces, name)
    end)

    :ok
  end

  describe "URI builders" do
    test "chat_uri/2 builds path-style chat URI" do
      assert Topology.chat_uri("ws_dev", "oc_xxx") ==
               "esr://localhost/workspaces/ws_dev/chats/oc_xxx"
    end

    test "user_uri/1 builds path-style user URI" do
      assert Topology.user_uri("ou_abc") == "esr://localhost/users/ou_abc"
    end

    test "adapter_uri/2 builds path-style adapter URI" do
      assert Topology.adapter_uri("feishu", "app_dev") ==
               "esr://localhost/adapters/feishu/app_dev"
    end

    test "all builders produce parseable Esr.Uri values" do
      for uri <- [
            Topology.chat_uri("ws_dev", "oc_xxx"),
            Topology.user_uri("ou_abc"),
            Topology.adapter_uri("feishu", "app_dev")
          ] do
        assert {:ok, _} = Esr.Uri.parse(uri)
      end
    end
  end

  describe "symmetric_closure/0" do
    test "empty registry yields empty closure" do
      assert Topology.symmetric_closure() == %{}
    end

    test "ws with no neighbours yields entry-less closure (no edges)" do
      :ok =
        WS.put(%WS.Workspace{
          name: "ws_dev",
          chats: [%{"chat_id" => "oc_dev", "app_id" => "cli_dev", "kind" => "group"}],
          neighbors: []
        })

      assert Topology.symmetric_closure() == %{}
    end

    test "workspace:<other> declaration produces both forward and reverse edges" do
      :ok =
        WS.put(%WS.Workspace{
          name: "ws_dev",
          chats: [%{"chat_id" => "oc_dev", "app_id" => "cli_dev", "kind" => "group"}],
          neighbors: ["workspace:ws_kanban"]
        })

      :ok =
        WS.put(%WS.Workspace{
          name: "ws_kanban",
          chats: [%{"chat_id" => "oc_kanban", "app_id" => "cli_kanban", "kind" => "group"}],
          neighbors: []
        })

      closure = Topology.symmetric_closure()

      # Forward: ws_dev sees ws_kanban's chat.
      assert MapSet.member?(
               closure["ws_dev"],
               "esr://localhost/workspaces/ws_kanban/chats/oc_kanban"
             )

      # Reverse: ws_kanban sees ws_dev's chat (because ws_dev declared the edge).
      assert MapSet.member?(
               closure["ws_kanban"],
               "esr://localhost/workspaces/ws_dev/chats/oc_dev"
             )
    end

    test "workspace:<unknown> declaration is dropped without crashing" do
      :ok =
        WS.put(%WS.Workspace{
          name: "ws_dev",
          chats: [%{"chat_id" => "oc_dev", "app_id" => "cli_dev", "kind" => "group"}],
          neighbors: ["workspace:ws_does_not_exist"]
        })

      closure = Topology.symmetric_closure()
      assert Map.get(closure, "ws_dev", MapSet.new()) == MapSet.new()
    end

    test "user:<open_id> entry expands without implicit reverse edge" do
      :ok =
        WS.put(%WS.Workspace{
          name: "ws_dev",
          chats: [%{"chat_id" => "oc_dev", "app_id" => "cli_dev"}],
          neighbors: ["user:ou_admin"]
        })

      closure = Topology.symmetric_closure()
      assert MapSet.member?(closure["ws_dev"], "esr://localhost/users/ou_admin")
      # No reverse edge because user is not a workspace.
      refute Map.has_key?(closure, "ou_admin")
    end

    test "adapter:<platform>:<id> entry expands to adapter URI" do
      :ok =
        WS.put(%WS.Workspace{
          name: "ws_dev",
          chats: [%{"chat_id" => "oc_dev", "app_id" => "cli_dev"}],
          neighbors: ["adapter:feishu:app_other"]
        })

      closure = Topology.symmetric_closure()

      assert MapSet.member?(
               closure["ws_dev"],
               "esr://localhost/adapters/feishu/app_other"
             )
    end

    test "chat:<chat_id> resolves via reverse-lookup of owning workspace" do
      :ok =
        WS.put(%WS.Workspace{
          name: "ws_legal",
          chats: [%{"chat_id" => "oc_legal_special", "app_id" => "cli_legal"}],
          neighbors: []
        })

      :ok =
        WS.put(%WS.Workspace{
          name: "ws_dev",
          chats: [%{"chat_id" => "oc_dev", "app_id" => "cli_dev"}],
          neighbors: ["chat:oc_legal_special"]
        })

      closure = Topology.symmetric_closure()

      assert MapSet.member?(
               closure["ws_dev"],
               "esr://localhost/workspaces/ws_legal/chats/oc_legal_special"
             )
    end
  end

  describe "neighbour_set/1" do
    test "unknown workspace yields empty set" do
      assert Topology.neighbour_set("ws_nonexistent") == MapSet.new()
    end

    test "returns the closed set for a known workspace" do
      :ok =
        WS.put(%WS.Workspace{
          name: "ws_a",
          chats: [%{"chat_id" => "oc_a"}],
          neighbors: ["workspace:ws_b"]
        })

      :ok =
        WS.put(%WS.Workspace{
          name: "ws_b",
          chats: [%{"chat_id" => "oc_b"}],
          neighbors: []
        })

      neighbours_a = Topology.neighbour_set("ws_a")
      neighbours_b = Topology.neighbour_set("ws_b")

      assert MapSet.size(neighbours_a) >= 1
      assert MapSet.size(neighbours_b) >= 1
    end
  end

  describe "initial_seed/3" do
    test "includes own chat + adapter + neighbours" do
      :ok =
        WS.put(%WS.Workspace{
          name: "ws_dev",
          chats: [%{"chat_id" => "oc_dev"}],
          neighbors: ["user:ou_admin"]
        })

      seed =
        Topology.initial_seed(
          "ws_dev",
          Topology.chat_uri("ws_dev", "oc_dev"),
          Topology.adapter_uri("feishu", "cli_dev")
        )

      assert MapSet.member?(seed, "esr://localhost/workspaces/ws_dev/chats/oc_dev")
      assert MapSet.member?(seed, "esr://localhost/adapters/feishu/cli_dev")
      assert MapSet.member?(seed, "esr://localhost/users/ou_admin")
    end

    test "nil adapter is omitted" do
      :ok =
        WS.put(%WS.Workspace{name: "ws_dev", chats: [%{"chat_id" => "oc_dev"}], neighbors: []})

      chat_uri = Topology.chat_uri("ws_dev", "oc_dev")
      seed = Topology.initial_seed("ws_dev", chat_uri, nil)

      assert MapSet.member?(seed, chat_uri)
      assert MapSet.size(seed) == 1
    end

    test "unknown workspace seeds with own chat + adapter only" do
      seed =
        Topology.initial_seed(
          "ws_unknown",
          "esr://localhost/workspaces/ws_unknown/chats/oc_x",
          "esr://localhost/adapters/feishu/cli_x"
        )

      assert MapSet.size(seed) == 2
    end
  end
end
