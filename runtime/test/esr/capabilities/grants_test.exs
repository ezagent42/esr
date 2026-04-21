defmodule Esr.Capabilities.GrantsTest do
  use ExUnit.Case, async: false

  alias Esr.Capabilities.Grants

  setup do
    # Grants is started by Esr.Application via Esr.Capabilities.Supervisor.
    # Fall back to start_supervised! only if the app-level singleton is absent.
    if Process.whereis(Grants) == nil do
      start_supervised!(Grants)
    end

    # Reset state between tests — the app-level Grants is long-lived.
    Grants.load_snapshot(%{})
    :ok
  end

  test "empty snapshot denies everything" do
    refute Grants.has?("ou_xxx", "workspace:proj/msg.send")
  end

  test "admin wildcard grants all" do
    Grants.load_snapshot(%{"ou_admin" => ["*"]})
    assert Grants.has?("ou_admin", "workspace:any/any.perm")
  end

  test "exact match" do
    Grants.load_snapshot(%{"ou_alice" => ["workspace:proj-a/msg.send"]})
    assert Grants.has?("ou_alice", "workspace:proj-a/msg.send")
    refute Grants.has?("ou_alice", "workspace:proj-b/msg.send")
    refute Grants.has?("ou_alice", "workspace:proj-a/session.create")
  end

  test "scope wildcard" do
    Grants.load_snapshot(%{"ou_reader" => ["workspace:*/msg.send"]})
    assert Grants.has?("ou_reader", "workspace:proj-a/msg.send")
    assert Grants.has?("ou_reader", "workspace:proj-b/msg.send")
    refute Grants.has?("ou_reader", "workspace:proj-a/session.create")
  end

  test "permission wildcard within scope" do
    Grants.load_snapshot(%{"ou_owner" => ["workspace:proj-a/*"]})
    assert Grants.has?("ou_owner", "workspace:proj-a/msg.send")
    assert Grants.has?("ou_owner", "workspace:proj-a/session.create")
    refute Grants.has?("ou_owner", "workspace:proj-b/msg.send")
  end

  test "prefix glob does not match" do
    # session.* is NOT a valid matcher — only `*` as whole segment matches
    Grants.load_snapshot(%{"ou_x" => ["workspace:proj/session.*"]})
    refute Grants.has?("ou_x", "workspace:proj/session.create")
  end

  test "load_snapshot atomically replaces prior state" do
    Grants.load_snapshot(%{"ou_a" => ["*"]})
    assert Grants.has?("ou_a", "workspace:x/y")
    Grants.load_snapshot(%{"ou_b" => ["*"]})
    refute Grants.has?("ou_a", "workspace:x/y")
    assert Grants.has?("ou_b", "workspace:x/y")
  end
end
