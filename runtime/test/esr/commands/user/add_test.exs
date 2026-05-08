defmodule Esr.Commands.User.AddTest do
  use ExUnit.Case, async: false

  alias Esr.Commands.User.Add
  alias Esr.Commands.User.Remove
  alias Esr.Entity.User.NameIndex

  # Unique prefix to isolate this test module's users.yaml writes from siblings.
  @prefix "addtest-#{System.system_time(:millisecond)}"

  setup do
    # Ensure NameIndex GenServer is running with the default table.
    case :ets.info(:esr_user_name_index_name_to_id) do
      :undefined -> start_supervised!({NameIndex, []})
      _ -> :ok
    end

    # Clear NameIndex state between tests.
    :ets.delete_all_objects(:esr_user_name_index_name_to_id)
    :ets.delete_all_objects(:esr_user_name_index_id_to_name)

    # Point users.yaml to a temp dir so tests don't pollute real state.
    tmp_dir = System.tmp_dir!() |> Path.join("esr_add_test_#{:rand.uniform(999_999)}")
    File.mkdir_p!(tmp_dir)
    System.put_env("ESRD_HOME", tmp_dir)
    System.put_env("ESR_INSTANCE", "default")
    instance_dir = Path.join(tmp_dir, "default")
    File.mkdir_p!(instance_dir)

    on_exit(fn ->
      File.rm_rf!(tmp_dir)
      System.delete_env("ESRD_HOME")
      System.delete_env("ESR_INSTANCE")
    end)

    {:ok, tmp_dir: tmp_dir, instance_dir: instance_dir}
  end

  describe "User.Add — NameIndex wiring" do
    test "/user:add populates NameIndex with a UUID", %{instance_dir: _dir} do
      name = "#{@prefix}-alice-#{:rand.uniform(9999)}"
      cmd = %{"args" => %{"name" => name}}

      assert {:ok, result} = Add.execute(cmd)
      uuid = result["id"]
      assert is_binary(uuid) and uuid != ""

      assert {:ok, ^uuid} = NameIndex.id_for_name(:esr_user_name_index, name)
    end

    test "/user:add returns already_exists without duplicate NameIndex entry" do
      name = "#{@prefix}-bob-#{:rand.uniform(9999)}"
      cmd = %{"args" => %{"name" => name}}

      {:ok, _} = Add.execute(cmd)
      assert {:error, %{"type" => "already_exists"}} = Add.execute(cmd)

      # NameIndex should still have exactly one entry for this user.
      assert {:ok, _uuid} = NameIndex.id_for_name(:esr_user_name_index, name)
    end
  end

  describe "User.Remove — NameIndex cleanup" do
    test "/user:remove cleans up NameIndex entry" do
      name = "#{@prefix}-carol-#{:rand.uniform(9999)}"

      {:ok, %{"id" => uuid}} = Add.execute(%{"args" => %{"name" => name}})
      assert {:ok, ^uuid} = NameIndex.id_for_name(:esr_user_name_index, name)

      assert {:ok, _} = Remove.execute(%{"args" => %{"name" => name}})
      assert :not_found = NameIndex.id_for_name(:esr_user_name_index, name)
    end

    test "/user:remove on unknown user returns not_found without touching NameIndex" do
      assert {:error, %{"type" => "not_found"}} =
               Remove.execute(%{"args" => %{"name" => "nobody-#{:rand.uniform(9999)}"}})
    end
  end

  describe "User.Add — argument validation" do
    test "missing name returns invalid_args" do
      assert {:error, %{"type" => "invalid_args"}} = Add.execute(%{"args" => %{}})
    end

    test "empty name returns invalid_args" do
      assert {:error, %{"type" => "invalid_args"}} = Add.execute(%{"args" => %{"name" => ""}})
    end

    test "invalid characters in name returns invalid_args" do
      assert {:error, %{"type" => "invalid_args"}} =
               Add.execute(%{"args" => %{"name" => "bad name!"}})
    end
  end

  describe "user.json default_workspace_id (M-5/D2 placeholder)" do
    test "user.json contains default_workspace_id key (null if not yet set)" do
      name = "alice-#{System.unique_integer([:positive])}"

      cmd = %{"submitted_by" => "ou_admin", "args" => %{"name" => name}}
      assert {:ok, %{"id" => uuid}} = Esr.Commands.User.Add.execute(cmd)

      json_path = Path.join([Esr.Paths.users_dir(), uuid, "user.json"])
      {:ok, doc} = Jason.decode(File.read!(json_path))

      assert Map.has_key?(doc, "default_workspace_id")
      # Phase 4 (M-5/D3) populates this with the real auto-created
      # `<username>-default` workspace UUID.
      assert is_binary(doc["default_workspace_id"])
    end
  end

  describe "auto-create user-default workspace (M-5/D3)" do
    setup do
      on_exit(fn -> Esr.Test.WorkspaceFixture.reset!() end)
      :ok
    end

    test "user_add creates <username>-default workspace + sets as user-default" do
      name = "auto-#{System.unique_integer([:positive])}"
      cmd = %{"submitted_by" => "ou_admin", "args" => %{"name" => name}}

      assert {:ok, result} = Esr.Commands.User.Add.execute(cmd)

      assert result["default_workspace"] == "#{name}-default"
      assert is_binary(result["default_workspace_id"])

      # Workspace exists in registry
      {:ok, ws_id} =
        Esr.Resource.Workspace.NameIndex.id_for_name(
          :esr_workspace_name_index,
          "#{name}-default"
        )

      assert {:ok, ws} = Esr.Resource.Workspace.Registry.get_by_id(ws_id)
      assert ws.owner == name

      # User-default link populated
      assert {:ok, ^ws_id} = Esr.Entity.User.Registry.get_default_workspace(name)
    end

    test "user_add result map carries actor identity (Phase 4 contract)" do
      name = "shape-#{System.unique_integer([:positive])}"
      cmd = %{"submitted_by" => "ou_admin", "args" => %{"name" => name}}

      assert {:ok, result} = Esr.Commands.User.Add.execute(cmd)

      assert result["text"] =~ "added"
      assert is_binary(result["id"])
      assert is_binary(result["default_workspace_id"])
      assert result["default_workspace"] == "#{name}-default"
    end
  end

  describe "rollback on partial failure (yellow-fix #2 / spec §9 invariant 5)" do
    setup do
      on_exit(fn -> Esr.Test.WorkspaceFixture.reset!() end)
      :ok
    end

    test "set_default_workspace failure undoes every prior write" do
      name = "rb-#{System.unique_integer([:positive])}"
      cmd = %{"args" => %{"name" => name}}

      stub_set_default = fn _username, _ws_id -> {:error, :forced_fail} end

      assert {:error, %{"type" => "write_failed"}} =
               Esr.Commands.User.Add.execute(cmd, set_default_fn: stub_set_default)

      users_yaml_path = Esr.Paths.users_yaml()

      if File.exists?(users_yaml_path) do
        {:ok, users_doc} = YamlElixir.read_from_file(users_yaml_path)
        users = Map.get(users_doc, "users", %{})
        refute Map.has_key?(users, name), "users.yaml still contains #{name} after rollback"
      end

      assert :not_found =
               Esr.Resource.Workspace.NameIndex.id_for_name(
                 :esr_workspace_name_index,
                 "#{name}-default"
               )
    end

    test "post-rollback /user:add <same-name> succeeds (no spurious already_exists)" do
      name = "rb2-#{System.unique_integer([:positive])}"
      stub_fail = fn _u, _w -> {:error, :boom} end

      assert {:error, _} = Esr.Commands.User.Add.execute(%{"args" => %{"name" => name}}, set_default_fn: stub_fail)
      assert {:ok, %{"text" => text}} = Esr.Commands.User.Add.execute(%{"args" => %{"name" => name}})
      assert text =~ "added"
    end
  end
end
