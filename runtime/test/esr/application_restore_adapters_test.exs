defmodule Esr.ApplicationRestoreAdaptersTest do
  use ExUnit.Case, async: false

  setup do
    prev = System.get_env("ESRD_HOME")
    on_exit(fn ->
      if prev, do: System.put_env("ESRD_HOME", prev), else: System.delete_env("ESRD_HOME")
    end)
    :ok
  end

  test "adapters.yaml restoration calls spawn_fn per instance" do
    unique = System.unique_integer([:positive])
    tmp = Path.join(System.tmp_dir!(), "esr-adapt-test-#{unique}")
    instance_name = "feishu-test-#{unique}"

    File.mkdir_p!(Path.join(tmp, "default"))
    path = Path.join([tmp, "default", "adapters.yaml"])

    File.write!(path, """
    instances:
      #{instance_name}:
        type: feishu
        config:
          app_id: cli_x
          app_secret: secret
    """)

    parent = self()

    System.put_env("ESRD_HOME", tmp)

    :ok =
      Esr.Application.restore_adapters_from_disk(tmp,
        spawn_fn: fn instance, type, config ->
          send(parent, {:spawned, instance, type, config})
          :ok
        end
      )

    assert_received {:spawned, ^instance_name, "feishu", %{"app_id" => "cli_x", "app_secret" => "secret"}}

    File.rm_rf!(tmp)
  end

  test "restore_adapters_from_disk is a no-op when adapters.yaml is missing" do
    tmp = Path.join(System.tmp_dir!(), "esr-adapt-empty-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)

    parent = self()

    System.put_env("ESRD_HOME", tmp)

    assert :ok =
             Esr.Application.restore_adapters_from_disk(tmp,
               spawn_fn: fn _, _, _ ->
                 send(parent, :should_not_fire)
                 :ok
               end
             )

    refute_received :should_not_fire

    File.rm_rf!(tmp)
  end

  test "restore_adapters_from_disk handles multiple instances" do
    unique = System.unique_integer([:positive])
    tmp = Path.join(System.tmp_dir!(), "esr-adapt-multi-#{unique}")
    File.mkdir_p!(Path.join(tmp, "default"))
    path = Path.join([tmp, "default", "adapters.yaml"])

    File.write!(path, """
    instances:
      a-#{unique}:
        type: feishu
        config: {}
      b-#{unique}:
        type: feishu
        config: {}
    """)

    parent = self()

    System.put_env("ESRD_HOME", tmp)

    :ok =
      Esr.Application.restore_adapters_from_disk(tmp,
        spawn_fn: fn name, _type, _cfg ->
          send(parent, {:got, name})
          :ok
        end
      )

    assert_received {:got, _}
    assert_received {:got, _}

    File.rm_rf!(tmp)
  end

  describe "ensure_app_secret fallback (2026-05-09 sidecar-auth fix)" do
    test "pulls app_secret from plugins.yaml when adapters.yaml row is missing it" do
      unique = System.unique_integer([:positive])
      tmp = Path.join(System.tmp_dir!(), "esr-adapt-fallback-#{unique}")
      File.mkdir_p!(Path.join(tmp, "default"))

      adapters_path = Path.join([tmp, "default", "adapters.yaml"])
      plugins_path = Path.join([tmp, "default", "plugins.yaml"])
      instance_name = "feishu-stale-#{unique}"

      # Pre-fix-shape adapters.yaml: app_id only, no app_secret. This is
      # what an operator's on-disk file looks like if they registered
      # before the 2026-05-09 register_adapter fix landed.
      File.write!(adapters_path, """
      instances:
        #{instance_name}:
          type: feishu
          config:
            app_id: cli_stale
      """)

      # plugins.yaml carries the secret in feishu plugin config — the
      # operator-side configuration source we fall back to.
      File.write!(plugins_path, """
      config:
        feishu:
          app_secret: "from_plugins_yaml"
      """)

      parent = self()
      System.put_env("ESRD_HOME", tmp)

      :ok =
        Esr.Application.restore_adapters_from_disk(tmp,
          spawn_fn: fn _name, type, config ->
            send(parent, {:spawned, type, config})
            :ok
          end
        )

      assert_receive {:spawned, "feishu", config}, 1_000
      assert config["app_id"] == "cli_stale"
      assert config["app_secret"] == "from_plugins_yaml"

      File.rm_rf!(tmp)
    end

    test "leaves config alone (warns) when neither adapters.yaml nor plugins.yaml has app_secret" do
      unique = System.unique_integer([:positive])
      tmp = Path.join(System.tmp_dir!(), "esr-adapt-nosecret-#{unique}")
      File.mkdir_p!(Path.join(tmp, "default"))

      adapters_path = Path.join([tmp, "default", "adapters.yaml"])
      instance_name = "feishu-nosecret-#{unique}"

      File.write!(adapters_path, """
      instances:
        #{instance_name}:
          type: feishu
          config:
            app_id: cli_lonely
      """)

      parent = self()
      System.put_env("ESRD_HOME", tmp)

      # Boot must NOT crash — fallback is permissive on miss; sidecar
      # will fail authentication at runtime but the rest of the
      # supervision tree stays healthy.
      :ok =
        Esr.Application.restore_adapters_from_disk(tmp,
          spawn_fn: fn _name, _type, config ->
            send(parent, {:spawned, config})
            :ok
          end
        )

      assert_receive {:spawned, config}, 1_000
      assert config["app_id"] == "cli_lonely"
      refute Map.has_key?(config, "app_secret")

      File.rm_rf!(tmp)
    end
  end
end
