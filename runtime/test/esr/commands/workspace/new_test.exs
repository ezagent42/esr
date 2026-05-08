defmodule Esr.Commands.Workspace.NewTest do
  use ExUnit.Case, async: false

  alias Esr.Commands.Workspace.New, as: WorkspaceNew

  setup do
    assert is_pid(Process.whereis(Esr.Resource.Workspace.Registry))

    if Process.whereis(Esr.Entity.User.Registry) == nil do
      start_supervised!(Esr.Entity.User.Registry)
    end

    Esr.Entity.User.Registry.load_snapshot(%{
      "linyilun" => %Esr.Entity.User.Registry.User{
        username: "linyilun",
        feishu_ids: ["ou_known"]
      }
    })

    # Isolate workspace storage to a tmp dir
    unique = System.unique_integer([:positive])
    tmp = Path.join(System.tmp_dir!(), "ws_new_test_#{unique}")
    File.mkdir_p!(Path.join(tmp, "default"))
    prev_home = System.get_env("ESRD_HOME")
    System.put_env("ESRD_HOME", tmp)

    on_exit(fn ->
      if prev_home,
        do: System.put_env("ESRD_HOME", prev_home),
        else: System.delete_env("ESRD_HOME")

      File.rm_rf!(tmp)
      Esr.Entity.User.Registry.load_snapshot(%{})
      Esr.Test.WorkspaceFixture.reset!()
      Esr.Resource.Workspace.Bootstrap.run()
    end)

    {:ok, tmp: tmp}
  end

  # ---------------------------------------------------------------------------
  # Happy-path: ESR-bound creation
  # ---------------------------------------------------------------------------

  test "creates ESR-bound workspace and writes workspace.json", %{tmp: tmp} do
    cmd = %{
      "submitted_by" => "ou_known",
      "args" => %{
        "name" => "test-ws-1",
        "owner" => "linyilun",
        "chat_id" => "oc_test1",
        "app_id" => "cli_test"
      }
    }

    assert {:ok, result} = WorkspaceNew.execute(cmd)

    assert result["name"] == "test-ws-1"
    assert result["owner"] == "linyilun"
    assert result["action"] == "created"
    assert result["location"] =~ ~r/^esr:/

    # UUID v4 format
    assert result["id"] =~ ~r/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i

    # Chats serialised to string-keyed maps
    assert result["chats"] == [%{"chat_id" => "oc_test1", "app_id" => "cli_test", "kind" => "dm"}]

    # No "role" or "root" in result (those are legacy yaml fields)
    refute Map.has_key?(result, "role")
    refute Map.has_key?(result, "root")

    # workspace.json written inside ESR-bound dir
    ws_dir = Path.join([tmp, "default", "workspaces", "test-ws-1"])
    json_path = Path.join(ws_dir, "workspace.json")
    assert File.exists?(json_path)
    {:ok, parsed} = Jason.decode(File.read!(json_path))
    assert parsed["name"] == "test-ws-1"
    assert parsed["owner"] == "linyilun"

    # Registry populated proactively
    {:ok, id} =
      Esr.Resource.Workspace.NameIndex.id_for_name(:esr_workspace_name_index, "test-ws-1")

    assert {:ok, ws} = Esr.Resource.Workspace.Registry.get_by_id(id)
    assert ws.owner == "linyilun"

    structs = Esr.Resource.Workspace.Registry.list_all()
    assert Enum.any?(structs, fn s -> s.name == "test-ws-1" end)
  end

  test "owner defaults to args.username (slash-handler resolved)", %{tmp: _tmp} do
    cmd = %{
      "submitted_by" => "ou_known",
      "args" => %{
        "name" => "test-ws-2",
        "username" => "linyilun"
      }
    }

    assert {:ok, %{"owner" => "linyilun"}} = WorkspaceNew.execute(cmd)
  end

  test "no chat_id/app_id args → empty chats list", %{tmp: _tmp} do
    cmd = %{
      "submitted_by" => "ou_known",
      "args" => %{
        "name" => "test-no-chat",
        "owner" => "linyilun"
      }
    }

    assert {:ok, %{"chats" => []}} = WorkspaceNew.execute(cmd)
  end

  test "transient: true is accepted for ESR-bound", %{tmp: _tmp} do
    cmd = %{
      "submitted_by" => "ou_known",
      "args" => %{
        "name" => "test-transient",
        "owner" => "linyilun",
        "transient" => "true"
      }
    }

    assert {:ok, %{"action" => "created"}} = WorkspaceNew.execute(cmd)

    structs = Esr.Resource.Workspace.Registry.list_all()
    ws = Enum.find(structs, fn s -> s.name == "test-transient" end)
    assert ws.transient == true
  end

  # ---------------------------------------------------------------------------
  # Repo-bound creation
  # ---------------------------------------------------------------------------

  test "folder= creates repo-bound workspace + registers path in registered_repos.yaml", %{tmp: tmp} do
    # Create a fake git repo in tmp
    repo_path = Path.join(tmp, "my-repo")
    File.mkdir_p!(Path.join(repo_path, ".git"))

    cmd = %{
      "submitted_by" => "ou_known",
      "args" => %{
        "name" => "repo-ws",
        "owner" => "linyilun",
        "folder" => repo_path,
        "chat_id" => "oc_r1",
        "app_id" => "cli_r"
      }
    }

    assert {:ok, result} = WorkspaceNew.execute(cmd)

    assert result["action"] == "created"
    assert result["location"] == "repo:#{repo_path}"
    assert result["folders"] == [%{"path" => repo_path, "name" => "my-repo"}]

    # workspace.json written to <repo>/.esr/workspace.json
    json_path = Path.join([repo_path, ".esr", "workspace.json"])
    assert File.exists?(json_path)
    {:ok, parsed} = Jason.decode(File.read!(json_path))
    assert parsed["name"] == "repo-ws"

    # registered_repos.yaml updated
    repos_yaml = Esr.Paths.registered_repos_yaml()
    assert File.exists?(repos_yaml)
    {:ok, parsed_yaml} = YamlElixir.read_from_file(repos_yaml)
    paths = Enum.map(parsed_yaml["repos"] || [], & &1["path"])
    assert repo_path in paths
  end

  test "folder= with non-existent path → folder_not_dir error" do
    cmd = %{
      "submitted_by" => "ou_known",
      "args" => %{
        "name" => "bad-folder",
        "owner" => "linyilun",
        "folder" => "/does/not/exist/ever"
      }
    }

    assert {:error, %{"type" => "folder_not_dir", "folder" => "/does/not/exist/ever"}} =
             WorkspaceNew.execute(cmd)
  end

  test "folder= with dir that is not a git repo → folder_not_git_repo error", %{tmp: tmp} do
    not_git = Path.join(tmp, "plain-dir")
    File.mkdir_p!(not_git)

    cmd = %{
      "submitted_by" => "ou_known",
      "args" => %{
        "name" => "bad-git",
        "owner" => "linyilun",
        "folder" => not_git
      }
    }

    assert {:error, %{"type" => "folder_not_git_repo", "folder" => ^not_git}} =
             WorkspaceNew.execute(cmd)
  end

  test "transient: true with folder= → transient_repo_bound_forbidden", %{tmp: tmp} do
    repo_path = Path.join(tmp, "repo-transient")
    File.mkdir_p!(Path.join(repo_path, ".git"))

    cmd = %{
      "submitted_by" => "ou_known",
      "args" => %{
        "name" => "bad-transient",
        "owner" => "linyilun",
        "folder" => repo_path,
        "transient" => "true"
      }
    }

    assert {:error, %{"type" => "transient_repo_bound_forbidden"}} = WorkspaceNew.execute(cmd)
  end

  # ---------------------------------------------------------------------------
  # Validation errors
  # ---------------------------------------------------------------------------

  test "no owner / no username → invalid_args" do
    cmd = %{
      "submitted_by" => "ou_known",
      "args" => %{"name" => "test-ws-x"}
    }

    assert {:error, %{"type" => "invalid_args", "message" => msg}} = WorkspaceNew.execute(cmd)
    assert msg =~ "owner"
  end

  test "unknown owner → unknown_owner error" do
    cmd = %{
      "submitted_by" => "ou_known",
      "args" => %{
        "name" => "test-ws-y",
        "owner" => "no-such-user"
      }
    }

    assert {:error, %{"type" => "unknown_owner", "owner" => "no-such-user"}} =
             WorkspaceNew.execute(cmd)
  end

  test "invalid name (special chars) → invalid_name" do
    for bad <- ["with space", "中文", "-leading-dash", "trailing!"] do
      cmd = %{
        "submitted_by" => "ou_known",
        "args" => %{
          "name" => bad,
          "owner" => "linyilun"
        }
      }

      assert {:error, %{"type" => "invalid_name"}} = WorkspaceNew.execute(cmd),
             "expected reject for #{inspect(bad)}"
    end
  end

  test "missing args.name → invalid_args" do
    assert {:error, %{"type" => "invalid_args"}} = WorkspaceNew.execute(%{"args" => %{}})
    assert {:error, %{"type" => "invalid_args"}} = WorkspaceNew.execute(%{})
  end

  # ---------------------------------------------------------------------------
  # Idempotency (PR-21η behaviour preserved)
  # ---------------------------------------------------------------------------

  test "duplicate workspace name without chat context → name_exists (CLI path)" do
    cmd = %{
      "submitted_by" => "ou_known",
      "args" => %{
        "name" => "test-dup-cli",
        "owner" => "linyilun"
      }
    }

    assert {:ok, _} = WorkspaceNew.execute(cmd)
    assert {:error, %{"type" => "name_exists"}} = WorkspaceNew.execute(cmd)
  end

  test "PR-21η: re-running /new-workspace with new chat appends chat (idempotent path)" do
    create_cmd = %{
      "submitted_by" => "ou_known",
      "args" => %{
        "name" => "test-rerun",
        "owner" => "linyilun",
        "chat_id" => "oc_first",
        "app_id" => "cli_a"
      }
    }

    assert {:ok, %{"action" => "created", "chats" => chats1}} = WorkspaceNew.execute(create_cmd)
    assert chats1 == [%{"chat_id" => "oc_first", "app_id" => "cli_a", "kind" => "dm"}]

    # Re-run from a DIFFERENT chat — should append rather than error.
    second_cmd = %{
      "submitted_by" => "ou_known",
      "args" => %{
        "name" => "test-rerun",
        "owner" => "linyilun",
        "chat_id" => "oc_second",
        "app_id" => "cli_a"
      }
    }

    assert {:ok, %{"action" => "added_chat", "chats" => chats2}} = WorkspaceNew.execute(second_cmd)
    assert length(chats2) == 2
    assert %{"chat_id" => "oc_first", "app_id" => "cli_a"} = Enum.at(chats2, 0)
    assert %{"chat_id" => "oc_second", "app_id" => "cli_a"} = Enum.at(chats2, 1)
  end

  test "PR-21η: re-running /new-workspace from same chat → already_bound (no write)" do
    cmd = %{
      "submitted_by" => "ou_known",
      "args" => %{
        "name" => "test-same-chat",
        "owner" => "linyilun",
        "chat_id" => "oc_same",
        "app_id" => "cli_a"
      }
    }

    assert {:ok, %{"action" => "created"}} = WorkspaceNew.execute(cmd)
    assert {:ok, %{"action" => "already_bound", "chats" => chats}} = WorkspaceNew.execute(cmd)
    assert length(chats) == 1
  end

  # ---------------------------------------------------------------------------
  # UUID generation
  # ---------------------------------------------------------------------------

  test "generated UUID is valid v4 format" do
    cmd = %{
      "submitted_by" => "ou_known",
      "args" => %{
        "name" => "uuid-check",
        "owner" => "linyilun"
      }
    }

    assert {:ok, %{"id" => id}} = WorkspaceNew.execute(cmd)
    # UUID v4: version nibble = 4, variant bits = 8/9/a/b
    assert id =~ ~r/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i
  end

  test "two successive creates produce different UUIDs" do
    make = fn n ->
      %{
        "submitted_by" => "ou_known",
        "args" => %{"name" => n, "owner" => "linyilun"}
      }
    end

    assert {:ok, %{"id" => id1}} = WorkspaceNew.execute(make.("uuid-ws-a"))
    assert {:ok, %{"id" => id2}} = WorkspaceNew.execute(make.("uuid-ws-b"))
    assert id1 != id2
  end
end
