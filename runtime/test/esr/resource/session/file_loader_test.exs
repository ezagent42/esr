defmodule Esr.Resource.Session.FileLoaderTest do
  use ExUnit.Case, async: true
  alias Esr.Resource.Session.{FileLoader, Struct}

  @uuid "a1b2c3d4-e5f6-4a7b-8c9d-e0f1a2b3c4d5"
  @owner_uuid "b2c3d4e5-f6a7-4b8c-9d0e-f1a2b3c4d5e6"
  @ws_uuid "c3d4e5f6-a7b8-4c9d-0e1f-a2b3c4d5e6f7"
  @inst_uuid "d4e5f6a7-b8c9-4d0e-9f1a-b2c3d4e5f6a7"

  @valid %{
    "schema_version" => 2,
    "id" => @uuid,
    "name" => "esr-dev",
    "owner_user" => @owner_uuid,
    "workspace_id" => @ws_uuid,
    "agent_ids" => [@inst_uuid],
    "primary_agent" => "esr-dev",
    "attached_chats" => [],
    "created_at" => "2026-05-07T12:00:00Z",
    "transient" => false
  }

  setup do
    tmp = Path.join(System.tmp_dir!(), "session_fl_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)
    %{tmp: tmp}
  end

  defp write_fixture(tmp, data) do
    path = Path.join(tmp, "session.json")
    File.write!(path, Jason.encode!(data))
    path
  end

  test "loads a valid session.json (v2 hardcut)", %{tmp: tmp} do
    path = write_fixture(tmp, @valid)
    assert {:ok, %Struct{} = s} = FileLoader.load(path, [])
    assert s.id == @uuid
    assert s.name == "esr-dev"
    assert s.owner_user == @owner_uuid
    assert s.workspace_id == @ws_uuid
    assert s.agent_ids == [@inst_uuid]
    assert s.primary_agent == "esr-dev"
    assert s.transient == false
  end

  test "returns :file_missing when file does not exist", %{tmp: tmp} do
    assert {:error, :file_missing} = FileLoader.load(Path.join(tmp, "nofile.json"), [])
  end

  test "rejects wrong schema_version (v1 hardcut)", %{tmp: tmp} do
    path = write_fixture(tmp, Map.put(@valid, "schema_version", 1))
    assert {:error, {:bad_schema_version, 1}} = FileLoader.load(path, [])
  end

  test "rejects malformed UUID in id", %{tmp: tmp} do
    path = write_fixture(tmp, Map.put(@valid, "id", "not-a-uuid"))
    assert {:error, {:bad_uuid, "not-a-uuid"}} = FileLoader.load(path, [])
  end

  test "rejects empty owner_user", %{tmp: tmp} do
    path = write_fixture(tmp, Map.put(@valid, "owner_user", ""))
    assert {:error, {:missing_field, "owner_user"}} = FileLoader.load(path, [])
  end

  test "rejects missing required field name", %{tmp: tmp} do
    path = write_fixture(tmp, Map.delete(@valid, "name"))
    assert {:error, {:missing_field, "name"}} = FileLoader.load(path, [])
  end
end
