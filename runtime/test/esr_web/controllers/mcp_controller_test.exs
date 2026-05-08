defmodule EsrWeb.McpControllerTest do
  use ExUnit.Case, async: false

  alias Esr.Resource.Media

  # ------------------------------------------------------------------
  # SSE attachment notification (Task 2.5)
  # ------------------------------------------------------------------

  describe "SSE attachment notification (Task 2.5)" do
    setup do
      tmp = Path.join(System.tmp_dir!(), "mcp_attach_#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp)
      saved_home = System.get_env("ESRD_HOME")
      saved_inst = System.get_env("ESR_INSTANCE")
      System.put_env("ESRD_HOME", tmp)
      System.put_env("ESR_INSTANCE", "test")

      on_exit(fn ->
        File.rm_rf!(tmp)

        if saved_home,
          do: System.put_env("ESRD_HOME", saved_home),
          else: System.delete_env("ESRD_HOME")

        if saved_inst,
          do: System.put_env("ESR_INSTANCE", saved_inst),
          else: System.delete_env("ESR_INSTANCE")
      end)

      {:ok, tmp: tmp}
    end

    test "non-text envelope produces meta.kind and meta.path", %{tmp: tmp} do
      src = Path.join(tmp, "fixture.png")
      File.write!(src, "fake png bytes")
      {:ok, %{uri: uri, path: real_path}} = Media.store(:image, src, %{adapter: "test"})

      envelope = %{
        "content" => uri,
        "msg_type" => "image",
        "media_uri" => uri,
        "chat_id" => "oc_xxx",
        "user_id" => "ou_yyy",
        "message_id" => "om_zzz"
      }

      params = EsrWeb.McpController.build_notification_params(envelope)

      assert params["content"] == "[image attachment]"
      assert params["meta"]["kind"] == "image"
      assert params["meta"]["path"] == real_path
      assert params["meta"]["chat_id"] == "oc_xxx"
      assert params["meta"]["user_id"] == "ou_yyy"
      assert params["meta"]["message_id"] == "om_zzz"
      # internal fields must be stripped from user-visible meta
      refute Map.has_key?(params["meta"], "msg_type")
      refute Map.has_key?(params["meta"], "media_uri")
    end

    test "non-text with file kind produces 'file attachment' content", %{tmp: tmp} do
      src = Path.join(tmp, "data.bin")
      File.write!(src, "blob")
      {:ok, %{uri: uri, path: real_path}} = Media.store(:file, src, %{})

      envelope = %{
        "content" => uri,
        "msg_type" => "file",
        "media_uri" => uri,
        "chat_id" => "oc_x"
      }

      params = EsrWeb.McpController.build_notification_params(envelope)
      assert params["content"] == "[file attachment]"
      assert params["meta"]["kind"] == "file"
      assert params["meta"]["path"] == real_path
    end

    test "text envelope unchanged (no msg_type)" do
      envelope = %{"content" => "hello world", "chat_id" => "oc_x"}
      params = EsrWeb.McpController.build_notification_params(envelope)
      assert params["content"] == "hello world"
      refute Map.has_key?(params["meta"], "kind")
      refute Map.has_key?(params["meta"], "path")
      assert params["meta"]["chat_id"] == "oc_x"
    end

    test "msg_type=text is treated as text path (kind/path absent)" do
      envelope = %{"content" => "hello", "msg_type" => "text", "chat_id" => "oc_x"}
      params = EsrWeb.McpController.build_notification_params(envelope)
      assert params["content"] == "hello"
      refute Map.has_key?(params["meta"], "kind")
      refute Map.has_key?(params["meta"], "path")
    end

    test "non-text envelope with phaser failure falls back gracefully", %{tmp: _tmp} do
      # URI references nonexistent resource — resolve returns :not_found.
      bogus_uri =
        "esr://test@localhost:4001/resources/image/" <>
          String.duplicate("0", 64) <> ".png"

      envelope = %{
        "content" => bogus_uri,
        "msg_type" => "image",
        "media_uri" => bogus_uri,
        "chat_id" => "oc_x"
      }

      params = EsrWeb.McpController.build_notification_params(envelope)
      # Must not crash; content reflects the failure
      assert is_binary(params["content"])
      assert params["content"] =~ "unavailable"
      # meta.kind is set even on failure
      assert params["meta"]["kind"] == "image"
      # meta.path absent when resolution failed
      refute Map.has_key?(params["meta"], "path")
    end
  end

  # ------------------------------------------------------------------
  # Text path — pre-Task-2.5 baseline
  # ------------------------------------------------------------------

  describe "build_notification_params/1 text baseline" do
    test "applies default runtime_mode and source when absent" do
      envelope = %{"content" => "hi", "chat_id" => "oc_1"}
      params = EsrWeb.McpController.build_notification_params(envelope)
      assert params["meta"]["runtime_mode"] == "discussion"
      assert params["meta"]["source"] == "feishu"
    end

    test "passes through all standard meta fields" do
      envelope = %{
        "content" => "msg",
        "chat_id" => "oc_1",
        "app_id" => "cli_1",
        "message_id" => "om_1",
        "user" => "Alice",
        "ts" => "1234",
        "thread_id" => "t_1",
        "runtime_mode" => "focus",
        "source" => "slack",
        "user_id" => "ou_1",
        "workspace" => "my_ws"
      }

      params = EsrWeb.McpController.build_notification_params(envelope)
      meta = params["meta"]
      assert meta["chat_id"] == "oc_1"
      assert meta["app_id"] == "cli_1"
      assert meta["message_id"] == "om_1"
      assert meta["user"] == "Alice"
      assert meta["ts"] == "1234"
      assert meta["thread_id"] == "t_1"
      assert meta["runtime_mode"] == "focus"
      assert meta["source"] == "slack"
      assert meta["user_id"] == "ou_1"
      assert meta["workspace"] == "my_ws"
    end

    test "nil and empty-string meta values are filtered out" do
      envelope = %{"content" => "x", "chat_id" => nil, "app_id" => ""}
      params = EsrWeb.McpController.build_notification_params(envelope)
      refute Map.has_key?(params["meta"], "chat_id")
      refute Map.has_key?(params["meta"], "app_id")
    end
  end
end
