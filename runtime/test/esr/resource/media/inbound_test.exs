defmodule Esr.Resource.Media.InboundTest do
  use ExUnit.Case, async: false
  alias Esr.Resource.Media.Inbound
  alias Esr.Resource.Media.PluginRegistry

  setup do
    # PluginRegistry started by Esr.Application; clear test entries on exit.
    on_exit(fn ->
      PluginRegistry.unregister("test_target")
      PluginRegistry.unregister("test_source")
    end)
    :ok
  end

  defp inbound_fixture(msg_type \\ "image") do
    %{
      msg_type: msg_type,
      adapter_msg: %{
        "msg_id" => "om_xx",
        "file_key" => "img_yy",
        "file_name" => "x.png",
        "msg_type" => msg_type
      },
      meta: %{
        chat_id: "oc_xx",
        sender_id: "ou_yy",
        source_plugin: "test_source",
        target_plugin: "test_target"
      }
    }
  end

  test "handle/2 returns {:ok, envelope} with URI on happy path" do
    PluginRegistry.register("test_target", %{inbound: [:image, :file], outbound: []})

    fake_directive = fn _action, _args ->
      {:ok,
       %{
         "ok" => true,
         "result" => %{
           "uri" =>
             "esr://test@localhost:4001/resources/image/" <>
               String.duplicate("a", 64) <> ".png",
           "sha256" => String.duplicate("a", 64),
           "path" => "/tmp/fake.png"
         }
       }}
    end

    assert {:ok, envelope} = Inbound.handle(inbound_fixture(), directive_fn: fake_directive)
    assert envelope.msg_type == "image"
    assert String.starts_with?(envelope.content, "esr://")
    assert envelope.content =~ "/resources/image/"
    assert envelope.meta.chat_id == "oc_xx"
    assert envelope.meta.sender_id == "ou_yy"
  end

  test "handle/2 returns :unsupported_kind when target doesn't declare type" do
    # target supports file but not image
    PluginRegistry.register("test_target", %{inbound: [:file], outbound: []})

    unreachable = fn _, _ -> raise "should not be called" end

    assert {:error, :unsupported_kind} =
             Inbound.handle(inbound_fixture("image"), directive_fn: unreachable)
  end

  test "handle/2 returns :unsupported_kind when target plugin not registered at all" do
    # No PluginRegistry.register call for "test_target"
    unreachable = fn _, _ -> raise "should not be called" end
    assert {:error, :unsupported_kind} =
             Inbound.handle(inbound_fixture("image"), directive_fn: unreachable)
  end

  test "handle/2 propagates directive failure" do
    PluginRegistry.register("test_target", %{inbound: [:image], outbound: []})

    fake_directive = fn _, _ ->
      {:ok, %{"ok" => false, "error" => "lark_fetch_failed: 404"}}
    end

    assert {:error, {:download_failed, "lark_fetch_failed: 404"}} =
             Inbound.handle(inbound_fixture("image"), directive_fn: fake_directive)
  end

  test "handle/2 forwards meta unchanged" do
    PluginRegistry.register("test_target", %{inbound: [:file], outbound: []})

    inbound = %{
      msg_type: "file",
      adapter_msg: %{"msg_id" => "om_x", "file_key" => "f_y", "file_name" => "doc.pdf", "msg_type" => "file"},
      meta: %{
        chat_id: "oc_chat",
        sender_id: "ou_send",
        source_plugin: "test_source",
        target_plugin: "test_target",
        custom_field: "preserved"
      }
    }

    fake_directive = fn _, _ ->
      {:ok, %{"ok" => true, "result" => %{"uri" => "esr://test@localhost:4001/resources/file/" <> String.duplicate("b", 64) <> ".pdf", "sha256" => String.duplicate("b", 64), "path" => "/tmp/y.pdf"}}}
    end

    {:ok, envelope} = Inbound.handle(inbound, directive_fn: fake_directive)
    assert envelope.meta.chat_id == "oc_chat"
    assert envelope.meta.custom_field == "preserved"
  end
end
