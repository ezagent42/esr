defmodule Esr.Plugins.Feishu.Commands.SelfUnbindTest do
  use ExUnit.Case, async: false

  alias Esr.Plugins.Feishu.Commands.SelfUnbind

  setup do
    tmp = Path.join(System.tmp_dir!(), "feishu_self_unbind_#{:rand.uniform(1_000_000)}")
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

  describe "golden path" do
    test "unbinds caller ou_xxx from owning user", %{inst_dir: inst_dir} do
      write_users_yaml(inst_dir, """
      users:
        linyilun:
          feishu_ids:
            - ou_X
      """)

      assert {:ok, %{"text" => text}} =
               SelfUnbind.execute(%{"args" => %{"caller_principal_id" => "ou_X"}})

      assert text =~ "unbound"
      assert text =~ "linyilun"
      assert %{"users" => %{"linyilun" => %{"feishu_ids" => []}}} = read_users_yaml(inst_dir)
    end
  end

  describe "delegation" do
    test "idempotent — caller ou_xxx not bound to anyone returns ok", %{inst_dir: inst_dir} do
      write_users_yaml(inst_dir, """
      users:
        linyilun:
          feishu_ids: []
      """)
      before = read_users_yaml(inst_dir)

      assert {:ok, %{"text" => text}} =
               SelfUnbind.execute(%{"args" => %{"caller_principal_id" => "ou_X"}})

      assert text =~ "not bound"
      assert before == read_users_yaml(inst_dir)
    end

    test "partial removal — only the caller's ou_xxx is removed", %{inst_dir: inst_dir} do
      write_users_yaml(inst_dir, """
      users:
        linyilun:
          feishu_ids:
            - ou_X
            - ou_Y
      """)

      assert {:ok, _} = SelfUnbind.execute(%{"args" => %{"caller_principal_id" => "ou_X"}})

      assert %{"users" => %{"linyilun" => %{"feishu_ids" => ["ou_Y"]}}} = read_users_yaml(inst_dir)
    end
  end

  describe "invalid input" do
    test "missing caller_principal_id produces invalid_args" do
      assert {:error, %{"type" => "invalid_args"}} =
               SelfUnbind.execute(%{"args" => %{}})
    end
  end

  describe "strict-args whitelist" do
    test "rejects user-supplied target_principal_id=", %{inst_dir: inst_dir} do
      write_users_yaml(inst_dir, """
      users:
        linyilun:
          feishu_ids:
            - ou_X
      """)
      before = read_users_yaml(inst_dir)

      assert {:error, %{"type" => "invalid_args", "message" => msg}} =
               SelfUnbind.execute(%{
                 "args" => %{"caller_principal_id" => "ou_X", "target_principal_id" => "ou_OTHER"}
               })

      assert msg =~ "target_principal_id"
      assert before == read_users_yaml(inst_dir)
    end

    test "rejects user-supplied name= (cross-account unbind not allowed)", %{inst_dir: inst_dir} do
      write_users_yaml(inst_dir, """
      users:
        linyilun:
          feishu_ids:
            - ou_X
      """)

      assert {:error, %{"type" => "invalid_args", "message" => msg}} =
               SelfUnbind.execute(%{
                 "args" => %{"caller_principal_id" => "ou_X", "name" => "linyilun"}
               })

      assert msg =~ "name"
    end
  end

  describe "yaml write failure" do
    test "returns write_failed when users.yaml parent is read-only", %{inst_dir: inst_dir} do
      case System.cmd("id", ["-u"]) do
        {"0\n", 0} ->
          IO.puts("\n  [skipped on root: chmod 0o555 is bypassed for EUID==0]")

        {_, 0} ->
          write_users_yaml(inst_dir, """
          users:
            linyilun:
              feishu_ids:
                - ou_X
          """)

          # Note: chmod-ing the parent dir alone doesn't prevent in-place
          # rewrites of existing files on macOS/Linux (dir perms gate dirent
          # creation, not file content). To deterministically force a write
          # failure cross-platform, chmod the file itself as well.
          users_path = Path.join(inst_dir, "users.yaml")
          File.chmod!(users_path, 0o444)
          File.chmod!(inst_dir, 0o555)

          try do
            assert {:error, %{"type" => "write_failed"}} =
                     SelfUnbind.execute(%{"args" => %{"caller_principal_id" => "ou_X"}})
          after
            File.chmod!(inst_dir, 0o755)
            File.chmod!(users_path, 0o644)
          end

        _ ->
          IO.puts("\n  [skipped: id command unavailable]")
      end
    end
  end

  describe "race-remap (spec § 7.2)" do
    test "user_not_found from delegated UnbindUser is remapped to idempotent :ok", %{inst_dir: inst_dir} do
      write_users_yaml(inst_dir, """
      users:
        linyilun:
          feishu_ids: []
      """)

      :meck.new(Esr.Plugins.Feishu.Commands.SelfUnbind, [:passthrough])
      :meck.expect(Esr.Plugins.Feishu.Commands.SelfUnbind, :lookup_owner, fn _ -> "linyilun" end)

      try do
        assert {:ok, %{"text" => text}} =
                 SelfUnbind.execute(%{"args" => %{"caller_principal_id" => "ou_X"}})

        assert text =~ "no longer bound"
      after
        :meck.unload(Esr.Plugins.Feishu.Commands.SelfUnbind)
      end
    end
  end

  describe "telemetry" do
    test "emits [:esr, :slash, :feishu, :self_unbind] on success", %{inst_dir: inst_dir} do
      write_users_yaml(inst_dir, """
      users:
        linyilun:
          feishu_ids:
            - ou_X
      """)

      ref = :telemetry_test.attach_event_handlers(self(), [[:esr, :slash, :feishu, :self_unbind]])

      assert {:ok, _} = SelfUnbind.execute(%{"args" => %{"caller_principal_id" => "ou_X"}})

      assert_receive {[:esr, :slash, :feishu, :self_unbind], ^ref, _measurements, metadata}
      assert metadata.result == :ok
      assert metadata.caller_principal_id == "ou_X"
    end

    test "emits event with result :ok on idempotent (not-bound) case", %{inst_dir: inst_dir} do
      write_users_yaml(inst_dir, """
      users:
        linyilun:
          feishu_ids: []
      """)

      ref = :telemetry_test.attach_event_handlers(self(), [[:esr, :slash, :feishu, :self_unbind]])

      assert {:ok, _} = SelfUnbind.execute(%{"args" => %{"caller_principal_id" => "ou_X"}})

      assert_receive {[:esr, :slash, :feishu, :self_unbind], ^ref, _measurements, metadata}
      assert metadata.result == :ok
    end
  end
end
