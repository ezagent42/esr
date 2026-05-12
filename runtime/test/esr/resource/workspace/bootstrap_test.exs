defmodule Esr.Resource.Workspace.BootstrapTest do
  use ExUnit.Case, async: false

  alias Esr.Resource.Workspace.Bootstrap
  alias Esr.Resource.Workspace.NameIndex
  alias Esr.Resource.Workspace.Registry, as: WsRegistry

  setup do
    # Start clean: clear ETS state polluted by prior test/app boots so
    # each test sees only what *this* Bootstrap run produces.
    Esr.Test.WorkspaceFixture.reset!()
    on_exit(fn -> Esr.Test.WorkspaceFixture.reset!() end)
    :ok
  end

  test "no-op when ESR_BOOTSTRAP_PRINCIPAL_ID is unset" do
    System.delete_env("ESR_BOOTSTRAP_PRINCIPAL_ID")
    assert :ok = Bootstrap.run()

    # Critical: no workspace named literally "default" was created
    assert :not_found = NameIndex.id_for_name(:esr_workspace_name_index, "default")
  end

  test "creates <bootstrap_user>-default + sets it as user-default when env is set" do
    Esr.Test.UserFixture.load_snapshot(
      %{
        "linyilun" => %Esr.Entity.User.Struct{username: "linyilun", feishu_ids: ["ou_lin"]}
      },
      %{"linyilun" => "linyilun-uuid"}
    )

    System.put_env("ESR_BOOTSTRAP_PRINCIPAL_ID", "ou_lin")
    on_exit(fn -> System.delete_env("ESR_BOOTSTRAP_PRINCIPAL_ID") end)

    assert :ok = Bootstrap.run()

    {:ok, ws_id} = NameIndex.id_for_name(:esr_workspace_name_index, "linyilun-default")
    assert {:ok, ws} = WsRegistry.get_by_id(ws_id)
    assert ws.owner == "linyilun"

    assert {:ok, ^ws_id} = Esr.Uri.Compat.default_workspace_for_user_name("linyilun")

    # Negative assertion: literal "default" still does not exist
    assert :not_found = NameIndex.id_for_name(:esr_workspace_name_index, "default")
  end

  test "idempotent: re-running with the same user does not create a second workspace" do
    Esr.Test.UserFixture.load_snapshot(
      %{
        "alice" => %Esr.Entity.User.Struct{username: "alice", feishu_ids: ["ou_a"]}
      },
      %{"alice" => "alice-uuid"}
    )

    System.put_env("ESR_BOOTSTRAP_PRINCIPAL_ID", "ou_a")
    on_exit(fn -> System.delete_env("ESR_BOOTSTRAP_PRINCIPAL_ID") end)

    :ok = Bootstrap.run()
    {:ok, first_id} = NameIndex.id_for_name(:esr_workspace_name_index, "alice-default")

    :ok = Bootstrap.run()
    {:ok, second_id} = NameIndex.id_for_name(:esr_workspace_name_index, "alice-default")

    assert first_id == second_id
  end
end
