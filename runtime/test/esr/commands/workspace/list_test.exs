defmodule Esr.Commands.Workspace.ListTest do
  use ExUnit.Case, async: false

  alias Esr.Commands.Workspace.List, as: WorkspaceList

  setup do
    assert is_pid(Process.whereis(Esr.Resource.Workspace.Registry))

    # Isolate workspace storage to a tmp dir
    unique = System.unique_integer([:positive])
    tmp = Path.join(System.tmp_dir!(), "ws_list_test_#{unique}")
    File.mkdir_p!(Path.join(tmp, "default"))
    prev_home = System.get_env("ESRD_HOME")
    System.put_env("ESRD_HOME", tmp)

    on_exit(fn ->
      if prev_home,
        do: System.put_env("ESRD_HOME", prev_home),
        else: System.delete_env("ESRD_HOME")

      File.rm_rf!(tmp)
      :ets.delete_all_objects(:esr_workspaces)
      :ets.delete_all_objects(:esr_workspaces_uuid)
      Esr.Resource.Workspace.Bootstrap.run()
    end)

    {:ok, tmp: tmp}
  end

  test "empty registry → no workspaces registered" do
    # Wipe ETS so this test sees a truly empty registry. The on_exit
    # already restores "default" via Bootstrap.run() for subsequent tests.
    :ets.delete_all_objects(:esr_workspaces)
    :ets.delete_all_objects(:esr_workspaces_uuid)
    assert {:ok, %{"text" => text}} = WorkspaceList.execute(%{})
    assert text == "no workspaces registered"
  end

  test "single ESR-bound workspace → renders name, id, owner, counts, location, transient", %{tmp: tmp} do
    # Manually create a workspace struct and put it in registry
    ws = %Esr.Resource.Workspace.Struct{
      id: "7b9f3c1a-2d8e-4f1b-9a35-c4e2f8d63b71",
      name: "esr-dev",
      owner: "linyilun",
      folders: [
        %{path: "/path/to/folder1", name: "folder1"},
        %{path: "/path/to/folder2", name: "folder2"}
      ],
      chats: [
        %{chat_id: "oc_test", app_id: "cli_test", kind: "dm"}
      ],
      transient: false,
      location: {:esr_bound, Path.join([tmp, "default", "workspaces", "esr-dev"])}
    }

    Esr.Resource.Workspace.Registry.put(ws)

    assert {:ok, %{"text" => text}} = WorkspaceList.execute(%{})

    assert text =~ "workspaces:"
    assert text =~ "name: esr-dev"
    assert text =~ "id: 7b9f3c1a-2d8e-4f1b-9a35-c4e2f8d63b71"
    assert text =~ "owner: linyilun"
    assert text =~ "folders: 2"
    assert text =~ "chats: 1"
    assert text =~ ~r/location: esr:.*esr-dev/
    assert text =~ "transient: false"
  end

  test "repo-bound workspace → location shows repo:<path>", %{tmp: tmp} do
    repo_path = Path.join(tmp, "my-repo")

    ws = %Esr.Resource.Workspace.Struct{
      id: "22222222-3333-4444-8555-666666666666",
      name: "repo-ws",
      owner: "linyilun",
      folders: [%{path: repo_path, name: "my-repo"}],
      chats: [],
      transient: false,
      location: {:repo_bound, repo_path}
    }

    Esr.Resource.Workspace.Registry.put(ws)

    assert {:ok, %{"text" => text}} = WorkspaceList.execute(%{})

    assert text =~ "name: repo-ws"
    assert text =~ "folders: 1"
    assert text =~ "chats: 0"
    assert text =~ "location: repo:#{repo_path}"
    assert text =~ "transient: false"
  end

  test "multiple workspaces → sorted by name", %{tmp: tmp} do
    # Create three workspaces in non-alphabetical order
    ws_beta = %Esr.Resource.Workspace.Struct{
      id: "11111111-1111-1111-1111-111111111111",
      name: "beta-ws",
      owner: "linyilun",
      folders: [],
      chats: [],
      transient: false,
      location: {:esr_bound, Path.join(tmp, "default/workspaces/beta-ws")}
    }

    ws_alpha = %Esr.Resource.Workspace.Struct{
      id: "22222222-2222-2222-2222-222222222222",
      name: "alpha-ws",
      owner: "linyilun",
      folders: [],
      chats: [],
      transient: false,
      location: {:esr_bound, Path.join(tmp, "default/workspaces/alpha-ws")}
    }

    ws_gamma = %Esr.Resource.Workspace.Struct{
      id: "33333333-3333-3333-3333-333333333333",
      name: "gamma-ws",
      owner: "linyilun",
      folders: [],
      chats: [],
      transient: false,
      location: {:esr_bound, Path.join(tmp, "default/workspaces/gamma-ws")}
    }

    Esr.Resource.Workspace.Registry.put(ws_beta)
    Esr.Resource.Workspace.Registry.put(ws_alpha)
    Esr.Resource.Workspace.Registry.put(ws_gamma)

    assert {:ok, %{"text" => text}} = WorkspaceList.execute(%{})

    # Verify order: alpha before beta before gamma
    # Split lines and find positions of each workspace name
    lines = String.split(text, "\n")
    alpha_line = Enum.find_index(lines, &String.contains?(&1, "alpha-ws"))
    beta_line = Enum.find_index(lines, &String.contains?(&1, "beta-ws"))
    gamma_line = Enum.find_index(lines, &String.contains?(&1, "gamma-ws"))

    assert alpha_line != nil
    assert beta_line != nil
    assert gamma_line != nil
    assert alpha_line < beta_line
    assert beta_line < gamma_line
  end

  test "workspace with multiple chats → chats count is correct" do
    ws = %Esr.Resource.Workspace.Struct{
      id: "44444444-4444-4444-4444-444444444444",
      name: "multi-chat-ws",
      owner: "linyilun",
      folders: [],
      chats: [
        %{chat_id: "oc_chat1", app_id: "cli_test", kind: "dm"},
        %{chat_id: "oc_chat2", app_id: "cli_test", kind: "dm"},
        %{chat_id: "oc_chat3", app_id: "cli_test", kind: "dm"}
      ],
      transient: false,
      location: {:esr_bound, "/some/path"}
    }

    Esr.Resource.Workspace.Registry.put(ws)

    assert {:ok, %{"text" => text}} = WorkspaceList.execute(%{})

    assert text =~ "name: multi-chat-ws"
    assert text =~ "chats: 3"
  end

  test "transient workspace → transient: true rendered" do
    ws = %Esr.Resource.Workspace.Struct{
      id: "55555555-5555-5555-5555-555555555555",
      name: "temp-ws",
      owner: "linyilun",
      folders: [],
      chats: [],
      transient: true,
      location: {:esr_bound, "/some/path"}
    }

    Esr.Resource.Workspace.Registry.put(ws)

    assert {:ok, %{"text" => text}} = WorkspaceList.execute(%{})

    assert text =~ "name: temp-ws"
    assert text =~ "transient: true"
  end

  test "mixed ESR-bound and repo-bound workspaces → both listed", %{tmp: tmp} do
    repo_path = Path.join(tmp, "my-repo")

    ws_esr = %Esr.Resource.Workspace.Struct{
      id: "66666666-6666-6666-6666-666666666666",
      name: "esr-workspace",
      owner: "linyilun",
      folders: [],
      chats: [],
      transient: false,
      location: {:esr_bound, Path.join(tmp, "default/workspaces/esr-workspace")}
    }

    ws_repo = %Esr.Resource.Workspace.Struct{
      id: "77777777-7777-7777-7777-777777777777",
      name: "repo-workspace",
      owner: "linyilun",
      folders: [%{path: repo_path, name: "my-repo"}],
      chats: [],
      transient: false,
      location: {:repo_bound, repo_path}
    }

    Esr.Resource.Workspace.Registry.put(ws_esr)
    Esr.Resource.Workspace.Registry.put(ws_repo)

    assert {:ok, %{"text" => text}} = WorkspaceList.execute(%{})

    assert text =~ "name: esr-workspace"
    assert text =~ ~r/location: esr:.*esr-workspace/
    assert text =~ "name: repo-workspace"
    assert text =~ "location: repo:#{repo_path}"
  end
end
