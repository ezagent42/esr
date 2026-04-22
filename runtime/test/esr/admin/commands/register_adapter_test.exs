defmodule Esr.Admin.Commands.RegisterAdapterTest do
  @moduledoc """
  DI-8 Task 16 — `Esr.Admin.Commands.RegisterAdapter` persists a new
  adapter instance to `adapters.yaml`, appends the secret to
  `.env.local` (chmod 0600), and calls `WorkerSupervisor.ensure_adapter`
  to hot-load the adapter subprocess post-boot.

  ## Why the spawn_fn injection

  `execute/2` takes an opts keyword with `:spawn_fn` so tests don't
  actually spawn a Python Feishu subprocess. The Dispatcher calls
  `execute/1` (no opts) which uses the real
  `Esr.WorkerSupervisor.ensure_adapter/4`. Pattern mirrors
  `Esr.Application.restore_adapters_from_disk/2`.
  """

  use ExUnit.Case, async: false

  alias Esr.Admin.Commands.RegisterAdapter

  setup do
    unique = System.unique_integer([:positive])
    tmp = Path.join(System.tmp_dir!(), "admin_regadapt_#{unique}")
    File.mkdir_p!(Path.join(tmp, "default"))

    prev_home = System.get_env("ESRD_HOME")
    System.put_env("ESRD_HOME", tmp)

    on_exit(fn ->
      if prev_home,
        do: System.put_env("ESRD_HOME", prev_home),
        else: System.delete_env("ESRD_HOME")

      File.rm_rf!(tmp)
    end)

    {:ok, tmp: tmp}
  end

  describe "execute/2 happy path" do
    test "appends to adapters.yaml + writes 0600 .env.local + calls spawn_fn", %{tmp: tmp} do
      parent = self()

      cmd = %{
        "args" => %{
          "type" => "feishu",
          "name" => "esr_dev_helper",
          "app_id" => "cli_test_app_id",
          "app_secret" => "sekret123"
        }
      }

      assert {:ok, %{"adapter_id" => "esr_dev_helper", "running" => true}} =
               RegisterAdapter.execute(cmd,
                 spawn_fn: fn args ->
                   send(parent, {:spawned, args})
                   :ok
                 end
               )

      # adapters.yaml was written with the new instance.
      adapters_path = Path.join([tmp, "default", "adapters.yaml"])
      assert File.exists?(adapters_path)
      {:ok, parsed} = YamlElixir.read_from_file(adapters_path)

      assert %{
               "instances" => %{
                 "esr_dev_helper" => %{
                   "type" => "feishu",
                   "config" => %{"app_id" => "cli_test_app_id"}
                 }
               }
             } = parsed

      # .env.local has the FEISHU_APP_SECRET line + mode 0600.
      env_path = Path.join([tmp, "default", ".env.local"])
      assert File.exists?(env_path)
      body = File.read!(env_path)
      assert body =~ "FEISHU_APP_SECRET_ESR_DEV_HELPER=sekret123"

      %File.Stat{mode: mode} = File.stat!(env_path)
      # File.Stat mode masks POSIX permission bits as the low 9 bits.
      assert Bitwise.band(mode, 0o777) == 0o600

      # spawn_fn saw the right args (type, name, config, url).
      assert_received {:spawned,
                       {"feishu", "esr_dev_helper", %{"app_id" => "cli_test_app_id"}, url}}

      assert is_binary(url)
      assert url =~ "/adapter_hub/socket/websocket"
    end

    test "merges into existing adapters.yaml without clobbering prior instances", %{tmp: tmp} do
      adapters_path = Path.join([tmp, "default", "adapters.yaml"])

      File.write!(adapters_path, """
      instances:
        existing_helper:
          type: feishu
          config:
            app_id: cli_existing
      """)

      cmd = %{
        "args" => %{
          "type" => "feishu",
          "name" => "new_helper",
          "app_id" => "cli_new",
          "app_secret" => "new_secret"
        }
      }

      assert {:ok, _} =
               RegisterAdapter.execute(cmd, spawn_fn: fn _ -> :ok end)

      {:ok, parsed} = YamlElixir.read_from_file(adapters_path)

      assert Map.has_key?(parsed["instances"], "existing_helper")
      assert Map.has_key?(parsed["instances"], "new_helper")
      assert parsed["instances"]["existing_helper"]["config"]["app_id"] == "cli_existing"
      assert parsed["instances"]["new_helper"]["config"]["app_id"] == "cli_new"
    end

    test "appending a second secret preserves the first line", %{tmp: tmp} do
      env_path = Path.join([tmp, "default", ".env.local"])

      # First command.
      assert {:ok, _} =
               RegisterAdapter.execute(
                 %{
                   "args" => %{
                     "type" => "feishu",
                     "name" => "first",
                     "app_id" => "a1",
                     "app_secret" => "s1"
                   }
                 },
                 spawn_fn: fn _ -> :ok end
               )

      # Second command.
      assert {:ok, _} =
               RegisterAdapter.execute(
                 %{
                   "args" => %{
                     "type" => "feishu",
                     "name" => "second",
                     "app_id" => "a2",
                     "app_secret" => "s2"
                   }
                 },
                 spawn_fn: fn _ -> :ok end
               )

      body = File.read!(env_path)
      assert body =~ "FEISHU_APP_SECRET_FIRST=s1"
      assert body =~ "FEISHU_APP_SECRET_SECOND=s2"

      # Still 0600 after the second write.
      %File.Stat{mode: mode} = File.stat!(env_path)
      assert Bitwise.band(mode, 0o777) == 0o600
    end
  end

  describe "execute/2 error paths" do
    test "invalid args (missing app_secret) returns invalid_args" do
      assert {:error, %{"type" => "invalid_args"}} =
               RegisterAdapter.execute(
                 %{"args" => %{"type" => "feishu", "name" => "x", "app_id" => "y"}},
                 spawn_fn: fn _ -> :ok end
               )
    end

    test "unknown type (non-feishu) returns invalid_args" do
      assert {:error, %{"type" => "invalid_args"}} =
               RegisterAdapter.execute(
                 %{
                   "args" => %{
                     "type" => "slack",
                     "name" => "x",
                     "app_id" => "y",
                     "app_secret" => "z"
                   }
                 },
                 spawn_fn: fn _ -> :ok end
               )
    end

    test "spawn_fn failure propagates as register_adapter_failed" do
      cmd = %{
        "args" => %{
          "type" => "feishu",
          "name" => "boom",
          "app_id" => "a",
          "app_secret" => "s"
        }
      }

      assert {:error, %{"type" => "register_adapter_failed"}} =
               RegisterAdapter.execute(cmd,
                 spawn_fn: fn _ -> {:error, :subprocess_crash} end
               )
    end
  end

  describe "execute/1 default path" do
    test "malformed command still rejected without touching disk" do
      # No args at all — the match falls to the invalid_args clause and
      # never writes anything.
      assert {:error, %{"type" => "invalid_args"}} = RegisterAdapter.execute(%{})
    end
  end
end
