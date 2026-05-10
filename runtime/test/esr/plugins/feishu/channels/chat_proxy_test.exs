defmodule Esr.Plugins.Feishu.Channels.ChatProxyTest do
  @moduledoc """
  Tests for `Esr.Plugins.Feishu.Channels.ChatProxy`.

  Spec: `docs/superpowers/specs/2026-05-10-session-template-and-channel.md`,
  Phase 3.

  `async: false` because the suite shares the global `EsrWeb.PubSub` and
  the `Esr.Channel.Instances` Registry (both already brought up by
  `Esr.Application`); concurrent tests would race on session_id reuse if
  any test author accidentally hard-coded one.
  """

  use ExUnit.Case, async: false

  alias Esr.Plugins.Feishu.Channels.ChatProxy

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
      assert function_exported?(ChatProxy, :start_link, 1)
      assert function_exported?(ChatProxy, :dispatch, 2)
      assert function_exported?(ChatProxy, :subscribe, 3)
      assert function_exported?(ChatProxy, :config_schema, 0)
    end

    test "config_schema/0 returns a JSON-Schema-lite map (object, no properties yet)" do
      schema = ChatProxy.config_schema()
      assert schema["type"] == "object"
      assert schema["properties"] == %{}
    end
  end

  describe "lifecycle" do
    test "start_link/1 with session_id starts a GenServer registered in Esr.Channel.Instances" do
      sid = unique_sid()
      {:ok, pid} = ChatProxy.start_link(session_id: sid)
      assert is_pid(pid)
      assert Process.alive?(pid)

      # Registered under the Esr.Channel.Instances via-key
      assert [{^pid, _}] =
               Registry.lookup(Esr.Channel.Instances, "feishu.chat_proxy:" <> sid)

      GenServer.stop(pid)
    end

    test "start_link/1 without session_id raises KeyError" do
      assert_raise KeyError, fn -> ChatProxy.start_link([]) end
    end

    test "crash + restart re-registers under same name" do
      sid = unique_sid()

      # `start_link` links the channel to the test pid; trap exits so we
      # can kill the channel without taking out the test process.
      Process.flag(:trap_exit, true)

      {:ok, pid1} = ChatProxy.start_link(session_id: sid)

      # Take down pid1; the via-name slot in Registry is freed so a fresh
      # start_link with the same session_id should succeed under the same
      # registered name.
      ref = Process.monitor(pid1)
      Process.exit(pid1, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid1, _}, 500
      # Also drain the {:EXIT, pid1, :killed} message from the link.
      assert_receive {:EXIT, ^pid1, :killed}, 500

      # New pid registers under the same key.
      {:ok, pid2} = ChatProxy.start_link(session_id: sid)
      assert pid1 != pid2
      assert Process.alive?(pid2)

      assert [{^pid2, _}] =
               Registry.lookup(Esr.Channel.Instances, "feishu.chat_proxy:" <> sid)

      GenServer.stop(pid2)
    end
  end

  describe "dispatch/2" do
    test "broadcasts msg on feishu_outbound/<sid> topic" do
      sid = unique_sid()
      {:ok, pid} = ChatProxy.start_link(session_id: sid)

      Phoenix.PubSub.subscribe(EsrWeb.PubSub, "feishu_outbound/" <> sid)

      msg = %{"kind" => "reply", "args" => %{"text" => "hello"}}
      assert :ok = ChatProxy.dispatch(pid, msg)

      assert_receive ^msg, 500

      GenServer.stop(pid)
    end

    test "dispatch with no PubSub listeners still returns :ok (fire-and-forget)" do
      sid = unique_sid()
      {:ok, pid} = ChatProxy.start_link(session_id: sid)

      # Nobody is subscribed to feishu_outbound/<sid>; broadcast must not
      # raise or block.
      assert :ok = ChatProxy.dispatch(pid, %{"kind" => "noop"})

      GenServer.stop(pid)
    end
  end

  describe "subscribe/3 + inbound forwarding" do
    test "subscribes to feishu_inbound/<sid> at boot and forwards inbound events to :inbound listeners" do
      sid = unique_sid()
      {:ok, pid} = ChatProxy.start_link(session_id: sid)

      :ok = ChatProxy.subscribe(pid, self(), :inbound)

      envelope = %{"payload" => %{"text" => "hi from feishu"}}

      Phoenix.PubSub.broadcast(
        EsrWeb.PubSub,
        "feishu_inbound/" <> sid,
        {:feishu_inbound_event, sid, envelope}
      )

      assert_receive {:feishu_inbound_event, ^sid, ^envelope}, 500

      GenServer.stop(pid)
    end

    test "subscribers on other topics are not notified by inbound events" do
      sid = unique_sid()
      {:ok, pid} = ChatProxy.start_link(session_id: sid)

      :ok = ChatProxy.subscribe(pid, self(), :other_topic)

      Phoenix.PubSub.broadcast(
        EsrWeb.PubSub,
        "feishu_inbound/" <> sid,
        {:feishu_inbound_event, sid, %{"payload" => %{}}}
      )

      refute_receive {:feishu_inbound_event, ^sid, _}, 100

      GenServer.stop(pid)
    end

    test "multiple :inbound subscribers all receive forwarded events" do
      sid = unique_sid()
      {:ok, pid} = ChatProxy.start_link(session_id: sid)

      parent = self()

      relay = fn label ->
        spawn_link(fn ->
          receive do
            msg ->
              send(parent, {:relay, label, msg})
          end
        end)
      end

      l1 = relay.(:l1)
      l2 = relay.(:l2)

      :ok = ChatProxy.subscribe(pid, l1, :inbound)
      :ok = ChatProxy.subscribe(pid, l2, :inbound)

      Phoenix.PubSub.broadcast(
        EsrWeb.PubSub,
        "feishu_inbound/" <> sid,
        {:feishu_inbound_event, sid, %{"payload" => %{"text" => "fanout"}}}
      )

      assert_receive {:relay, :l1, {:feishu_inbound_event, ^sid, _}}, 500
      assert_receive {:relay, :l2, {:feishu_inbound_event, ^sid, _}}, 500

      GenServer.stop(pid)
    end
  end

  describe "Esr.Channel.Registry smoke (manifest → loader → registry)" do
    test "feishu's manifest declares chat_proxy and loader registers it" do
      # Smoke proof that manifest → loader → registry is wired correctly.
      # We don't rely on app-boot side-effects surviving (other tests, e.g.
      # `Esr.Channel.RegistryTest`, call `Registry.clear/0` in on_exit and
      # would race here). Instead we re-parse the live manifest + replay
      # the loader's `register_channels/1` step inline; if the manifest
      # is missing the channels: block, the parse returns [] and the
      # lookup is :not_found.
      manifest_path = Path.join([
        Application.app_dir(:esr),
        "priv/plugins/feishu/manifest.yaml"
      ])

      # In dev/test, plugins ship under runtime/lib/.../plugins/<name>/manifest.yaml,
      # not priv. Resolve via the same path the loader uses.
      manifest_path =
        if File.exists?(manifest_path) do
          manifest_path
        else
          Path.expand(
            "../../../../../lib/esr/plugins/feishu/manifest.yaml",
            __DIR__
          )
        end

      {:ok, manifest} = Esr.Plugin.Manifest.parse(manifest_path)

      assert Enum.any?(manifest.channels, fn ch ->
               ch.name == "chat_proxy" and ch.module == ChatProxy
             end),
             "manifest.yaml must declare channels: with chat_proxy → #{inspect(ChatProxy)}"

      # Replay loader's registration step (idempotent — Registry.register/3
      # is upsert-style per registry_test.exs).
      Enum.each(manifest.channels, fn %{name: name, module: module} ->
        :ok = Esr.Channel.Registry.register("feishu", name, module)
      end)

      assert {:ok, ChatProxy} = Esr.Channel.Registry.lookup("feishu.chat_proxy")
    end
  end

  defp unique_sid, do: "test-fcp-channel-#{System.unique_integer([:positive])}"
end
