defmodule Esr.Entity.Agent.InstanceTest do
  use ExUnit.Case, async: true
  alias Esr.Entity.Agent.Instance

  @session_uuid "a1b2c3d4-e5f6-4a7b-8c9d-e0f1a2b3c4d5"

  test "default struct has expected keys" do
    i = %Instance{}
    assert Map.has_key?(i, :id)
    assert Map.has_key?(i, :session_id)
    assert Map.has_key?(i, :type)
    assert Map.has_key?(i, :name)
    assert Map.has_key?(i, :config)
    assert Map.has_key?(i, :created_at)
  end

  test "config defaults to empty map" do
    assert %Instance{}.config == %{}
  end

  test "can be constructed with all fields" do
    i = %Instance{
      id: "b2c3d4e5-f6a7-4b8c-9d0e-f1a2b3c4d5e6",
      session_id: @session_uuid,
      type: "cc",
      name: "esr-dev",
      config: %{"model" => "claude-opus-4"},
      created_at: "2026-05-07T12:00:00Z"
    }
    assert i.type == "cc"
    assert i.name == "esr-dev"
    assert i.config == %{"model" => "claude-opus-4"}
  end

  test "name accepts dash-separated strings" do
    i = %Instance{name: "my-agent-1"}
    assert i.name == "my-agent-1"
  end
end
