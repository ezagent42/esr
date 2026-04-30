defmodule Esr.Admin.Commands.Workspace.NewTest do
  use ExUnit.Case, async: false

  alias Esr.Admin.Commands.Workspace.New, as: WorkspaceNew

  setup do
    assert is_pid(Process.whereis(Esr.Workspaces.Registry))

    if Process.whereis(Esr.Users.Registry) == nil do
      start_supervised!(Esr.Users.Registry)
    end

    Esr.Users.Registry.load_snapshot(%{
      "linyilun" => %Esr.Users.Registry.User{
        username: "linyilun",
        feishu_ids: ["ou_known"]
      }
    })

    # Isolate workspaces.yaml writes to tmp dir
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
      Esr.Users.Registry.load_snapshot(%{})
      :ets.delete_all_objects(:esr_workspaces)
    end)

    {:ok, tmp: tmp}
  end

  test "creates workspace with all fields and writes yaml (PR-22: no root)", %{tmp: tmp} do
    cmd = %{
      "submitted_by" => "ou_known",
      "args" => %{
        "name" => "test-ws-1",
        "owner" => "linyilun",
        "chat_id" => "oc_test1",
        "app_id" => "cli_test"
      }
    }

    assert {:ok,
            %{
              "name" => "test-ws-1",
              "owner" => "linyilun",
              "role" => "dev",
              "chats" => chats
            } = result} = WorkspaceNew.execute(cmd)

    # PR-22: workspace.New result no longer includes "root"
    refute Map.has_key?(result, "root")

    assert chats == [%{"chat_id" => "oc_test1", "app_id" => "cli_test", "kind" => "dm"}]

    # File written
    yaml = File.read!(Path.join([tmp, "default", "workspaces.yaml"]))
    {:ok, parsed} = YamlElixir.read_from_string(yaml)
    assert parsed["workspaces"]["test-ws-1"]["owner"] == "linyilun"
    refute Map.has_key?(parsed["workspaces"]["test-ws-1"], "root")

    # Registry populated proactively
    assert {:ok, ws} = Esr.Workspaces.Registry.get("test-ws-1")
    assert ws.owner == "linyilun"
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
        "root" => "/tmp",
        "owner" => "no-such-user"
      }
    }

    assert {:error, %{"type" => "unknown_owner", "owner" => "no-such-user"}} =
             WorkspaceNew.execute(cmd)
  end

  test "duplicate workspace name without chat context → name_exists (CLI path)" do
    # PR-21η: name_exists is preserved for the CLI path where no
    # chat_id / app_id are supplied. Only the slash path (chat
    # context present) gets the new idempotent add-chat behaviour.
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

  test "invalid name (special chars) → invalid_name" do
    for bad <- ["with space", "中文", "-leading-dash", "trailing!"] do
      cmd = %{
        "submitted_by" => "ou_known",
        "args" => %{
          "name" => bad,
          "root" => "/tmp",
          "owner" => "linyilun"
        }
      }

      assert {:error, %{"type" => "invalid_name"}} = WorkspaceNew.execute(cmd),
             "expected reject for #{inspect(bad)}"
    end
  end

  test "no chat_id/app_id args → empty chats list", %{tmp: _tmp} do
    cmd = %{
      "submitted_by" => "ou_known",
      "args" => %{
        "name" => "test-no-chat",
        "root" => "/tmp",
        "owner" => "linyilun"
      }
    }

    assert {:ok, %{"chats" => []}} = WorkspaceNew.execute(cmd)
  end
end
