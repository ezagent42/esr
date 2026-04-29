defmodule EsrWeb.PendingActionsGuardTest do
  use ExUnit.Case, async: false

  alias EsrWeb.PendingActionsGuard

  setup do
    if Process.whereis(PendingActionsGuard) == nil do
      start_supervised!(PendingActionsGuard)
    end

    # Clean up any previous test's entries
    PendingActionsGuard.drop("test", "oc_x")
    :ok
  end

  test "intercept? with no registered action returns :passthrough" do
    assert :passthrough = PendingActionsGuard.intercept?("user", "oc_x", "confirm")
    assert :passthrough = PendingActionsGuard.intercept?("user", "oc_x", "cancel")
    assert :passthrough = PendingActionsGuard.intercept?("user", "oc_x", "anything")
  end

  test "register + intercept? confirm consumes and notifies caller" do
    :ok = PendingActionsGuard.register("test", "oc_x", :end_session, %{"name" => "foo"})

    assert {:consume, :confirm} = PendingActionsGuard.intercept?("test", "oc_x", "confirm")
    assert_receive {:pending_action, :end_session, :confirmed, %{"name" => "foo"}}, 200

    # Entry consumed; subsequent intercept passes through
    assert :passthrough = PendingActionsGuard.intercept?("test", "oc_x", "confirm")
  end

  test "register + intercept? cancel consumes and notifies caller" do
    :ok = PendingActionsGuard.register("test", "oc_x", :end_session, %{"name" => "bar"})

    assert {:consume, :cancel} = PendingActionsGuard.intercept?("test", "oc_x", "cancel")
    assert_receive {:pending_action, :end_session, :cancelled, %{"name" => "bar"}}, 200
  end

  test "intercept? with non-confirm/cancel text passes through (entry stays)" do
    :ok = PendingActionsGuard.register("test", "oc_x", :end_session, %{"name" => "baz"})

    assert :passthrough = PendingActionsGuard.intercept?("test", "oc_x", "hello")
    # Entry still present
    assert {:ok, _} = PendingActionsGuard.lookup("test", "oc_x")
  end

  test "case-insensitive match on confirm/cancel" do
    :ok = PendingActionsGuard.register("test", "oc_x", :end_session, %{})
    assert {:consume, :confirm} = PendingActionsGuard.intercept?("test", "oc_x", "  CONFIRM  ")
  end

  test "ttl expiry notifies caller :expired and removes entry" do
    :ok =
      PendingActionsGuard.register("test", "oc_x", :end_session, %{"who" => "alice"},
        ttl_ms: 30
      )

    assert_receive {:pending_action, :end_session, :expired, %{"who" => "alice"}}, 500
    assert :not_found = PendingActionsGuard.lookup("test", "oc_x")
  end

  test "register on existing key cancels prior entry (last write wins)" do
    :ok =
      PendingActionsGuard.register("test", "oc_x", :end_session, %{"v" => 1},
        ttl_ms: 5_000
      )

    :ok =
      PendingActionsGuard.register("test", "oc_x", :end_session, %{"v" => 2},
        ttl_ms: 5_000
      )

    assert {:ok, %{payload: %{"v" => 2}}} = PendingActionsGuard.lookup("test", "oc_x")
  end

  test "drop removes entry without notifying caller" do
    :ok = PendingActionsGuard.register("test", "oc_x", :end_session, %{})
    :ok = PendingActionsGuard.drop("test", "oc_x")
    assert :not_found = PendingActionsGuard.lookup("test", "oc_x")
    refute_receive {:pending_action, _, _, _}, 100
  end

  test "different (principal_id, chat_id) keys are isolated" do
    :ok = PendingActionsGuard.register("alice", "oc_x", :end_session, %{"a" => 1})
    :ok = PendingActionsGuard.register("bob", "oc_x", :end_session, %{"a" => 2})

    assert {:consume, :confirm} = PendingActionsGuard.intercept?("alice", "oc_x", "confirm")
    assert_receive {:pending_action, :end_session, :confirmed, %{"a" => 1}}, 200

    # Bob's entry survives
    assert {:ok, %{payload: %{"a" => 2}}} = PendingActionsGuard.lookup("bob", "oc_x")

    PendingActionsGuard.drop("bob", "oc_x")
  end
end
