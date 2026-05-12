defmodule Esr.CapabilitiesTest do
  @moduledoc """
  PR-21s 2026-04-29 — `Esr.Resource.Capability.has?/2` resolves a Feishu
  `ou_*` principal_id to the bound esr-username and consults BOTH
  cap tables. Lets operators grant caps by username without
  invalidating PR-21q's bootstrap auto-grant on raw open_id.
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

  test "open_id resolves via Users.Registry to esr-username with cap" do
    Esr.Test.UserFixture.load_snapshot(%{
      "linyilun" => %Esr.Entity.User.Struct{
        username: "linyilun",
        feishu_ids: ["ou_xyz"]
      }
    })

    Esr.Resource.Capability.Grants.load_snapshot(%{
      "linyilun" => ["workspace.create"]
    })

    # Inbound carries `principal_id = ou_xyz`; cap was granted to
    # `linyilun`. PR-21s makes this work.
    assert Esr.Resource.Capability.has?("ou_xyz", "workspace.create")
  end

  test "raw open_id wins when both keyed (no double-counting)" do
    Esr.Test.UserFixture.load_snapshot(%{
      "linyilun" => %Esr.Entity.User.Struct{
        username: "linyilun",
        feishu_ids: ["ou_xyz"]
      }
    })

    Esr.Resource.Capability.Grants.load_snapshot(%{
      "ou_xyz" => ["workspace.create"],
      "linyilun" => ["session.list"]
    })

    # Both lookups succeed for their respective caps.
    assert Esr.Resource.Capability.has?("ou_xyz", "workspace.create")
    assert Esr.Resource.Capability.has?("ou_xyz", "session.list")
  end

  test "no binding + no direct grant → false" do
    Esr.Resource.Capability.Grants.load_snapshot(%{
      "linyilun" => ["workspace.create"]
    })

    # Nobody bound `ou_unbound` to any esr user; raw lookup fails too.
    refute Esr.Resource.Capability.has?("ou_unbound", "workspace.create")
  end

  test "username-typed principal_id (admin queue path) still works directly" do
    # Admin CLI submits sometimes carry `principal_id = "linyilun"`
    # already (no resolution needed). Direct lookup still fires first.
    Esr.Resource.Capability.Grants.load_snapshot(%{
      "linyilun" => ["workspace.create"]
    })

    assert Esr.Resource.Capability.has?("linyilun", "workspace.create")
  end

  test "URI store path: principal_id has no esr-user binding → falls back to direct grants" do
    # PR-1 deleted User.Registry; the binding-resolution path now goes
    # via Esr.Uri.Compat.username_for_feishu_id/1 which reads the URI
    # store. With no users registered for the open_id, the path returns
    # :not_found and Capability.has?/2 falls back to direct-grant lookup.
    Esr.Test.UserFixture.load_snapshot(%{})
    Esr.Resource.Capability.Grants.load_snapshot(%{"ou_xyz" => ["workspace.create"]})

    assert Esr.Resource.Capability.has?("ou_xyz", "workspace.create")
  end
end
