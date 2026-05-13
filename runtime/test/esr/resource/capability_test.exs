defmodule Esr.CapabilitiesTest do
  @moduledoc """
  `Esr.Resource.Capability.has?/2` keys caps by UUID (since PR-348 /
  Cap.UuidTranslator). For Feishu inbounds carrying `ou_*` as principal_id,
  the URI store alias `feishu/<ou>` → canonical user URI yields the UUID,
  and the cap check retries against that UUID. Direct check on raw open_id
  still runs first (PR-21q bootstrap auto-grant before user_add).
  """
  use ExUnit.Case, async: false

  setup do
    if Process.whereis(Esr.Uri.Store) == nil do
      start_supervised!(Esr.Uri.Store)
    end

    prior_grants =
      try do
        :ets.tab2list(:esr_capabilities_grants) |> Map.new()
      rescue
        _ -> %{}
      end

    Esr.Resource.Capability.Grants.load_snapshot(%{})
    Esr.Test.UserFixture.load_snapshot(%{})

    on_exit(fn ->
      Esr.Resource.Capability.Grants.load_snapshot(prior_grants)
      Esr.Test.UserFixture.load_snapshot(%{})
    end)

    :ok
  end

  test "raw open_id direct hit (PR-21q bootstrap path)" do
    Esr.Resource.Capability.Grants.load_snapshot(%{
      "ou_xyz" => ["workspace.create"]
    })

    assert Esr.Resource.Capability.has?("ou_xyz", "workspace.create")
    refute Esr.Resource.Capability.has?("ou_xyz", "session.list")
  end

  test "open_id resolves via URI store to canonical UUID with cap" do
    # UserFixture.load_snapshot/1 synthesizes UUID "test-uuid-linyilun"
    # and registers the alias feishu/ou_xyz → users/test-uuid-linyilun.
    Esr.Test.UserFixture.load_snapshot(%{
      "linyilun" => %Esr.Entity.User.Struct{
        username: "linyilun",
        feishu_ids: ["ou_xyz"]
      }
    })

    Esr.Resource.Capability.Grants.load_snapshot(%{
      "test-uuid-linyilun" => ["workspace.create"]
    })

    # Inbound carries principal_id = ou_xyz; cap is keyed by UUID.
    # Resolver retries against the UUID and finds the grant.
    assert Esr.Resource.Capability.has?("ou_xyz", "workspace.create")
  end

  test "raw open_id and UUID grants compose for the same user" do
    Esr.Test.UserFixture.load_snapshot(%{
      "linyilun" => %Esr.Entity.User.Struct{
        username: "linyilun",
        feishu_ids: ["ou_xyz"]
      }
    })

    Esr.Resource.Capability.Grants.load_snapshot(%{
      "ou_xyz" => ["workspace.create"],
      "test-uuid-linyilun" => ["session.list"]
    })

    # Direct open_id hit.
    assert Esr.Resource.Capability.has?("ou_xyz", "workspace.create")
    # Falls through to UUID resolution.
    assert Esr.Resource.Capability.has?("ou_xyz", "session.list")
  end

  test "no binding + no direct grant → false" do
    Esr.Resource.Capability.Grants.load_snapshot(%{
      "test-uuid-linyilun" => ["workspace.create"]
    })

    # `ou_unbound` is not aliased to any canonical user URI, and isn't
    # in Grants directly either.
    refute Esr.Resource.Capability.has?("ou_unbound", "workspace.create")
  end

  test "UUID-typed principal_id (admin queue path) hits directly" do
    # Admin CLI submits (after Cap.UuidTranslator on the input side) carry
    # principal_id = the UUID. Direct lookup fires first.
    Esr.Resource.Capability.Grants.load_snapshot(%{
      "test-uuid-linyilun" => ["workspace.create"]
    })

    assert Esr.Resource.Capability.has?("test-uuid-linyilun", "workspace.create")
  end

  test "URI store path: principal_id has no user alias → falls back to direct grants" do
    Esr.Test.UserFixture.load_snapshot(%{})
    Esr.Resource.Capability.Grants.load_snapshot(%{"ou_xyz" => ["workspace.create"]})

    # No alias → resolver returns :not_found → only direct grant lookup runs.
    assert Esr.Resource.Capability.has?("ou_xyz", "workspace.create")
  end

  test "regression: Feishu inbound /session:new with UUID-keyed wildcard grant" do
    # The exact shape of the 2026-05-12 live-test failure:
    # - user_add seeded capabilities.yaml with principal_id = UUID and caps ["*"]
    # - /feishu:bind aliased feishu/<ou> → canonical user URI carrying that UUID
    # - Inbound /session:new carries principal_id = ou_*, expects wildcard to apply
    Esr.Test.UserFixture.load_snapshot(%{
      "linyilun" => %Esr.Entity.User.Struct{
        username: "linyilun",
        feishu_ids: ["ou_97f164"]
      }
    })

    Esr.Resource.Capability.Grants.load_snapshot(%{
      "test-uuid-linyilun" => ["*"]
    })

    assert :ok = Esr.Resource.Capability.has_all?("ou_97f164", ["session.new", "agent.spawn"])
  end
end
