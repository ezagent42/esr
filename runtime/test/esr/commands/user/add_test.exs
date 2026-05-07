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
end
