defmodule Esr.Entity.Agent.InstanceTest do
  use ExUnit.Case, async: true
  alias Esr.Entity.Agent.Instance

  @session_uuid "a1b2c3d4-e5f6-4a7b-8c9d-e0f1a2b3c4d5"
  @session_uuid_2 "b2c3d4e5-f6a7-4b8c-9d0e-f1a2b3c4d5e6"

  test "default struct has expected keys" do
    i = %Instance{}
    assert Map.has_key?(i, :id)
    assert Map.has_key?(i, :session_ids)
    assert Map.has_key?(i, :type)
    assert Map.has_key?(i, :name)
    assert Map.has_key?(i, :config)
    assert Map.has_key?(i, :created_at)
  end

  test "config defaults to empty map" do
    assert %Instance{}.config == %{}
  end

  test "session_ids defaults to empty list" do
    assert %Instance{}.session_ids == []
  end

  test "can be constructed with all fields" do
    i = %Instance{
      id: "b2c3d4e5-f6a7-4b8c-9d0e-f1a2b3c4d5e6",
      session_ids: [@session_uuid],
      type: "cc",
      name: "esr-dev",
      config: %{"model" => "claude-opus-4"},
      created_at: "2026-05-07T12:00:00Z"
    }
    assert i.type == "cc"
    assert i.name == "esr-dev"
    assert i.config == %{"model" => "claude-opus-4"}
    assert i.session_ids == [@session_uuid]
  end

  test "name accepts dash-separated strings" do
    i = %Instance{name: "my-agent-1"}
    assert i.name == "my-agent-1"
  end

  describe "primary_session_id/1" do
    test "returns the first session_id (originating session)" do
      i = %Instance{session_ids: [@session_uuid, @session_uuid_2]}
      assert Instance.primary_session_id(i) == @session_uuid
    end

    test "returns nil when session_ids is empty" do
      assert Instance.primary_session_id(%Instance{}) == nil
    end
  end

  describe "attached?/2" do
    test "true when session_id is in session_ids" do
      i = %Instance{session_ids: [@session_uuid, @session_uuid_2]}
      assert Instance.attached?(i, @session_uuid_2)
    end

    test "false when session_id is not in session_ids" do
      i = %Instance{session_ids: [@session_uuid]}
      refute Instance.attached?(i, @session_uuid_2)
    end
  end
end
