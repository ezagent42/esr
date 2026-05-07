defmodule Esr.Commands.Workspace.InfoTest do
  use ExUnit.Case, async: false

  alias Esr.Commands.Workspace.Info, as: WorkspaceInfo

  setup do
    assert is_pid(Process.whereis(Esr.Resource.Workspace.Registry))

    on_exit(fn ->
      :ets.delete(:esr_workspaces, "ws_info_test")
    end)

    :ok
  end

  test "returns the workspace record when present" do
    :ok =
      Esr.Resource.Workspace.Registry.put(%Esr.Resource.Workspace.Registry.Workspace{
        name: "ws_info_test",
        owner: "linyilun",
        role: "dev",
        start_cmd: "claude",
        chats: [%{"chat_id" => "oc_a", "app_id" => "cli_x", "kind" => "dm"}],
        env: %{},
        neighbors: ["workspace:other-ws"],
        metadata: %{"purpose" => "test"}
      })

    cmd = %{"submitted_by" => "ou_test", "args" => %{"workspace" => "ws_info_test"}}

    assert {:ok, info} = WorkspaceInfo.execute(cmd)
    assert info["name"] == "ws_info_test"
    assert info["owner"] == "linyilun"
    # PR-22: workspace no longer carries `root:` — repo is per-session.
    refute Map.has_key?(info, "root")
    assert info["role"] == "dev"
    assert info["chats"] == [%{"chat_id" => "oc_a", "app_id" => "cli_x", "kind" => "dm"}]
    assert info["neighbors"] == ["workspace:other-ws"]
    assert info["metadata"] == %{"purpose" => "test"}
  end

  test "unknown workspace → error" do
    cmd = %{"submitted_by" => "ou_test", "args" => %{"workspace" => "nonexistent_ws_xyz"}}
    assert {:error, %{"type" => "unknown_workspace"}} = WorkspaceInfo.execute(cmd)
  end

  test "missing args.workspace → invalid_args" do
    cmd = %{"submitted_by" => "ou_test", "args" => %{}}
    assert {:error, %{"type" => "invalid_args"}} = WorkspaceInfo.execute(cmd)
  end

  test "empty workspace string → invalid_args" do
    cmd = %{"submitted_by" => "ou_test", "args" => %{"workspace" => ""}}
    assert {:error, %{"type" => "invalid_args"}} = WorkspaceInfo.execute(cmd)
  end

  describe "new struct fields" do
    setup do
      unique = System.unique_integer([:positive])
      ws_name = "ws_info_struct_#{unique}"

      on_exit(fn ->
        :ets.delete(:esr_workspaces, ws_name)
      end)

      {:ok, ws_name: ws_name, unique: unique}
    end

    test "new struct fields are surfaced when put via %Struct{}", %{ws_name: ws_name} do
      ws_id = UUID.uuid4()

      :ok =
        Esr.Resource.Workspace.Registry.put(%Esr.Resource.Workspace.Struct{
          id: ws_id,
          name: ws_name,
          owner: "alice",
          agent: "cc",
          folders: [%{path: "/some/repo", name: "repo"}],
          settings: %{
            "cc.model" => "claude-sonnet-4-6",
            "_legacy.role" => "dev",
            "_legacy.neighbors" => [],
            "_legacy.metadata" => %{}
          },
          env: %{"FOO" => "bar"},
          chats: [%{chat_id: "oc_b", app_id: "cli_z", kind: "dm"}],
          transient: false,
          location: nil
        })

      cmd = %{"submitted_by" => "ou_test", "args" => %{"workspace" => ws_name}}

      assert {:ok, info} = WorkspaceInfo.execute(cmd)

      # New struct fields
      assert info["id"] == ws_id
      assert info["agent"] == "cc"
      assert info["folders"] == [%{"path" => "/some/repo", "name" => "repo"}]
      assert info["env"] == %{"FOO" => "bar"}
      assert info["transient"] == false
      # location: nil → encoded as nil (no esr_bound dir to write)
      assert is_nil(info["location"]) or is_binary(info["location"])

      # _legacy.* keys must NOT appear in settings
      refute Map.has_key?(info["settings"], "_legacy.role")
      refute Map.has_key?(info["settings"], "_legacy.neighbors")
      refute Map.has_key?(info["settings"], "_legacy.metadata")

      # Non-legacy settings are preserved
      assert info["settings"]["cc.model"] == "claude-sonnet-4-6"
    end

    test "legacy fields still surfaced from _legacy.* stash when put via legacy Workspace",
         %{ws_name: ws_name} do
      :ok =
        Esr.Resource.Workspace.Registry.put(%Esr.Resource.Workspace.Registry.Workspace{
          name: ws_name,
          owner: "bob",
          role: "kanban",
          start_cmd: "",
          chats: [],
          env: %{},
          neighbors: ["workspace:esr-kanban"],
          metadata: %{"purpose" => "kanban board"}
        })

      cmd = %{"submitted_by" => "ou_test", "args" => %{"workspace" => ws_name}}

      assert {:ok, info} = WorkspaceInfo.execute(cmd)
      assert info["role"] == "kanban"
      assert info["neighbors"] == ["workspace:esr-kanban"]
      assert info["metadata"] == %{"purpose" => "kanban board"}
    end

    test "args.name alias accepted in place of args.workspace", %{ws_name: ws_name} do
      :ok =
        Esr.Resource.Workspace.Registry.put(%Esr.Resource.Workspace.Registry.Workspace{
          name: ws_name,
          owner: "carol",
          role: "dev",
          chats: [],
          env: %{},
          neighbors: [],
          metadata: %{}
        })

      cmd = %{"submitted_by" => "ou_test", "args" => %{"name" => ws_name}}

      assert {:ok, info} = WorkspaceInfo.execute(cmd)
      assert info["name"] == ws_name
      assert info["owner"] == "carol"
    end

    test "topology overlay included when topology.yaml present", %{unique: unique} do
      tmp_repo = Path.join(System.tmp_dir!(), "topo_test_repo_#{unique}")
      esr_dir = Path.join(tmp_repo, ".esr")
      File.mkdir_p!(esr_dir)

      File.write!(Path.join(esr_dir, "topology.yaml"), """
      description: test topology
      nodes:
        - name: alpha
      """)

      ws_name = "ws_topo_present_#{unique}"

      on_exit(fn ->
        File.rm_rf!(tmp_repo)
        :ets.delete(:esr_workspaces, ws_name)
      end)

      ws_id = UUID.uuid4()

      :ok =
        Esr.Resource.Workspace.Registry.put(%Esr.Resource.Workspace.Struct{
          id: ws_id,
          name: ws_name,
          owner: "dave",
          agent: "cc",
          folders: [%{path: tmp_repo, name: "repo"}],
          settings: %{},
          env: %{},
          chats: [],
          transient: false,
          location: {:repo_bound, tmp_repo}
        })

      cmd = %{"submitted_by" => "ou_test", "args" => %{"workspace" => ws_name}}

      assert {:ok, info} = WorkspaceInfo.execute(cmd)
      assert is_map(info["topology"])
      assert info["topology"]["description"] == "test topology"
      assert is_list(info["topology"]["nodes"])
    end

    test "topology overlay nil when folders empty or topology.yaml absent", %{unique: unique} do
      tmp_repo = Path.join(System.tmp_dir!(), "topo_test_absent_#{unique}")
      File.mkdir_p!(tmp_repo)
      # No .esr/topology.yaml created

      ws_name_no_folders = "ws_topo_no_folders_#{unique}"
      ws_name_no_yaml = "ws_topo_no_yaml_#{unique}"

      on_exit(fn ->
        File.rm_rf!(tmp_repo)
        :ets.delete(:esr_workspaces, ws_name_no_folders)
        :ets.delete(:esr_workspaces, ws_name_no_yaml)
      end)

      # Workspace with empty folders list
      :ok =
        Esr.Resource.Workspace.Registry.put(%Esr.Resource.Workspace.Struct{
          id: UUID.uuid4(),
          name: ws_name_no_folders,
          owner: "eve",
          agent: "cc",
          folders: [],
          settings: %{},
          env: %{},
          chats: [],
          transient: false,
          location: nil
        })

      cmd_no_folders = %{
        "submitted_by" => "ou_test",
        "args" => %{"workspace" => ws_name_no_folders}
      }

      assert {:ok, info_no_folders} = WorkspaceInfo.execute(cmd_no_folders)
      assert info_no_folders["topology"] == nil

      # Workspace with a folder but no topology.yaml in that folder
      :ok =
        Esr.Resource.Workspace.Registry.put(%Esr.Resource.Workspace.Struct{
          id: UUID.uuid4(),
          name: ws_name_no_yaml,
          owner: "eve",
          agent: "cc",
          folders: [%{path: tmp_repo, name: "repo"}],
          settings: %{},
          env: %{},
          chats: [],
          transient: false,
          location: {:repo_bound, tmp_repo}
        })

      cmd_no_yaml = %{
        "submitted_by" => "ou_test",
        "args" => %{"workspace" => ws_name_no_yaml}
      }

      assert {:ok, info_no_yaml} = WorkspaceInfo.execute(cmd_no_yaml)
      assert info_no_yaml["topology"] == nil
    end
  end
end
