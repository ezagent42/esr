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

  # 2026-05-09: Inbound.handle/2 stopped invoking a directive_fn closure.
  # It now returns either {:directive, action, args, ctx} when the caller
  # should dispatch the download_file directive, or {:error,
  # :unsupported_kind} on capability-miss. Every test below pins one of
  # these two return shapes — the directive_fn-related tests collapsed
  # into the single happy-path "returns directive descriptor" check.

  test "handle/2 returns directive descriptor on happy path" do
    PluginRegistry.register("test_target", %{inbound: [:image, :file], outbound: []})

    assert {:directive, "download_file", args, ctx} =
             Inbound.handle(inbound_fixture())

    assert args["msg_id"] == "om_xx"
    assert args["file_key"] == "img_yy"
    assert args["file_name"] == "x.png"
    assert args["msg_type"] == "image"

    assert ctx.msg_type == "image"
    assert ctx.meta.chat_id == "oc_xx"
    assert ctx.meta.sender_id == "ou_yy"
  end

  test "handle/2 returns :unsupported_kind when target doesn't declare type" do
    # target supports file but not image
    PluginRegistry.register("test_target", %{inbound: [:file], outbound: []})

    assert {:error, :unsupported_kind} = Inbound.handle(inbound_fixture("image"))
  end

  test "handle/2 returns :unsupported_kind when target plugin not registered at all" do
    # No PluginRegistry.register call for "test_target"
    assert {:error, :unsupported_kind} = Inbound.handle(inbound_fixture("image"))
  end

  test "handle/2 returns :unsupported_kind for unknown msg_type strings" do
    PluginRegistry.register("test_target", %{inbound: [:image, :file], outbound: []})

    inbound = %{
      msg_type: "definitely_not_a_known_atom_#{System.unique_integer([:positive])}",
      adapter_msg: %{},
      meta: %{
        chat_id: "oc_x",
        sender_id: "ou_y",
        source_plugin: "test_source",
        target_plugin: "test_target"
      }
    }

    assert {:error, :unsupported_kind} = Inbound.handle(inbound)
  end

  test "handle/2 forwards meta unchanged in ctx" do
    PluginRegistry.register("test_target", %{inbound: [:file], outbound: []})

    inbound = %{
      msg_type: "file",
      adapter_msg: %{
        "msg_id" => "om_x",
        "file_key" => "f_y",
        "file_name" => "doc.pdf",
        "msg_type" => "file"
      },
      meta: %{
        chat_id: "oc_chat",
        sender_id: "ou_send",
        source_plugin: "test_source",
        target_plugin: "test_target",
        custom_field: "preserved"
      }
    }

    assert {:directive, "download_file", _args, ctx} = Inbound.handle(inbound)
    assert ctx.meta.chat_id == "oc_chat"
    assert ctx.meta.custom_field == "preserved"
  end
end
