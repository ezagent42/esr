defmodule Esr.FeishuChatProxyRoutingTest do
  @moduledoc """
  Phase M-2.1 invariant: FCP routes to its peers via
  `Esr.ActorQuery.list_by_role/2` (Index 3) instead of
  `Keyword.get(state.neighbors, role)`.

  This test does not boot a full FCP — it only verifies the M-1
  infrastructure (register_attrs + ActorQuery.list_by_role) works for
  the role atoms FCP consults at runtime: `:cc_process` and
  `:feishu_app_proxy`. End-to-end routing is exercised by the existing
  scope_router_test and feishu_chat_proxy_cross_app_test suites.
  """

  use ExUnit.Case, async: false

  test "list_by_role/2 returns the registered cc_process pid" do
    sid = "fcp-route-test-cc-#{System.unique_integer([:positive])}"
    actor_id = "cc-fake-#{System.unique_integer([:positive])}"

    :ok =
      Esr.Entity.Registry.register_attrs(actor_id, %{
        session_id: sid,
        name: "cc-test-" <> sid,
        role: :cc_process
      })

    assert [pid] = Esr.ActorQuery.list_by_role(sid, :cc_process)
    assert pid == self()
  end

  test "list_by_role/2 returns the registered feishu_app_proxy pid" do
    sid = "fcp-route-test-faa-#{System.unique_integer([:positive])}"
    actor_id = "faa-fake-#{System.unique_integer([:positive])}"

    :ok =
      Esr.Entity.Registry.register_attrs(actor_id, %{
        session_id: sid,
        name: "faa-test-" <> sid,
        role: :feishu_app_proxy
      })

    assert [pid] = Esr.ActorQuery.list_by_role(sid, :feishu_app_proxy)
    assert pid == self()
  end

  test "list_by_role/2 returns [] when no peer registered" do
    sid = "fcp-route-test-empty-#{System.unique_integer([:positive])}"
    assert [] == Esr.ActorQuery.list_by_role(sid, :cc_process)
    assert [] == Esr.ActorQuery.list_by_role(sid, :feishu_app_proxy)
  end
end
