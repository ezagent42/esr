defmodule Esr.ApplicationRestoreHandlersTest do
  @moduledoc """
  Phase 6 (2026-05-10): boot-time spawn of Python handler_workers for
  every handler module referenced by any agent_kind's
  `capabilities_required` entry.

  Pre-Phase-6 source: `<runtime_home>/agents.yaml`. Post-Phase-6 source:
  `Esr.Plugin.AgentKindRegistry` (populated by `Esr.Plugin.Loader` from
  each enabled plugin's manifest `agent_kinds:` block).

  Closes the "nobody spawns X worker" anti-pattern — without this,
  `HandlerRouter.call` broadcasts to an empty Phoenix channel and
  CCProcess times out waiting for a reply.
  """
  use ExUnit.Case, async: false

  alias Esr.Plugin.AgentKindRegistry

  defp empty_kind_spec(plugin, name) do
    %{
      plugin: plugin,
      name: name,
      description: "",
      handler_module: nil,
      pipeline: %{inbound: [], outbound: []},
      proxies: [],
      capabilities_required: [],
      params: []
    }
  end

  defp register_kind(plugin, name, caps) do
    spec = empty_kind_spec(plugin, name) |> Map.put(:capabilities_required, caps)
    :ok = AgentKindRegistry.register(plugin, name, spec)
  end

  describe "extract_handler_modules/0" do
    setup do
      # Application boots the singleton; if a sibling test poisoned it,
      # snapshot the current contents and restore on exit so we can
      # write deterministic fixtures inside this test without leaking
      # outside.
      case Process.whereis(AgentKindRegistry) do
        nil -> start_supervised!(AgentKindRegistry)
        _ -> :ok
      end

      snapshot = AgentKindRegistry.list_kinds()
      AgentKindRegistry.clear()

      on_exit(fn ->
        AgentKindRegistry.clear()
        for {key, spec} <- snapshot do
          [plugin, name] = String.split(key, ".", parts: 2)
          AgentKindRegistry.register(plugin, name, spec)
        end
      end)

      :ok
    end

    test "returns unique sorted handler module names across all agent_kinds" do
      register_kind("plugin_a", "cc", [
        "handler:cc_adapter_runner/invoke",
        "pty:default/spawn",
        "handler:cc_adapter_runner/read"
      ])

      register_kind("plugin_b", "voice", [
        "handler:cc_adapter_runner/invoke",
        "handler:voice_e2e/invoke"
      ])

      assert Esr.Application.extract_handler_modules() ==
               ["cc_adapter_runner", "voice_e2e"]
    end

    test "skips malformed capabilities (no slash, empty module, wrong prefix)" do
      register_kind("plugin_a", "broken", [
        "handler:",
        "handler:/action",
        "workspace:foo/msg.send",
        "handler:real_one/ok"
      ])

      assert Esr.Application.extract_handler_modules() == ["real_one"]
    end

    test "empty registry → []" do
      assert Esr.Application.extract_handler_modules() == []
    end
  end

  describe "restore_handlers_from_disk/1" do
    setup do
      case Process.whereis(AgentKindRegistry) do
        nil -> start_supervised!(AgentKindRegistry)
        _ -> :ok
      end

      snapshot = AgentKindRegistry.list_kinds()
      AgentKindRegistry.clear()

      on_exit(fn ->
        AgentKindRegistry.clear()
        for {key, spec} <- snapshot do
          [plugin, name] = String.split(key, ".", parts: 2)
          AgentKindRegistry.register(plugin, name, spec)
        end
      end)

      :ok
    end

    test "invokes spawn_fn once per unique handler module" do
      register_kind("plugin_a", "cc", [
        "handler:cc_adapter_runner/invoke",
        "handler:cc_adapter_runner/read"
      ])

      register_kind("plugin_b", "voice", [
        "handler:voice_e2e/invoke"
      ])

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

    test "empty registry → :ok no-op" do
      parent = self()

      :ok =
        Esr.Application.restore_handlers_from_disk(
          spawn_fn: fn mod -> send(parent, {:handler_spawn, mod}) end
        )

      refute_receive _, 50
    end

    test "spawn_fn failure is logged but non-fatal" do
      import ExUnit.CaptureLog

      register_kind("plugin_a", "cc", [
        "handler:cc_adapter_runner/invoke"
      ])

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
