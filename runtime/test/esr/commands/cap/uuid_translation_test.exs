defmodule Esr.Commands.Cap.UuidTranslationTest do
  use ExUnit.Case, async: false
  alias Esr.Commands.Cap.{Grant, Revoke}
  alias Esr.Resource.Workspace.{Registry, Struct}
  alias Esr.Commands.Cap.Show
  alias Esr.Commands.Cap.WhoCan

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

  test "Cap.Show translates UUIDs back to names in output" do
    Grant.execute(%{
      "args" => %{"principal_id" => "linyilun", "permission" => "session:esr-dev/create"}
    })

    Grant.execute(%{
      "args" => %{"principal_id" => "linyilun", "permission" => "user.manage"}
    })

    {:ok, %{"text" => text}} =
      Show.execute(%{
        "args" => %{"principal_id" => "linyilun"}
      })

    assert text =~ "session:esr-dev/create"
    refute text =~ @uuid
    assert text =~ "user.manage"
  end

  test "Cap.Show shows <UNKNOWN-...> for orphan UUIDs" do
    path = Esr.Paths.capabilities_yaml()

    yaml = """
    principals:
      - id: linyilun
        kind: feishu_user
        capabilities:
          - "session:99999999-9999-4999-8999-999999999999/create"
    """

    File.mkdir_p!(Path.dirname(path))
    File.write!(path, yaml)

    {:ok, %{"text" => text}} =
      Show.execute(%{
        "args" => %{"principal_id" => "linyilun"}
      })

    assert text =~ "<UNKNOWN-99999999>"
  end

  test "Cap.WhoCan translates input perm name → UUID before matching" do
    Grant.execute(%{
      "args" => %{"principal_id" => "linyilun", "permission" => "session:esr-dev/create"}
    })

    {:ok, %{"text" => text}} =
      WhoCan.execute(%{
        "args" => %{"permission" => "session:esr-dev/create"}
      })

    assert text =~ "linyilun"
  end
end
