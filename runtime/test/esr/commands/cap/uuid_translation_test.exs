defmodule Esr.Commands.Cap.UuidTranslationTest do
  use ExUnit.Case, async: false
  alias Esr.Commands.Cap.{Grant, Revoke}
  alias Esr.Resource.Workspace.{Registry, Struct}
  alias Esr.Commands.Cap.Show
  alias Esr.Commands.Cap.WhoCan

  @uuid "7b9f3c1a-2d8e-4f1b-9a35-c4e2f8d63b71"
  @session_uuid "a1b2c3d4-e5f6-4a7b-8c9d-e0f1a2b3c4d5"

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

  # Phase 5 contract: session caps are UUID-only at input.
  # session:<name>/... is now rejected by Grant and Revoke.

  test "Cap.Grant rejects session:<name>/<perm> — UUID required at input" do
    assert {:error, %{"type" => "session_cap_requires_uuid", "message" => msg}} =
             Grant.execute(%{
               "args" => %{"principal_id" => "linyilun", "permission" => "session:esr-dev/create"}
             })

    assert msg =~ "esr-dev"
  end

  test "Cap.Grant accepts session:<uuid>/<perm> — UUID passes straight through" do
    cap = "session:#{@session_uuid}/create"

    result =
      Grant.execute(%{
        "args" => %{"principal_id" => "linyilun", "permission" => cap}
      })

    # Either granted OK or write_failed (no ESRD_HOME caps.yaml in this setup);
    # must NOT return session_cap_requires_uuid.
    assert match?({:ok, _}, result) or match?({:error, %{"type" => "write_failed"}}, result)
    refute match?({:error, %{"type" => "session_cap_requires_uuid"}}, result)
  end

  test "Cap.Revoke rejects session:<name>/<perm> — UUID required at input" do
    assert {:error, %{"type" => "session_cap_requires_uuid"}} =
             Revoke.execute(%{
               "args" => %{"principal_id" => "linyilun", "permission" => "session:esr-dev/create"}
             })
  end

  test "Cap.Grant rejects session name input — returns session_cap_requires_uuid not unknown_workspace" do
    assert {:error, %{"type" => "session_cap_requires_uuid"}} =
             Grant.execute(%{
               "args" => %{
                 "principal_id" => "linyilun",
                 "permission" => "session:ghost-ws/create"
               }
             })
  end

  test "workspace:<name>/... still translates name → UUID via NameIndex" do
    {:ok, %{"permission" => persisted_perm}} =
      Grant.execute(%{
        "args" => %{"principal_id" => "linyilun", "permission" => "workspace:esr-dev/read"}
      })

    assert persisted_perm == "workspace:#{@uuid}/read"
  end

  test "non-workspace-scoped caps pass through unchanged" do
    {:ok, %{"permission" => persisted_perm}} =
      Grant.execute(%{
        "args" => %{"principal_id" => "linyilun", "permission" => "user.manage"}
      })

    assert persisted_perm == "user.manage"
  end

  test "Cap.Show renders session UUIDs with UNKNOWN sentinel when session not in registry" do
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

  test "Cap.WhoCan accepts session:<uuid> at input for reverse lookup" do
    cap = "session:#{@session_uuid}/create"

    # Grant the UUID-form cap
    Grant.execute(%{
      "args" => %{"principal_id" => "linyilun", "permission" => cap}
    })

    {:ok, %{"text" => text}} =
      WhoCan.execute(%{
        "args" => %{"permission" => cap}
      })

    assert text =~ "linyilun"
  end
end
