defmodule Esr.Resource.Session.StructTest do
  use ExUnit.Case, async: true
  alias Esr.Resource.Session.Struct

  @uuid "a1b2c3d4-e5f6-4a7b-8c9d-e0f1a2b3c4d5"
  @inst_uuid "b2c3d4e5-f6a7-4b8c-9d0e-f1a2b3c4d5e6"

  test "default struct has expected keys" do
    s = %Struct{}
    assert Map.has_key?(s, :id)
    assert Map.has_key?(s, :name)
    assert Map.has_key?(s, :owner_user)
    assert Map.has_key?(s, :workspace_id)
    assert Map.has_key?(s, :agent_ids)
    assert Map.has_key?(s, :primary_agent)
    assert Map.has_key?(s, :attached_chats)
    assert Map.has_key?(s, :created_at)
    assert Map.has_key?(s, :transient)
  end

  test "agent_ids defaults to empty list" do
    assert %Struct{}.agent_ids == []
  end

  test "attached_chats defaults to empty list" do
    assert %Struct{}.attached_chats == []
  end

  test "transient defaults to false" do
    assert %Struct{}.transient == false
  end

  test "can be constructed with all fields" do
    s = %Struct{
      id: @uuid,
      name: "esr-dev",
      owner_user: "user-uuid-1",
      workspace_id: "ws-uuid-1",
      agent_ids: [@inst_uuid],
      primary_agent: "esr-dev",
      attached_chats: [%{chat_id: "oc_x", app_id: "cli_y", attached_by: "user-uuid-1", attached_at: "2026-05-07T12:00:00Z"}],
      created_at: "2026-05-07T12:00:00Z",
      transient: true
    }
    assert s.id == @uuid
    assert s.name == "esr-dev"
    assert s.transient == true
    assert s.agent_ids == [@inst_uuid]
  end
end
