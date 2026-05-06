defmodule Esr.Commands.Cap.UuidTranslationTest do
  use ExUnit.Case, async: false
  alias Esr.Commands.Cap.{Grant, Revoke}
  alias Esr.Resource.Workspace.{Registry, Struct}

  @uuid "7b9f3c1a-2d8e-4f1b-9a35-c4e2f8d63b71"

  setup do
    unique = System.unique_integer([:positive])
    tmp = Path.join(System.tmp_dir!(), "cap_uuid_test_#{unique}")
    ws_dir = Path.join([tmp, "default", "workspaces", "esr-dev"])
    File.mkdir_p!(ws_dir)
    System.put_env("ESRD_HOME", tmp)
    System.put_env("ESR_INSTANCE", "default")

    # Registry is supervised — don't stop it. Just register a workspace entry
    # and clean up on exit.
    Registry.put(%Struct{
      id: @uuid,
      name: "esr-dev",
      owner: "linyilun",
      location: {:esr_bound, ws_dir}
    })

    on_exit(fn ->
      Registry.delete_by_id(@uuid)
      System.delete_env("ESRD_HOME")
      System.delete_env("ESR_INSTANCE")
      File.rm_rf!(tmp)
    end)

    %{}
  end

  test "Cap.Grant translates session:<name>/<perm> → session:<uuid>/<perm> before persisting" do
    {:ok, %{"permission" => persisted_perm}} =
      Grant.execute(%{
        "args" => %{"principal_id" => "linyilun", "permission" => "session:esr-dev/create"}
      })

    assert persisted_perm == "session:#{@uuid}/create"
  end

  test "Cap.Revoke translates name → UUID before matching" do
    # First grant the UUID-form cap directly (simulating prior translated state)
    Grant.execute(%{
      "args" => %{"principal_id" => "linyilun", "permission" => "session:esr-dev/create"}
    })

    {:ok, %{"permission" => removed_perm}} =
      Revoke.execute(%{
        "args" => %{"principal_id" => "linyilun", "permission" => "session:esr-dev/create"}
      })

    assert removed_perm == "session:#{@uuid}/create"
  end

  test "Grant errors on unknown workspace name" do
    assert {:error, %{"type" => "unknown_workspace"}} =
             Grant.execute(%{
               "args" => %{
                 "principal_id" => "linyilun",
                 "permission" => "session:ghost-ws/create"
               }
             })
  end

  test "non-workspace-scoped caps pass through unchanged" do
    {:ok, %{"permission" => persisted_perm}} =
      Grant.execute(%{
        "args" => %{"principal_id" => "linyilun", "permission" => "user.manage"}
      })

    assert persisted_perm == "user.manage"
  end
end
