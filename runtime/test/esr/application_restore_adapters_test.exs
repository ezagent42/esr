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
end
