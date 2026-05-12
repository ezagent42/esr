defmodule Esr.Integration.RegisterAdapterSpawnsFaaTest do
  @moduledoc """
  Integration test for the 2026-05-12 atomic-FAA-spawn fix.

  Live-test bug: after `tools/wipe-esrd-home.sh --dev` + esrd boot +
  `register_adapter`, inbound Feishu messages were silently dropped
  because `register_adapter` only spawned the Python sidecar, not the
  Elixir FAA peer.

  This test exercises the real `Esr.Plugin.Loader.run_startup/0` path:
  the unit test (`register_adapter_test.exs`) DI's `:startup_fn` and
  proves it gets called; this test proves the default callback actually
  ends with an FAA process registered in `Esr.Entity.Registry`.

  Tagged `:integration` so it's skipped by default (`test_helper.exs`
  excludes that tag). Run via `mix test --include integration <path>`.

  ## Test environment caveat (seed feishu startup callback)

  `config/test.exs:23` sets `enabled_plugins: []`, so the feishu plugin
  is NOT loaded during `mix test`. Consequently `Esr.Plugin.Loader`'s
  `:startup_callbacks` persistent_term is empty, and the default
  `&Esr.Plugin.Loader.run_startup/0` would no-op — the FAA would never
  spawn and `Registry.lookup` would return `[]`.

  Seed the persistent_term in setup with feishu's startup tuple (the
  same shape `Esr.Plugin.Loader.register_startup/2` writes at boot in
  production). on_exit restores the previous value so the leak doesn't
  cross into other integration tests.

  ## Cleanup contract

  The FAA process spawned by run_startup/0 is parented to
  `Esr.Session.Admin.children_supervisor_name()` (a global
  DynamicSupervisor in the Application tree). on_exit must terminate
  the child so it doesn't leak into subsequent tests in the same VM.
  """

  use ExUnit.Case, async: false

  @moduletag :integration

  alias Esr.Commands.RegisterAdapter

  setup do
    unique = System.unique_integer([:positive])
    tmp = Path.join(System.tmp_dir!(), "regadapt_faa_#{unique}")
    File.mkdir_p!(Path.join(tmp, "default"))

    prev_home = System.get_env("ESRD_HOME")
    System.put_env("ESRD_HOME", tmp)

    # Seed feishu's startup callback (test.exs sets enabled_plugins=[]).
    # Tuple shape matches what register_startup/2 writes in production
    # (loader.ex:377-393): {plugin_name :: String.t(), module(), atom()}.
    prev_callbacks = :persistent_term.get({Esr.Plugin.Loader, :startup_callbacks}, [])

    :persistent_term.put(
      {Esr.Plugin.Loader, :startup_callbacks},
      prev_callbacks ++ [{"feishu", Esr.Plugins.Feishu.Bootstrap, :bootstrap}]
    )

    sup = Esr.Session.Admin.children_supervisor_name()
    instance_id = "atomic_faa_#{unique}"

    on_exit(fn ->
      # Kill any FAA(s) this test left in the global supervisor before
      # tearing down ESRD_HOME — otherwise the next test in the same VM
      # inherits an orphan FAA registered under the same name.
      for key <- [
            "feishu_app_adapter_#{instance_id}",
            "feishu_app_adapter_#{instance_id}_a",
            "feishu_app_adapter_#{instance_id}_b"
          ] do
        case Registry.lookup(Esr.Entity.Registry, key) do
          [{pid, _}] when is_pid(pid) ->
            _ = DynamicSupervisor.terminate_child(sup, pid)

          _ ->
            :ok
        end
      end

      :persistent_term.put({Esr.Plugin.Loader, :startup_callbacks}, prev_callbacks)

      if prev_home,
        do: System.put_env("ESRD_HOME", prev_home),
        else: System.delete_env("ESRD_HOME")

      File.rm_rf!(tmp)
    end)

    {:ok, tmp: tmp, instance_id: instance_id}
  end

  test "register_adapter spawns the FAA in Esr.Entity.Registry", %{instance_id: name} do
    # spawn_fn stub so we don't fork a real Python sidecar — only the
    # startup_fn (defaulted to Esr.Plugin.Loader.run_startup/0) needs to
    # be real for this test. Bootstrap.bootstrap/0 reads
    # adapters/<name>/config.yaml from disk and spawns the FAA; the disk
    # write happens inside execute/2's Esr.Adapters.add/3, so by the
    # time startup_fn runs, the config is there.
    cmd = %{
      "args" => %{
        "type" => "feishu",
        "name" => name,
        "app_id" => "cli_atomic_#{name}",
        "app_secret" => "secret_#{name}"
      }
    }

    assert {:ok, %{"running" => true}} =
             RegisterAdapter.execute(cmd, spawn_fn: fn _ -> :ok end)

    # The FAA registers under both an atom alias (Esr.Session.Admin.Process)
    # and a string key in Esr.Entity.Registry. The string-keyed lookup is
    # what FeishuChatProxy.lookup_app_adapter_pid/1 uses on every inbound
    # message — that's the lookup the bug was triggering "no FeishuAppAdapter"
    # warnings on (see feishu_chat_proxy.ex:1084).
    assert [{pid, _}] = Registry.lookup(Esr.Entity.Registry, "feishu_app_adapter_#{name}")
    assert is_pid(pid)
    assert Process.alive?(pid)
  end

  test "second register_adapter for a different name does not disturb the first", %{
    instance_id: base
  } do
    name1 = "#{base}_a"
    name2 = "#{base}_b"

    assert {:ok, _} =
             RegisterAdapter.execute(
               %{
                 "args" => %{
                   "type" => "feishu",
                   "name" => name1,
                   "app_id" => "cli_a",
                   "app_secret" => "sa"
                 }
               },
               spawn_fn: fn _ -> :ok end
             )

    assert {:ok, _} =
             RegisterAdapter.execute(
               %{
                 "args" => %{
                   "type" => "feishu",
                   "name" => name2,
                   "app_id" => "cli_b",
                   "app_secret" => "sb"
                 }
               },
               spawn_fn: fn _ -> :ok end
             )

    assert [{pid1, _}] = Registry.lookup(Esr.Entity.Registry, "feishu_app_adapter_#{name1}")
    assert [{pid2, _}] = Registry.lookup(Esr.Entity.Registry, "feishu_app_adapter_#{name2}")
    assert pid1 != pid2
    assert Process.alive?(pid1)
    assert Process.alive?(pid2)
  end
end
