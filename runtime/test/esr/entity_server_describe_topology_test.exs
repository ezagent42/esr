defmodule Esr.EntityServerDescribeTopologyTest do
  @moduledoc """
  PR-21z (2026-04-30) — security regression tests for the
  `describe_topology` MCP tool's response filter.

  `Esr.Entity.Server.build_emit_for_tool("describe_topology", ...)` is
  the only response builder that returns workspace yaml data verbatim
  to the LLM. Its allowlist (`filter_workspace_for_describe/1`) is a
  **security boundary** — operators put `metadata` keys like
  `purpose`, `pipeline_position` there for the LLM to read, but
  `owner`, `start_cmd`, `env`, and `users.yaml` data must NEVER leak.

  These tests pin the response shape so adding a new field to
  `%Workspace{}` won't accidentally pass through. If a future
  contributor needs to expose a new field, the right path is:

    1. Update `filter_workspace_for_describe/1` (explicit add)
    2. Add a regression test asserting the field IS present
    3. Update this file's "must not leak" list if relevant

  See peer_server.ex `filter_workspace_for_describe/1` comment for
  the rationale on each excluded field.
  """

  use ExUnit.Case, async: false

  alias Esr.Entity
  alias Esr.Resource.Workspace.Registry, as: WsReg
  alias Esr.Resource.Workspace.Struct

  # WsReg has no `delete/1` API — cleanup is by uniqueness of test
  # workspace names (the `ws_audit_*` prefix). The boot tree's
  # WsReg + Watcher persist across tests; that's fine, we only care
  # about the rows we insert here.

  defp peer_state do
    %Entity.Server{
      actor_id: "test-actor",
      actor_type: "cc_process",
      handler_module: "noop",
      state: %{}
    }
  end

  test "response includes only the allowlisted workspace fields" do
    :ok =
      WsReg.put(%WsReg.Workspace{
        name: "ws_audit_1",
        owner: "linyilun",
        role: "dev",
        start_cmd: "scripts/secret-launch.sh",
        env: %{"AWS_SECRET" => "should-not-leak"},
        chats: [
          %{
            "chat_id" => "oc_1",
            "app_id" => "app_a",
            "kind" => "dm",
            "name" => "alice"
          }
        ],
        neighbors: ["workspace:ws_audit_2"],
        metadata: %{"purpose" => "ingestion", "pipeline_position" => "head"}
      })

    {:ok, :direct_ack, %{"data" => data}} =
      Entity.Server.build_emit_for_tool_for_test(
        "describe_topology",
        %{"workspace_name" => "ws_audit_1"},
        peer_state()
      )

    current = data["current_workspace"]
    keys = Map.keys(current) |> Enum.sort()

    # Phase 7.1 adds "topology_overlay" (boolean) to the allowlist.
    # "description" is only present when topology.yaml provides it, so it
    # does NOT appear here (ws_audit_1 has no folders → no topology.yaml).
    assert keys == [
             "chats",
             "metadata",
             "name",
             "neighbors_declared",
             "role",
             "topology_overlay"
           ]
  end

  test "owner field is filtered out (esr-username is sensitive identity material)" do
    :ok =
      WsReg.put(%WsReg.Workspace{
        name: "ws_audit_owner",
        owner: "linyilun",
        chats: []
      })

    {:ok, :direct_ack, %{"data" => data}} =
      Entity.Server.build_emit_for_tool_for_test(
        "describe_topology",
        %{"workspace_name" => "ws_audit_owner"},
        peer_state()
      )

    refute Map.has_key?(data["current_workspace"], "owner")
    refute serialize(data) =~ "linyilun"
  end

  test "start_cmd / env are filtered out (operator config)" do
    :ok =
      WsReg.put(%WsReg.Workspace{
        name: "ws_audit_cmd",
        owner: "linyilun",
        start_cmd: "/usr/local/bin/launch.sh --token AKIASOMETHING",
        env: %{"PROD_API_KEY" => "do-not-leak"},
        chats: []
      })

    {:ok, :direct_ack, %{"data" => data}} =
      Entity.Server.build_emit_for_tool_for_test(
        "describe_topology",
        %{"workspace_name" => "ws_audit_cmd"},
        peer_state()
      )

    refute Map.has_key?(data["current_workspace"], "start_cmd")
    refute Map.has_key?(data["current_workspace"], "env")
    refute serialize(data) =~ "AKIASOMETHING"
    refute serialize(data) =~ "PROD_API_KEY"
    refute serialize(data) =~ "do-not-leak"
  end

  test "chats sub-map is also allowlisted (no surprise nested fields)" do
    :ok =
      WsReg.put(%WsReg.Workspace{
        name: "ws_audit_chats",
        owner: "linyilun",
        chats: [
          %{
            "chat_id" => "oc_1",
            "app_id" => "app_a",
            "kind" => "dm",
            "name" => "alice",
            "metadata" => %{"label" => "primary"},
            # Hypothetical future field that mustn't leak
            "feishu_user_ids" => ["ou_should_not_leak"],
            "secret_token" => "do-not-leak-this-either"
          }
        ]
      })

    {:ok, :direct_ack, %{"data" => data}} =
      Entity.Server.build_emit_for_tool_for_test(
        "describe_topology",
        %{"workspace_name" => "ws_audit_chats"},
        peer_state()
      )

    [chat] = data["current_workspace"]["chats"]
    keys = Map.keys(chat) |> Enum.sort()
    assert keys == ["app_id", "chat_id", "kind", "metadata", "name"]
    refute serialize(data) =~ "ou_should_not_leak"
    refute serialize(data) =~ "do-not-leak-this-either"
  end

  test "users.yaml data is never reachable via describe_topology" do
    # Sanity check: even if Esr.Entity.User.Registry has bindings, the
    # describe_topology response builder doesn't read from it. This
    # test sets up users + workspaces + asserts no feishu_id appears
    # anywhere in the response payload.
    if Process.whereis(Esr.Entity.User.Registry) do
      Esr.Entity.User.Registry.load_snapshot(%{
        "linyilun" => %Esr.Entity.User.Registry.User{
          username: "linyilun",
          feishu_ids: ["ou_secret_open_id_xyz"]
        }
      })
    end

    :ok =
      WsReg.put(%WsReg.Workspace{
        name: "ws_audit_users",
        owner: "linyilun",
        chats: [%{"chat_id" => "oc_1", "app_id" => "app_a", "kind" => "dm"}]
      })

    {:ok, :direct_ack, %{"data" => data}} =
      Entity.Server.build_emit_for_tool_for_test(
        "describe_topology",
        %{"workspace_name" => "ws_audit_users"},
        peer_state()
      )

    refute serialize(data) =~ "ou_secret_open_id_xyz"
    refute serialize(data) =~ "feishu_id"
  end

  ## Phase 7.1 — topology.yaml overlay tests --------------------------------

  describe "topology.yaml overlay (Phase 7.1)" do
    # Helper: build a %Struct{} pointing at a given tmp dir.
    defp struct_with_folder(name, folder_path, extra_settings \\ %{}) do
      %Struct{
        id: UUID.uuid4(),
        name: name,
        owner: "test-owner",
        folders: [%{path: folder_path, name: "main"}],
        agent: "cc",
        settings:
          Map.merge(
            %{
              "_legacy.role" => "dev",
              "_legacy.neighbors" => [],
              "_legacy.metadata" => %{}
            },
            extra_settings
          ),
        env: %{},
        chats: [],
        transient: false,
        location: {:esr_bound, "/tmp/esr-test/#{name}"}
      }
    end

    defp write_topology(folder_path, content) do
      esr_dir = Path.join(folder_path, ".esr")
      File.mkdir_p!(esr_dir)
      File.write!(Path.join(esr_dir, "topology.yaml"), content)
    end

    test "description from topology.yaml is merged into response" do
      dir = System.tmp_dir!() |> Path.join("esr-overlay-desc-#{:os.getpid()}")
      File.mkdir_p!(dir)

      write_topology(dir, """
      description: "test desc from topology"
      """)

      ws = struct_with_folder("ws_overlay_desc", dir)
      :ok = WsReg.put(ws)

      {:ok, :direct_ack, %{"data" => data}} =
        Entity.Server.build_emit_for_tool_for_test(
          "describe_topology",
          %{"workspace_name" => "ws_overlay_desc"},
          peer_state()
        )

      current = data["current_workspace"]
      assert current["description"] == "test desc from topology"
      assert current["topology_overlay"] == true
    after
      File.rm_rf(System.tmp_dir!() |> Path.join("esr-overlay-desc-#{:os.getpid()}"))
    end

    test "metadata from topology.yaml is unioned; overlay takes precedence on conflicts" do
      dir = System.tmp_dir!() |> Path.join("esr-overlay-meta-#{:os.getpid()}")
      File.mkdir_p!(dir)

      write_topology(dir, """
      metadata:
        b: from_overlay
        c: from_overlay
      """)

      ws =
        struct_with_folder("ws_overlay_meta", dir, %{
          "_legacy.metadata" => %{"a" => "from_struct", "b" => "from_struct"}
        })

      :ok = WsReg.put(ws)

      {:ok, :direct_ack, %{"data" => data}} =
        Entity.Server.build_emit_for_tool_for_test(
          "describe_topology",
          %{"workspace_name" => "ws_overlay_meta"},
          peer_state()
        )

      meta = data["current_workspace"]["metadata"]
      assert meta["a"] == "from_struct"
      assert meta["b"] == "from_overlay"
      assert meta["c"] == "from_overlay"
      assert data["current_workspace"]["topology_overlay"] == true
    after
      File.rm_rf(System.tmp_dir!() |> Path.join("esr-overlay-meta-#{:os.getpid()}"))
    end

    test "neighbors from topology.yaml are unioned and deduplicated" do
      dir = System.tmp_dir!() |> Path.join("esr-overlay-nbrs-#{:os.getpid()}")
      File.mkdir_p!(dir)

      write_topology(dir, """
      neighbors:
        - workspace:ws-other-2
        - workspace:ws-other-1
      """)

      ws =
        struct_with_folder("ws_overlay_nbrs", dir, %{
          "_legacy.neighbors" => ["workspace:ws-other-1"]
        })

      :ok = WsReg.put(ws)

      {:ok, :direct_ack, %{"data" => data}} =
        Entity.Server.build_emit_for_tool_for_test(
          "describe_topology",
          %{"workspace_name" => "ws_overlay_nbrs"},
          peer_state()
        )

      declared = data["current_workspace"]["neighbors_declared"]
      assert "workspace:ws-other-1" in declared
      assert "workspace:ws-other-2" in declared
      # Dedup: ws-other-1 appears in both struct and overlay — only once
      assert Enum.count(declared, &(&1 == "workspace:ws-other-1")) == 1
      assert data["current_workspace"]["topology_overlay"] == true
    after
      File.rm_rf(System.tmp_dir!() |> Path.join("esr-overlay-nbrs-#{:os.getpid()}"))
    end

    test "topology.yaml absent → topology_overlay=false, no description key" do
      dir = System.tmp_dir!() |> Path.join("esr-overlay-absent-#{:os.getpid()}")
      File.mkdir_p!(dir)
      # No .esr/topology.yaml written

      ws = struct_with_folder("ws_overlay_absent", dir)
      :ok = WsReg.put(ws)

      {:ok, :direct_ack, %{"data" => data}} =
        Entity.Server.build_emit_for_tool_for_test(
          "describe_topology",
          %{"workspace_name" => "ws_overlay_absent"},
          peer_state()
        )

      current = data["current_workspace"]
      assert current["topology_overlay"] == false
      refute Map.has_key?(current, "description")
    after
      File.rm_rf(System.tmp_dir!() |> Path.join("esr-overlay-absent-#{:os.getpid()}"))
    end

    test "malformed topology.yaml → silent fallback, topology_overlay=false" do
      dir = System.tmp_dir!() |> Path.join("esr-overlay-bad-#{:os.getpid()}")
      File.mkdir_p!(dir)
      write_topology(dir, ":::this is not valid yaml:::\n\t\tbad: [unclosed")

      ws = struct_with_folder("ws_overlay_bad", dir)
      :ok = WsReg.put(ws)

      # Must not raise or return error
      result =
        Entity.Server.build_emit_for_tool_for_test(
          "describe_topology",
          %{"workspace_name" => "ws_overlay_bad"},
          peer_state()
        )

      assert {:ok, :direct_ack, %{"data" => data}} = result
      assert data["current_workspace"]["topology_overlay"] == false
      refute Map.has_key?(data["current_workspace"], "description")
    after
      File.rm_rf(System.tmp_dir!() |> Path.join("esr-overlay-bad-#{:os.getpid()}"))
    end
  end

  defp serialize(term), do: inspect(term, limit: :infinity, printable_limit: :infinity)
end
