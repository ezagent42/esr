defmodule Esr.Resource.Workspace.Registry.NewApiTest do
  use ExUnit.Case, async: false
  alias Esr.Resource.Workspace.{Registry, Struct}

  setup do
    tmp = Path.join(System.tmp_dir!(), "reg_test_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(tmp)

    System.put_env("ESRD_HOME", tmp)
    System.put_env("ESR_INSTANCE", "default")

    File.mkdir_p!(Path.join([tmp, "default", "workspaces"]))

    on_exit(fn ->
      # Reset ESRD_HOME so the registry goes back to an empty state
      System.delete_env("ESRD_HOME")
      System.delete_env("ESR_INSTANCE")
      File.rm_rf!(tmp)
      # Leave the Registry running; caller isolation is via refresh/0
    end)

    # Ensure Registry is alive (it should be under the app supervisor)
    unless Process.whereis(Registry), do: Registry.start_link([])

    # Start with a clean slate for this test
    Registry.refresh()

    %{tmp: tmp}
  end

  defp make_ws_dir(tmp, name, json_overrides \\ %{}) do
    dir = Path.join([tmp, "default", "workspaces", name])
    File.mkdir_p!(dir)

    base = %{
      "schema_version" => 1,
      "id" => UUID.uuid4(),
      "name" => name,
      "owner" => "linyilun"
    }

    File.write!(Path.join(dir, "workspace.json"), Jason.encode!(Map.merge(base, json_overrides)))
    dir
  end

  test "discovers ESR-bound workspaces from $ESRD_HOME", %{tmp: tmp} do
    make_ws_dir(tmp, "default")
    make_ws_dir(tmp, "esr-dev")

    Registry.refresh()
    {:ok, names} = Registry.list_names()
    assert Enum.sort(names) == ["default", "esr-dev"]
  end

  test "get_by_id/1 returns the struct", %{tmp: tmp} do
    make_ws_dir(tmp, "esr-dev", %{"id" => "7b9f3c1a-2d8e-4f1b-9a35-c4e2f8d63b71"})
    Registry.refresh()
    assert {:ok, %Struct{name: "esr-dev"}} = Registry.get_by_id("7b9f3c1a-2d8e-4f1b-9a35-c4e2f8d63b71")
  end

  test "rejects duplicate UUIDs across two sources", %{tmp: tmp} do
    same_id = "7b9f3c1a-2d8e-4f1b-9a35-c4e2f8d63b71"
    make_ws_dir(tmp, "a", %{"id" => same_id})
    make_ws_dir(tmp, "b", %{"id" => same_id})

    assert {:error, {:duplicate_uuid, ^same_id, [_, _]}} = Registry.refresh()
  end

  test "rename updates name index but keeps id", %{tmp: tmp} do
    dir = make_ws_dir(tmp, "esr-dev", %{"id" => "11111111-2222-4333-8444-555555555551"})
    Registry.refresh()

    assert :ok = Registry.rename("esr-dev", "esr-prod")

    assert {:ok, ws} = Registry.get_by_id("11111111-2222-4333-8444-555555555551")
    assert ws.name == "esr-prod"

    new_dir = Path.join([tmp, "default", "workspaces", "esr-prod"])
    assert File.exists?(Path.join(new_dir, "workspace.json"))
    refute File.exists?(dir)
  end
end
