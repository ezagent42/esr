defmodule Esr.Plugins.ClaudeCode.Channels.McpTest do
  @moduledoc """
  Tests for `Esr.Plugins.ClaudeCode.Channels.Mcp`.

  Spec: `docs/superpowers/specs/2026-05-10-session-template-and-channel.md`,
  Phase 2.

  `async: false` because the suite shares the global `EsrWeb.PubSub` and
  the `Esr.Channel.Instances` Registry (both already brought up by
  `Esr.Application`); concurrent tests would race on session_id reuse if
  any test author accidentally hard-coded one.
  """

  use ExUnit.Case, async: false

  alias Esr.Plugins.ClaudeCode.Channels.Mcp

  setup do
    # Application boot already brings up `EsrWeb.PubSub` and
    # `Esr.Channel.Instances`; `start_supervised` would reject a duplicate.
    # Just sanity-check they're alive — if not, the suite was started
    # without :esr loaded and these tests can't run anyway.
    assert Process.whereis(EsrWeb.PubSub), "EsrWeb.PubSub must be running"
    assert Process.whereis(Esr.Channel.Instances), "Esr.Channel.Instances must be running"
    :ok
  end

  describe "behaviour conformance" do
    test "implements Esr.Channel callbacks" do
      assert function_exported?(Mcp, :start_link, 1)
      assert function_exported?(Mcp, :dispatch, 2)
      assert function_exported?(Mcp, :subscribe, 3)
      assert function_exported?(Mcp, :config_schema, 0)
    end

    test "config_schema/0 returns a JSON-Schema-lite map with port: integer" do
      schema = Mcp.config_schema()
      assert schema["type"] == "object"
      assert get_in(schema, ["properties", "port", "type"]) == "integer"
    end
  end

  describe "lifecycle" do
    test "start_link/1 with session_id starts a GenServer registered in Esr.Channel.Instances" do
      sid = unique_sid()
      {:ok, pid} = Mcp.start_link(session_id: sid)
      assert is_pid(pid)
      assert Process.alive?(pid)

      # Registered under the Esr.Channel.Instances via-key
      assert [{^pid, _}] =
               Registry.lookup(Esr.Channel.Instances, "claude_code.mcp_stdio:" <> sid)

      GenServer.stop(pid)
    end

    test "start_link/1 without session_id raises KeyError" do
      assert_raise KeyError, fn -> Mcp.start_link([]) end
    end
  end

  describe "dispatch/2" do
    test "broadcasts msg on cli:channel/<sid> topic" do
      sid = unique_sid()
      {:ok, pid} = Mcp.start_link(session_id: sid)

      Phoenix.PubSub.subscribe(EsrWeb.PubSub, "cli:channel/" <> sid)

      msg = %{"kind" => "notification", "payload" => "hello"}
      assert :ok = Mcp.dispatch(pid, msg)

      assert_receive ^msg, 500

      GenServer.stop(pid)
    end
  end

  describe "subscribe/3 + cc_mcp_ready forwarding" do
    test "subscribes to cc_mcp_ready/<sid> at boot and forwards to :ready listeners" do
      sid = unique_sid()
      {:ok, pid} = Mcp.start_link(session_id: sid)

      :ok = Mcp.subscribe(pid, self(), :ready)

      Phoenix.PubSub.broadcast(
        EsrWeb.PubSub,
        "cc_mcp_ready/" <> sid,
        {:cc_mcp_ready, sid}
      )

      assert_receive {:cc_mcp_ready, ^sid}, 500

      GenServer.stop(pid)
    end

    test "subscribers on other topics are not notified by cc_mcp_ready" do
      sid = unique_sid()
      {:ok, pid} = Mcp.start_link(session_id: sid)

      # Listener subscribed to a different topic shouldn't get the ready message.
      :ok = Mcp.subscribe(pid, self(), :other_topic)

      Phoenix.PubSub.broadcast(
        EsrWeb.PubSub,
        "cc_mcp_ready/" <> sid,
        {:cc_mcp_ready, sid}
      )

      refute_receive {:cc_mcp_ready, ^sid}, 100

      GenServer.stop(pid)
    end
  end

  describe "Esr.Channel.Registry smoke (manifest → loader → registry)" do
    test "claude_code's manifest declares mcp_stdio and loader registers it" do
      # Smoke proof that manifest → loader → registry is wired correctly.
      # We don't rely on app-boot side-effects surviving (other tests, e.g.
      # `Esr.Channel.RegistryTest`, call `Registry.clear/0` in on_exit and
      # would race here). Instead we re-parse the live manifest + replay
      # the loader's `register_channels/1` step inline; if the manifest
      # is missing the channels: block, the parse returns [] and the
      # lookup is :not_found.
      manifest_path = Path.join([
        Application.app_dir(:esr),
        "priv/plugins/claude_code/manifest.yaml"
      ])

      # In dev/test, plugins ship under runtime/lib/.../plugins/<name>/manifest.yaml,
      # not priv. Resolve via the same path the loader uses.
      manifest_path =
        if File.exists?(manifest_path) do
          manifest_path
        else
          Path.expand(
            "../../../../../lib/esr/plugins/claude_code/manifest.yaml",
            __DIR__
          )
        end

      {:ok, manifest} = Esr.Plugin.Manifest.parse(manifest_path)

      assert Enum.any?(manifest.channels, fn ch ->
               ch.name == "mcp_stdio" and ch.module == Mcp
             end),
             "manifest.yaml must declare channels: with mcp_stdio → #{inspect(Mcp)}"

      # Replay loader's registration step (idempotent — Registry.register/3
      # is upsert-style per registry_test.exs).
      Enum.each(manifest.channels, fn %{name: name, module: module} ->
        :ok = Esr.Channel.Registry.register("claude_code", name, module)
      end)

      assert {:ok, Mcp} = Esr.Channel.Registry.lookup("claude_code.mcp_stdio")
    end
  end

  defp unique_sid, do: "test-mcphttp-#{System.unique_integer([:positive])}"
end
