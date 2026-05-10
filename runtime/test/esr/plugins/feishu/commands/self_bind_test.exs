defmodule Esr.Plugins.Feishu.Commands.SelfBindTest do
  use ExUnit.Case, async: false

  alias Esr.Plugins.Feishu.Commands.SelfBind

  setup do
    tmp = Path.join(System.tmp_dir!(), "feishu_self_bind_#{:rand.uniform(1_000_000)}")
    inst_dir = Path.join(tmp, "default")
    File.mkdir_p!(inst_dir)

    prev_home = System.get_env("ESRD_HOME")
    prev_inst = System.get_env("ESR_INSTANCE")
    System.put_env("ESRD_HOME", tmp)
    System.put_env("ESR_INSTANCE", "default")

    on_exit(fn ->
      if prev_home, do: System.put_env("ESRD_HOME", prev_home), else: System.delete_env("ESRD_HOME")
      if prev_inst, do: System.put_env("ESR_INSTANCE", prev_inst), else: System.delete_env("ESR_INSTANCE")
      File.rm_rf!(tmp)
    end)

    {:ok, inst_dir: inst_dir}
  end

  defp write_users_yaml(inst_dir, content), do: File.write!(Path.join(inst_dir, "users.yaml"), content)
  defp read_users_yaml(inst_dir), do: YamlElixir.read_from_file!(Path.join(inst_dir, "users.yaml"))

  describe "golden path + delegation" do
    test "binds caller ou_xxx to a pre-existing user with empty feishu_ids", %{inst_dir: inst_dir} do
      write_users_yaml(inst_dir, """
      users:
        linyilun:
          feishu_ids: []
      """)

      assert {:ok, %{"text" => text}} =
               SelfBind.execute(%{
                 "args" => %{"name" => "linyilun", "caller_principal_id" => "ou_X"}
               })

      assert text =~ "bound"
      assert text =~ "ou_X"
      assert %{"users" => %{"linyilun" => %{"feishu_ids" => ["ou_X"]}}} = read_users_yaml(inst_dir)
    end

    test "idempotent — already-bound caller returns ok with no semantic change", %{inst_dir: inst_dir} do
      write_users_yaml(inst_dir, """
      users:
        linyilun:
          feishu_ids:
            - ou_X
      """)
      before = read_users_yaml(inst_dir)

      assert {:ok, _} =
               SelfBind.execute(%{"args" => %{"name" => "linyilun", "caller_principal_id" => "ou_X"}})

      assert before == read_users_yaml(inst_dir)
    end

    test "multi-bind appends caller ou_xxx alongside existing ones", %{inst_dir: inst_dir} do
      write_users_yaml(inst_dir, """
      users:
        linyilun:
          feishu_ids:
            - ou_OTHER
      """)

      assert {:ok, _} =
               SelfBind.execute(%{"args" => %{"name" => "linyilun", "caller_principal_id" => "ou_X"}})

      assert %{"users" => %{"linyilun" => %{"feishu_ids" => ids}}} = read_users_yaml(inst_dir)
      assert "ou_OTHER" in ids
      assert "ou_X" in ids
    end

    test "conflict — caller ou_xxx already bound to another user", %{inst_dir: inst_dir} do
      write_users_yaml(inst_dir, """
      users:
        bob:
          feishu_ids:
            - ou_X
        linyilun:
          feishu_ids: []
      """)

      assert {:error, %{"type" => "feishu_id_in_use"}} =
               SelfBind.execute(%{"args" => %{"name" => "linyilun", "caller_principal_id" => "ou_X"}})
    end

    test "user_not_found — pre-existing user record required", %{inst_dir: inst_dir} do
      write_users_yaml(inst_dir, """
      users:
        linyilun:
          feishu_ids: []
      """)

      assert {:error, %{"type" => "user_not_found"}} =
               SelfBind.execute(%{"args" => %{"name" => "ghost", "caller_principal_id" => "ou_X"}})
    end
  end

  describe "invalid input" do
    test "missing name= produces invalid_args" do
      assert {:error, %{"type" => "invalid_args"}} =
               SelfBind.execute(%{"args" => %{"caller_principal_id" => "ou_X"}})
    end

    test "missing caller_principal_id (envelope anomaly fallback) produces invalid_args" do
      assert {:error, %{"type" => "invalid_args"}} =
               SelfBind.execute(%{"args" => %{"name" => "linyilun"}})
    end
  end

  describe "strict-args whitelist" do
    test "rejects user-supplied target_principal_id= (not allowed for SelfBind)", %{inst_dir: inst_dir} do
      write_users_yaml(inst_dir, """
      users:
        linyilun:
          feishu_ids: []
      """)

      assert {:error, %{"type" => "invalid_args", "message" => msg}} =
               SelfBind.execute(%{
                 "args" => %{
                   "name" => "linyilun",
                   "caller_principal_id" => "ou_X",
                   "target_principal_id" => "ou_VICTIM"
                 }
               })

      assert msg =~ "target_principal_id"
    end

    test "rejects arbitrary unknown key", %{inst_dir: inst_dir} do
      write_users_yaml(inst_dir, """
      users:
        linyilun:
          feishu_ids: []
      """)

      assert {:error, %{"type" => "invalid_args", "message" => msg}} =
               SelfBind.execute(%{
                 "args" => %{
                   "name" => "linyilun",
                   "caller_principal_id" => "ou_X",
                   "random_arg" => "foo"
                 }
               })

      assert msg =~ "random_arg"
    end
  end

  describe "telemetry" do
    test "emits [:esr, :slash, :feishu, :self_bind] on success", %{inst_dir: inst_dir} do
      write_users_yaml(inst_dir, """
      users:
        linyilun:
          feishu_ids: []
      """)

      ref = :telemetry_test.attach_event_handlers(self(), [[:esr, :slash, :feishu, :self_bind]])

      assert {:ok, _} =
               SelfBind.execute(%{"args" => %{"name" => "linyilun", "caller_principal_id" => "ou_X"}})

      assert_receive {[:esr, :slash, :feishu, :self_bind], ^ref, _measurements, metadata}
      assert metadata.result == :ok
      assert metadata.name == "linyilun"
      assert metadata.caller_principal_id == "ou_X"
    end

    test "emits event with error type on conflict", %{inst_dir: inst_dir} do
      write_users_yaml(inst_dir, """
      users:
        bob:
          feishu_ids:
            - ou_X
        linyilun:
          feishu_ids: []
      """)

      ref = :telemetry_test.attach_event_handlers(self(), [[:esr, :slash, :feishu, :self_bind]])

      assert {:error, %{"type" => "feishu_id_in_use"}} =
               SelfBind.execute(%{"args" => %{"name" => "linyilun", "caller_principal_id" => "ou_X"}})

      assert_receive {[:esr, :slash, :feishu, :self_bind], ^ref, _measurements, metadata}
      assert metadata.result == "feishu_id_in_use"
    end
  end
end
