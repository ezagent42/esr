defmodule Esr.Resource.Session.JsonWriterTest do
  use ExUnit.Case, async: true
  alias Esr.Resource.Session.{JsonWriter, FileLoader, Struct}

  @uuid "a1b2c3d4-e5f6-4a7b-8c9d-e0f1a2b3c4d5"
  @owner_uuid "b2c3d4e5-f6a7-4b8c-9d0e-f1a2b3c4d5e6"
  @ws_uuid "c3d4e5f6-a7b8-4c9d-0e1f-a2b3c4d5e6f7"

  setup do
    tmp = Path.join(System.tmp_dir!(), "session_jw_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)
    %{tmp: tmp}
  end

  defp sample_struct do
    %Struct{
      id: @uuid,
      name: "esr-dev",
      owner_user: @owner_uuid,
      workspace_id: @ws_uuid,
      agents: [%{type: "cc", name: "esr-dev", config: %{}}],
      primary_agent: "esr-dev",
      attached_chats: [],
      created_at: "2026-05-07T12:00:00Z",
      transient: false
    }
  end

  test "writes session.json and produces valid JSON", %{tmp: tmp} do
    path = Path.join(tmp, "session.json")
    assert :ok = JsonWriter.write(path, sample_struct())
    assert File.exists?(path)
    assert {:ok, _decoded} = Jason.decode(File.read!(path))
  end

  test "no .tmp file remains after successful write", %{tmp: tmp} do
    path = Path.join(tmp, "session.json")
    JsonWriter.write(path, sample_struct())
    refute File.exists?(path <> ".tmp")
  end

  test "creates parent directories as needed", %{tmp: tmp} do
    path = Path.join([tmp, "deep", "nested", "session.json"])
    assert :ok = JsonWriter.write(path, sample_struct())
    assert File.exists?(path)
  end

  test "round-trip: write then load returns equal struct", %{tmp: tmp} do
    path = Path.join(tmp, "session.json")
    original = sample_struct()
    JsonWriter.write(path, original)
    assert {:ok, loaded} = FileLoader.load(path, [])
    assert loaded.id == original.id
    assert loaded.name == original.name
    assert loaded.owner_user == original.owner_user
    assert loaded.workspace_id == original.workspace_id
    assert loaded.primary_agent == original.primary_agent
    assert loaded.transient == original.transient
  end
end
