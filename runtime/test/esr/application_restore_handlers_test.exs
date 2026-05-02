defmodule Esr.ApplicationRestoreHandlersTest do
  @moduledoc """
  PR-9 T11a: boot-time spawn of Python handler_workers for every
  handler module referenced by any agents.yaml `capabilities_required`
  entry.

  Closes the "nobody spawns X worker" anti-pattern — without this,
  `HandlerRouter.call` broadcasts to an empty Phoenix channel and
  CCProcess times out waiting for a reply.
  """
  use ExUnit.Case, async: false

  describe "extract_handler_modules/1" do
    setup do
      unique = System.unique_integer([:positive])
      path = Path.join(System.tmp_dir!(), "agents-#{unique}.yaml")
      on_exit(fn -> File.rm(path) end)
      {:ok, path: path}
    end

    test "returns unique sorted handler module names across all agents", %{path: path} do
      File.write!(path, """
      agents:
        cc:
          capabilities_required:
            - handler:cc_adapter_runner/invoke
            - pty:default/spawn
            - handler:cc_adapter_runner/read
        voice:
          capabilities_required:
            - handler:cc_adapter_runner/invoke
            - handler:voice_e2e/invoke
      """)

      assert Esr.Application.extract_handler_modules(path) ==
               ["cc_adapter_runner", "voice_e2e"]
    end

    test "skips malformed capabilities (no slash, empty module, wrong prefix)",
         %{path: path} do
      File.write!(path, """
      agents:
        broken:
          capabilities_required:
            - handler:
            - handler:/action
            - workspace:foo/msg.send
            - handler:real_one/ok
      """)

      assert Esr.Application.extract_handler_modules(path) == ["real_one"]
    end

    test "missing file → []", %{path: path} do
      refute File.exists?(path)
      assert Esr.Application.extract_handler_modules(path) == []
    end

    test "no agents key → []", %{path: path} do
      File.write!(path, "schema_version: 1\n")
      assert Esr.Application.extract_handler_modules(path) == []
    end
  end

  describe "restore_handlers_from_disk/1" do
    setup do
      prev = System.get_env("ESRD_HOME")
      prev_inst = System.get_env("ESR_INSTANCE")

      unique = System.unique_integer([:positive])
      home = Path.join(System.tmp_dir!(), "esr-rh-#{unique}")
      instance = "e2e-#{unique}"
      File.mkdir_p!(Path.join(home, instance))
      System.put_env("ESRD_HOME", home)
      System.put_env("ESR_INSTANCE", instance)

      on_exit(fn ->
        File.rm_rf!(home)
        if prev, do: System.put_env("ESRD_HOME", prev), else: System.delete_env("ESRD_HOME")

        if prev_inst,
          do: System.put_env("ESR_INSTANCE", prev_inst),
          else: System.delete_env("ESR_INSTANCE")
      end)

      {:ok, home: home, instance: instance}
    end

    test "invokes spawn_fn once per unique handler module", %{home: home, instance: instance} do
      File.write!(Path.join([home, instance, "agents.yaml"]), """
      agents:
        cc:
          capabilities_required:
            - handler:cc_adapter_runner/invoke
            - handler:cc_adapter_runner/read
        voice:
          capabilities_required:
            - handler:voice_e2e/invoke
      """)

      parent = self()

      :ok =
        Esr.Application.restore_handlers_from_disk(
          spawn_fn: fn mod ->
            send(parent, {:handler_spawn, mod})
            :ok
          end
        )

      assert_receive {:handler_spawn, "cc_adapter_runner"}
      assert_receive {:handler_spawn, "voice_e2e"}
      refute_receive {:handler_spawn, "cc_adapter_runner"}, 50
    end

    test "missing agents.yaml → :ok no-op", %{home: home, instance: instance} do
      refute File.exists?(Path.join([home, instance, "agents.yaml"]))

      parent = self()

      :ok =
        Esr.Application.restore_handlers_from_disk(
          spawn_fn: fn mod -> send(parent, {:handler_spawn, mod}) end
        )

      refute_receive _, 50
    end

    test "spawn_fn failure is logged but non-fatal", %{home: home, instance: instance} do
      import ExUnit.CaptureLog

      File.write!(Path.join([home, instance, "agents.yaml"]), """
      agents:
        cc:
          capabilities_required:
            - handler:cc_adapter_runner/invoke
      """)

      log =
        capture_log(fn ->
          :ok =
            Esr.Application.restore_handlers_from_disk(
              spawn_fn: fn _mod -> {:error, :fake_fail} end
            )
        end)

      assert log =~ "handler bootstrap: ensure_handler failed"
      assert log =~ "cc_adapter_runner"
      assert log =~ ":fake_fail"
    end
  end
end
