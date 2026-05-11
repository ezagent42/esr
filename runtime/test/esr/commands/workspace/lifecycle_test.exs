defmodule Esr.Commands.Workspace.LifecycleTest do
  @moduledoc """
  PR-1 acceptance: ESR-bound workspace lifecycle end-to-end exercising
  the ≥1-folder invariant (spec 2026-05-11 §4.1).

  Flow:
    1. Create an ESR-bound workspace (no folder= arg) — should produce
       a 1-folder workspace whose only folder is the ESR-managed dir.
    2. Attempt to remove that only folder — must be rejected with
       `:cannot_remove_last_folder`.
    3. Remove the whole workspace via /workspace:remove — succeeds; the
       NameIndex no longer resolves it.
  """

  use ExUnit.Case, async: false

  alias Esr.Commands.Workspace.{New, Remove, RemoveFolder}
  alias Esr.Resource.Workspace.{NameIndex, Registry}

  setup do
    if Process.whereis(Esr.Entity.User.Registry) == nil do
      start_supervised!(Esr.Entity.User.Registry)
    end

    Esr.Entity.User.Registry.load_snapshot(%{
      "alice" => %Esr.Entity.User.Registry.User{
        username: "alice",
        feishu_ids: ["ou_alice"]
      }
    })

    unique = System.unique_integer([:positive])
    tmp = Path.join(System.tmp_dir!(), "ws_lifecycle_#{unique}")
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

  test "ESR-bound workspace lifecycle: create, describe, attempt-remove-folder, remove" do
    name = "lc-#{:erlang.unique_integer([:positive])}"

    {:ok, _} =
      New.execute(%{
        "args" => %{"name" => name, "username" => "alice"}
      })

    {:ok, wid} = NameIndex.id_for_name(:esr_workspace_name_index, name)
    {:ok, ws} = Registry.get_by_id(wid)
    assert length(ws.folders) == 1
    assert File.dir?(hd(ws.folders).path)

    folder_path = hd(ws.folders).path

    assert {:error, %{"type" => "cannot_remove_last_folder"}} =
             RemoveFolder.execute(%{
               "args" => %{"name" => name, "path" => folder_path}
             })

    {:ok, _} =
      Remove.execute(%{
        "args" => %{"name" => name, "username" => "alice"}
      })

    assert :not_found = NameIndex.id_for_name(:esr_workspace_name_index, name)
  end
end
