defmodule Esr.Session.AgentSpawnerTest do
  @moduledoc """
  R6 — unit tests for `Esr.Session.AgentSpawner`, the stateless
  Spawner extracted from `Esr.Session.Router`. Mirrors the pre-R6
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

  describe "verify_pipeline_complete/2 — PR-2 post-spawn integrity check" do
    test "returns :ok when no inbound stages declare a verifiable role" do
      # Stage impl strings that role_for_impl/1 maps to nil are excluded
      # from the expected set — verification is a no-op.
      agent_def = %{
        pipeline: %{
          inbound: [
            %{"name" => "noop", "impl" => "UnknownModule", "kind" => "stateful"}
          ]
        }
      }

      sid = "vpc-empty-#{System.unique_integer([:positive])}"
      assert :ok = AgentSpawner.verify_pipeline_complete_for_test(sid, agent_def)
    end

    test "returns :ok when pipeline.inbound is empty / nil" do
      sid = "vpc-empty2-#{System.unique_integer([:positive])}"

      assert :ok =
               AgentSpawner.verify_pipeline_complete_for_test(
                 sid,
                 %{pipeline: %{inbound: []}}
               )

      assert :ok =
               AgentSpawner.verify_pipeline_complete_for_test(
                 sid,
                 %{pipeline: %{inbound: nil}}
               )
    end

    test "returns {:error, :pipeline_incomplete} when an expected role isn't spawned" do
      # FeishuChatProxy maps to :feishu_chat_proxy in role_for_impl/1.
      # No actor registered under {sid, :feishu_chat_proxy} → missing.
      agent_def = %{
        pipeline: %{
          inbound: [
            %{
              "name" => "feishu_chat_proxy",
              "impl" => "Esr.Plugins.Feishu.FeishuChatProxy",
              "kind" => "stateful"
            }
          ]
        }
      }

      sid = "vpc-missing-#{System.unique_integer([:positive])}"

      # The function calls Esr.Session.Router.end_session/1 on the
      # tear-down path. For an unknown sid, that's a no-op
      # ({:noreply, _} from the GenServer.call).
      assert {:error, :pipeline_incomplete} =
               AgentSpawner.verify_pipeline_complete_for_test(sid, agent_def)
    end
  end
end
