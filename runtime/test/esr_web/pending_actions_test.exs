defmodule EsrWeb.PendingActionsTest do
  use ExUnit.Case, async: false

  alias EsrWeb.PendingActions

  setup do
    if Process.whereis(PendingActions) == nil do
      start_supervised!(PendingActions)
    end

    # Clean up any previous test's entries
    PendingActions.drop("test", "oc_x")
    :ok
  end

  test "intercept? with no registered action returns :passthrough" do
    assert :passthrough = PendingActions.intercept?("user", "oc_x", "confirm")
    assert :passthrough = PendingActions.intercept?("user", "oc_x", "cancel")
    assert :passthrough = PendingActions.intercept?("user", "oc_x", "anything")
  end

  test "register + intercept? confirm consumes and notifies caller" do
    :ok = PendingActions.register("test", "oc_x", :end_session, %{"name" => "foo"})

    assert {:consume, :confirm} = PendingActions.intercept?("test", "oc_x", "confirm")
    assert_receive {:pending_action, :end_session, :confirmed, %{"name" => "foo"}}, 200

    # Entry consumed; subsequent intercept passes through
    assert :passthrough = PendingActions.intercept?("test", "oc_x", "confirm")
  end

  test "register + intercept? cancel consumes and notifies caller" do
    :ok = PendingActions.register("test", "oc_x", :end_session, %{"name" => "bar"})

    assert {:consume, :cancel} = PendingActions.intercept?("test", "oc_x", "cancel")
    assert_receive {:pending_action, :end_session, :cancelled, %{"name" => "bar"}}, 200
  end

  test "intercept? with non-confirm/cancel text passes through (entry stays)" do
    :ok = PendingActions.register("test", "oc_x", :end_session, %{"name" => "baz"})

    assert :passthrough = PendingActions.intercept?("test", "oc_x", "hello")
    # Entry still present
    assert {:ok, _} = PendingActions.lookup("test", "oc_x")
  end

  test "case-insensitive match on confirm/cancel" do
    :ok = PendingActions.register("test", "oc_x", :end_session, %{})
    assert {:consume, :confirm} = PendingActions.intercept?("test", "oc_x", "  CONFIRM  ")
  end

  test "ttl expiry notifies caller :expired and removes entry" do
    :ok =
      PendingActions.register("test", "oc_x", :end_session, %{"who" => "alice"},
        ttl_ms: 30
      )

    assert_receive {:pending_action, :end_session, :expired, %{"who" => "alice"}}, 500
    assert :not_found = PendingActions.lookup("test", "oc_x")
  end

  test "register on existing key cancels prior entry (last write wins)" do
    :ok =
      PendingActions.register("test", "oc_x", :end_session, %{"v" => 1},
        ttl_ms: 5_000
      )

    :ok =
      PendingActions.register("test", "oc_x", :end_session, %{"v" => 2},
        ttl_ms: 5_000
      )

    assert {:ok, %{payload: %{"v" => 2}}} = PendingActions.lookup("test", "oc_x")
  end

  test "drop removes entry without notifying caller" do
    :ok = PendingActions.register("test", "oc_x", :end_session, %{})
    :ok = PendingActions.drop("test", "oc_x")
    assert :not_found = PendingActions.lookup("test", "oc_x")
    refute_receive {:pending_action, _, _, _}, 100
  end

  test "different (principal_id, chat_id) keys are isolated" do
    :ok = PendingActions.register("alice", "oc_x", :end_session, %{"a" => 1})
    :ok = PendingActions.register("bob", "oc_x", :end_session, %{"a" => 2})

    assert {:consume, :confirm} = PendingActions.intercept?("alice", "oc_x", "confirm")
    assert_receive {:pending_action, :end_session, :confirmed, %{"a" => 1}}, 200

    # Bob's entry survives
    assert {:ok, %{payload: %{"a" => 2}}} = PendingActions.lookup("bob", "oc_x")

    PendingActions.drop("bob", "oc_x")
  end
end
