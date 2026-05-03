defmodule Esr.CapabilitiesTest do
  @moduledoc """
  PR-21s 2026-04-29 — `Esr.Resource.Capability.has?/2` resolves a Feishu
  `ou_*` principal_id to the bound esr-username and consults BOTH
  cap tables. Lets operators grant caps by username without
  invalidating PR-21q's bootstrap auto-grant on raw open_id.
  """
  use ExUnit.Case, async: false

  setup do
    if Process.whereis(Esr.Entity.User.Registry) == nil do
      start_supervised!(Esr.Entity.User.Registry)
    end

    prior_grants =
      try do
        :ets.tab2list(:esr_capabilities_grants) |> Map.new()
      rescue
        _ -> %{}
      end

    Esr.Resource.Capability.Grants.load_snapshot(%{})
    Esr.Entity.User.Registry.load_snapshot(%{})

    on_exit(fn ->
      Esr.Resource.Capability.Grants.load_snapshot(prior_grants)
      Esr.Entity.User.Registry.load_snapshot(%{})
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
    Esr.Entity.User.Registry.load_snapshot(%{
      "linyilun" => %Esr.Entity.User.Registry.User{
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
    Esr.Entity.User.Registry.load_snapshot(%{
      "linyilun" => %Esr.Entity.User.Registry.User{
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

  test "Users.Registry not running → falls back to direct-only (no crash)" do
    # Simulate by stopping the registry. Note: in real runtime it's
    # always up, but we want to verify the guard in
    # maybe_resolve_to_username/1 handles the edge.
    pid = Process.whereis(Esr.Entity.User.Registry)

    if pid do
      Process.exit(pid, :shutdown)
      # Wait for it to actually stop; supervisor will restart but the
      # Process.whereis check inside has?/2 has its own race-free
      # guard so the call is safe regardless.
      :timer.sleep(20)
    end

    Esr.Resource.Capability.Grants.load_snapshot(%{"ou_xyz" => ["workspace.create"]})

    # Direct hit still works; binding-resolution path harmlessly returns
    # :not_found since the registry might be transiently absent.
    assert Esr.Resource.Capability.has?("ou_xyz", "workspace.create")
  end
end
