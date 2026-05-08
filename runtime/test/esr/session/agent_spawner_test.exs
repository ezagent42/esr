defmodule Esr.Session.AgentSpawnerTest do
  @moduledoc """
  R6 — unit tests for `Esr.Session.AgentSpawner`, the stateless
  Spawner extracted from `Esr.Scope.Router`. Mirrors the pre-R6
  `scope_router_channel_adapter_test.exs` content (the
  `parse_channel_adapter` / `build_ctx` / `stamp_channel_adapter`
  surface area) and locks in the new test-helper home.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Esr.Session.AgentSpawner

  describe "parse_channel_adapter/1" do
    test "regex captures entire family incl. underscored suffix (feishu_app)" do
      target = "admin::feishu_app_adapter_default"
      assert AgentSpawner.parse_channel_adapter(target) == {:ok, "feishu_app"}
    end

    test "alphanumeric app_id does not bleed into family capture" do
      assert AgentSpawner.parse_channel_adapter(
               "admin::feishu_app_adapter_e2e-mock"
             ) == {:ok, "feishu_app"}
    end

    test "multi-underscore family captured whole (slack_v2)" do
      assert AgentSpawner.parse_channel_adapter(
               "admin::slack_v2_adapter_acme"
             ) == {:ok, "slack_v2"}
    end

    test "non-matching target falls back to feishu and logs a warning" do
      log =
        capture_log(fn ->
          assert AgentSpawner.parse_channel_adapter(
                   "admin::malformed-no-underscore"
                 ) == {:ok, "feishu"}
        end)

      assert log =~ "channel_adapter: non-matching proxy target"
    end
  end

  describe "build_ctx_for_test/2 — params thread channel_adapter" do
    test "FeishuAppProxy target seeds :channel_adapter in ctx" do
      spec = %{
        "impl" => "Esr.Entity.FeishuAppProxy",
        "target" => "admin::feishu_app_adapter_e2e-mock"
      }

      ctx = AgentSpawner.build_ctx_for_test(spec, %{app_id: "e2e-mock"})
      assert ctx[:channel_adapter] == "feishu_app"
      assert ctx[:app_id] == "e2e-mock"
    end

    test "non-FeishuAppProxy spec returns ctx without :channel_adapter" do
      spec = %{"impl" => "Esr.Entity.CCProxy"}
      ctx = AgentSpawner.build_ctx_for_test(spec, %{})
      refute Map.has_key?(ctx, :channel_adapter)
    end
  end

  describe "stamp_channel_adapter_for_test/2 — spawn_pipeline stamps params" do
    test "agent with FeishuAppProxy lifts channel_adapter=feishu_app" do
      agent_def = %{
        pipeline: %{inbound: []},
        proxies: [
          %{
            "name" => "feishu_app_proxy",
            "impl" => "Esr.Entity.FeishuAppProxy",
            "target" => "admin::feishu_app_adapter_default"
          }
        ]
      }

      params = AgentSpawner.stamp_channel_adapter_for_test(agent_def, %{})
      assert params[:channel_adapter] == "feishu_app"
    end

    test "agent with no proxies falls back to feishu" do
      agent_def = %{pipeline: %{inbound: []}, proxies: []}
      params = AgentSpawner.stamp_channel_adapter_for_test(agent_def, %{})
      assert params[:channel_adapter] == "feishu"
    end
  end

  describe "@behaviour Esr.Interface.Spawner conformance" do
    test "exports spawn/3 and terminate/2" do
      assert function_exported?(AgentSpawner, :spawn, 3)
      assert function_exported?(AgentSpawner, :terminate, 2)
    end
  end
end
