defmodule Esr.ScopeRouterChannelAdapterTest do
  @moduledoc """
  Task D1 — verify `channel_adapter` is extracted from the
  `proxies[].target` string and propagated into session params.
  Named cases cover the four rows in T0 §1.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Esr.Scope

  describe "parse_channel_adapter/1" do
    test "regex captures entire family incl. underscored suffix (feishu_app)" do
      target = "admin::feishu_app_adapter_default"
      assert Scope.Router.parse_channel_adapter(target) == {:ok, "feishu_app"}
    end

    test "alphanumeric app_id does not bleed into family capture" do
      assert Scope.Router.parse_channel_adapter(
               "admin::feishu_app_adapter_e2e-mock"
             ) == {:ok, "feishu_app"}
    end

    test "multi-underscore family captured whole (slack_v2)" do
      assert Scope.Router.parse_channel_adapter(
               "admin::slack_v2_adapter_acme"
             ) == {:ok, "slack_v2"}
    end

    test "non-matching target falls back to feishu and logs a warning" do
      log =
        capture_log(fn ->
          assert Scope.Router.parse_channel_adapter(
                   "admin::malformed-no-underscore"
                 ) == {:ok, "feishu"}
        end)

      assert log =~ "channel_adapter: non-matching proxy target"
    end
  end

  describe "do_create/1 params thread channel_adapter" do
    test "FeishuAppProxy target seeds :channel_adapter in ctx" do
      # The `build_ctx` clause for FeishuAppProxy is the seed point.
      # We exercise it directly (it's a private helper but tested
      # via a narrow public hook: see `Scope.Router.build_ctx_for_test/2`).
      spec = %{
        "impl" => "Esr.Entities.FeishuAppProxy",
        "target" => "admin::feishu_app_adapter_e2e-mock"
      }

      ctx = Scope.Router.build_ctx_for_test(spec, %{app_id: "e2e-mock"})
      assert ctx[:channel_adapter] == "feishu_app"
      assert ctx[:app_id] == "e2e-mock"
    end

    test "non-FeishuAppProxy spec returns ctx without :channel_adapter" do
      spec = %{"impl" => "Esr.Entities.CCProxy"}
      ctx = Scope.Router.build_ctx_for_test(spec, %{})
      refute Map.has_key?(ctx, :channel_adapter)
    end
  end

  describe "spawn_pipeline/3 stamps :channel_adapter into params" do
    test "agent with FeishuAppProxy lifts channel_adapter=feishu_app" do
      # Drive do_create indirectly: build a fake agent_def and call the
      # exposed shim. A full session spawn is overkill for this test;
      # the stamp step is the observable the test targets.
      agent_def = %{
        pipeline: %{inbound: []},
        proxies: [
          %{"name" => "feishu_app_proxy",
            "impl" => "Esr.Entities.FeishuAppProxy",
            "target" => "admin::feishu_app_adapter_default"}
        ]
      }

      params = Scope.Router.stamp_channel_adapter_for_test(agent_def, %{})
      assert params[:channel_adapter] == "feishu_app"
    end

    test "agent with no proxies falls back to feishu" do
      agent_def = %{pipeline: %{inbound: []}, proxies: []}
      params = Scope.Router.stamp_channel_adapter_for_test(agent_def, %{})
      assert params[:channel_adapter] == "feishu"
    end
  end
end
