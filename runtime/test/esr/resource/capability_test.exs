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

  # Walkthrough-4 C16 (= team todo `chat-cap-check-username-to-uuid-hop`):
  # the previous 2-hop chain (open_id → username) couldn't reach grants
  # keyed by UUID. The `user_add` auto-admin path (#282) keys cap rows
  # by the user's UUID, so chat-side `/session:new` got
  # `missing_capabilities` even with admin grants on file.
  #
  # New behaviour: resolve to canonical user (whatever form arrives),
  # collect every identifier form (UUID, username, every bound ou_*),
  # check Grants against each. The cases below exercise every cell of
  # the 3-form principal × 3-form grant matrix.

  describe "C16 — N-form identifier resolution" do
    @uuid_yao "b31e9dcc-e2dd-4c4e-8c8e-ef87ead83bb9"

    setup do
      Esr.Test.UserFixture.load_snapshot(
        %{
          "yao" => %Esr.Entity.User.Struct{
            username: "yao",
            feishu_ids: ["ou_yao_app1", "ou_yao_app2"]
          }
        },
        %{"yao" => @uuid_yao}
      )

      :ok
    end

    test "open_id principal hits UUID-keyed grant (the auto-admin scenario)" do
      Esr.Resource.Capability.Grants.load_snapshot(%{
        @uuid_yao => ["session:default/create"]
      })

      assert Esr.Resource.Capability.has?("ou_yao_app1", "session:default/create"),
             "open_id → username → UUID chain must reach UUID-keyed grants"
    end

    test "open_id principal hits open_id-keyed grant from a DIFFERENT app" do
      # The user has two bound ou_* (e.g. they're in two Feishu apps).
      # A cap granted via raw open_id during one app's bootstrap should
      # still apply when the user shows up via the other app's open_id.
      Esr.Resource.Capability.Grants.load_snapshot(%{"ou_yao_app2" => ["msg.send"]})

      assert Esr.Resource.Capability.has?("ou_yao_app1", "msg.send"),
             "alternate-app open_id must reach the user's other open_id-keyed grants"
    end

    test "username principal hits UUID-keyed grant" do
      # Admin-queue path sometimes carries `principal_id = "yao"` already.
      # The username → UUID hop is needed to see the auto-admin row.
      Esr.Resource.Capability.Grants.load_snapshot(%{
        @uuid_yao => ["session:default/create"]
      })

      assert Esr.Resource.Capability.has?("yao", "session:default/create")
    end

    test "UUID principal hits username-keyed grant" do
      # `esr cap grant yao msg.send` writes a username-keyed row. If
      # principal_id arrives as UUID (CLI submit path), we still need
      # to see that grant via UUID → username hop.
      Esr.Resource.Capability.Grants.load_snapshot(%{"yao" => ["msg.send"]})

      assert Esr.Resource.Capability.has?(@uuid_yao, "msg.send")
    end

    test "UUID principal hits open_id-keyed grant from any bound app" do
      Esr.Resource.Capability.Grants.load_snapshot(%{"ou_yao_app1" => ["workspace.create"]})

      assert Esr.Resource.Capability.has?(@uuid_yao, "workspace.create"),
             "UUID → feishu_ids hop must surface open_id-keyed grants"
    end

    test "missing permission still returns false across all forms" do
      Esr.Resource.Capability.Grants.load_snapshot(%{@uuid_yao => ["msg.send"]})

      refute Esr.Resource.Capability.has?("ou_yao_app1", "session:default/create"),
             "cap not granted in any form must remain false"
    end
  end
end
