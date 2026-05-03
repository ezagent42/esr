defmodule Esr.Capabilities.GrantsBroadcastTest do
  @moduledoc """
  P3-3a.1: `Esr.Capabilities.Grants.load_snapshot/1` broadcasts a
  per-principal `:grants_changed` signal on PubSub so per-session
  projections (`Scope.Process`) can refresh their local grants map.

  The broadcast topic is `grants_changed:<principal_id>` on the
  app-level `EsrWeb.PubSub`.
  """
  use ExUnit.Case, async: false

  alias Esr.Capabilities.Grants

  setup do
    if Process.whereis(Grants) == nil do
      start_supervised!(Grants)
    end

    # Reset to a known baseline so test-vs-test contamination doesn't
    # hide a missing broadcast.
    Grants.load_snapshot(%{})
    :ok
  end

  test "load_snapshot broadcasts grants_changed for newly added principal" do
    :ok = Phoenix.PubSub.subscribe(EsrWeb.PubSub, "grants_changed:ou_carol_pbroadcast")
    :ok = Grants.load_snapshot(%{"ou_carol_pbroadcast" => ["workspace:proj/msg.send"]})
    assert_receive :grants_changed, 500
  end

  test "load_snapshot broadcasts grants_changed for each principal in the snapshot" do
    :ok = Phoenix.PubSub.subscribe(EsrWeb.PubSub, "grants_changed:ou_alice_pbroadcast")
    :ok = Phoenix.PubSub.subscribe(EsrWeb.PubSub, "grants_changed:ou_bob_pbroadcast")

    :ok =
      Grants.load_snapshot(%{
        "ou_alice_pbroadcast" => ["*"],
        "ou_bob_pbroadcast" => ["workspace:x/y"]
      })

    assert_receive :grants_changed, 500
    assert_receive :grants_changed, 500
  end

  test "load_snapshot broadcasts grants_changed for principals whose grants were removed" do
    # First populate so ou_dave has a grant.
    :ok = Grants.load_snapshot(%{"ou_dave_pbroadcast" => ["workspace:proj/msg.send"]})

    # Now subscribe and replace with a snapshot that drops ou_dave_pbroadcast.
    :ok = Phoenix.PubSub.subscribe(EsrWeb.PubSub, "grants_changed:ou_dave_pbroadcast")
    :ok = Grants.load_snapshot(%{"ou_eve_pbroadcast" => ["*"]})

    # ou_dave_pbroadcast's grants changed (from [...] to []) — must broadcast.
    assert_receive :grants_changed, 500
  end

  test "load_snapshot does NOT broadcast for principals whose grants did not change" do
    :ok = Grants.load_snapshot(%{"ou_stable_pbroadcast" => ["workspace:proj/msg.send"]})

    # Re-submitting an identical snapshot should be a no-op from the
    # broadcast point of view (no downstream projections need refresh).
    :ok = Phoenix.PubSub.subscribe(EsrWeb.PubSub, "grants_changed:ou_stable_pbroadcast")
    :ok = Grants.load_snapshot(%{"ou_stable_pbroadcast" => ["workspace:proj/msg.send"]})

    refute_receive :grants_changed, 200
  end
end
