defmodule Esr.Migrations.AgentInstancesV1ToV2Test do
  @moduledoc """
  Phase 7 (2026-05-10) — covers
  `Esr.Migrations.AgentInstancesV1ToV2.run/1`.

  Asserts:
    1. A v1 session.json with embedded `agents:[]` is rewritten to v2
       (`schema_version: 2`, `agent_ids: [<uuid>...]`, no `agents` key).
    2. Each agent entry produces a file at
       `sessions/<sid>/agents/<uuid>.json` validating against the
       v2 schema (single-element `session_ids: [<sid>]`).
    3. Re-running the migration is a no-op (idempotent) — second-run
       counts report `migrated=0, skipped=N`.
  """

  use ExUnit.Case, async: true

  @uuid "a1b2c3d4-e5f6-4a7b-8c9d-e0f1a2b3c4d5"
  @owner_uuid "b2c3d4e5-f6a7-4b8c-9d0e-f1a2b3c4d5e6"
  @ws_uuid "c3d4e5f6-a7b8-4c9d-9e1f-a2b3c4d5e6f7"

  setup do
    tmp = Path.join(System.tmp_dir!(), "esr_mig_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(Path.join(tmp, "sessions"))
    on_exit(fn -> File.rm_rf!(tmp) end)
    %{home: tmp}
  end

  defp write_v1_session(home, sid, agents) do
    dir = Path.join([home, "sessions", sid])
    File.mkdir_p!(dir)

    doc = %{
      "schema_version" => 1,
      "id" => sid,
      "name" => "test-session",
      "owner_user" => @owner_uuid,
      "workspace_id" => @ws_uuid,
      "agents" => agents,
      "primary_agent" => List.first(agents)["name"],
      "attached_chats" => [],
      "created_at" => "2026-05-09T12:00:00Z",
      "transient" => false
    }

    File.write!(Path.join(dir, "session.json"), Jason.encode!(doc))
    dir
  end

  defp v2_agent_schema do
    Esr.Paths.agent_instance_schema_v2()
    |> File.read!()
    |> Jason.decode!()
    |> ExJsonSchema.Schema.resolve()
  end

  defp v2_session_schema do
    Esr.Paths.session_schema_v2()
    |> File.read!()
    |> Jason.decode!()
    |> ExJsonSchema.Schema.resolve()
  end

  test "migrates a v1 session.json with one agent into v2 layout", %{home: home} do
    write_v1_session(home, @uuid, [
      %{"type" => "cc", "name" => "alice", "config" => %{}}
    ])

    assert {:ok, %{migrated: 1, skipped: 0}} =
             Esr.Migrations.AgentInstancesV1ToV2.run(home)

    # session.json is v2 now.
    session_doc =
      Path.join([home, "sessions", @uuid, "session.json"])
      |> File.read!()
      |> Jason.decode!()

    assert session_doc["schema_version"] == 2
    assert [_uuid] = session_doc["agent_ids"]
    refute Map.has_key?(session_doc, "agents")

    # The session.json validates against the v2 schema.
    assert :ok = ExJsonSchema.Validator.validate(v2_session_schema(), session_doc)

    # The per-instance file is at sessions/<sid>/agents/<uuid>.json and validates.
    [instance_id] = session_doc["agent_ids"]
    agent_path = Path.join([home, "sessions", @uuid, "agents", instance_id <> ".json"])
    assert File.exists?(agent_path)

    agent_doc = agent_path |> File.read!() |> Jason.decode!()
    assert agent_doc["schema_version"] == 2
    assert agent_doc["session_ids"] == [@uuid]
    assert agent_doc["name"] == "alice"
    assert agent_doc["type"] == "cc"

    assert :ok = ExJsonSchema.Validator.validate(v2_agent_schema(), agent_doc)
  end

  test "migrates multiple agents", %{home: home} do
    write_v1_session(home, @uuid, [
      %{"type" => "cc", "name" => "alice", "config" => %{}},
      %{"type" => "cc", "name" => "bob", "config" => %{"model" => "opus"}}
    ])

    {:ok, %{migrated: 1}} = Esr.Migrations.AgentInstancesV1ToV2.run(home)

    session_doc =
      Path.join([home, "sessions", @uuid, "session.json"])
      |> File.read!()
      |> Jason.decode!()

    assert length(session_doc["agent_ids"]) == 2

    names =
      for inst_id <- session_doc["agent_ids"] do
        path = Path.join([home, "sessions", @uuid, "agents", inst_id <> ".json"])
        File.read!(path) |> Jason.decode!() |> Map.get("name")
      end
      |> Enum.sort()

    assert names == ["alice", "bob"]
  end

  test "second run is idempotent (skips v2 sessions)", %{home: home} do
    write_v1_session(home, @uuid, [%{"type" => "cc", "name" => "alice", "config" => %{}}])

    {:ok, %{migrated: 1, skipped: 0}} = Esr.Migrations.AgentInstancesV1ToV2.run(home)

    # Capture first agent file content.
    session_doc =
      Path.join([home, "sessions", @uuid, "session.json"])
      |> File.read!()
      |> Jason.decode!()

    [instance_id] = session_doc["agent_ids"]
    first_agent_content = Path.join([home, "sessions", @uuid, "agents", instance_id <> ".json"]) |> File.read!()

    # Re-run.
    assert {:ok, %{migrated: 0, skipped: 1}} =
             Esr.Migrations.AgentInstancesV1ToV2.run(home)

    # Files unchanged.
    second_agent_content = Path.join([home, "sessions", @uuid, "agents", instance_id <> ".json"]) |> File.read!()
    assert first_agent_content == second_agent_content
  end

  test "empty sessions dir → migrated=0, skipped=0", %{home: home} do
    assert {:ok, %{migrated: 0, skipped: 0}} =
             Esr.Migrations.AgentInstancesV1ToV2.run(home)
  end

  test "no sessions dir at all → migrated=0, skipped=0" do
    tmp = Path.join(System.tmp_dir!(), "esr_no_sess_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)

    assert {:ok, %{migrated: 0, skipped: 0}} =
             Esr.Migrations.AgentInstancesV1ToV2.run(tmp)
  end

  test "v1 session with no agents migrates to empty agent_ids", %{home: home} do
    write_v1_session(home, @uuid, [])

    {:ok, %{migrated: 1}} = Esr.Migrations.AgentInstancesV1ToV2.run(home)

    session_doc =
      Path.join([home, "sessions", @uuid, "session.json"])
      |> File.read!()
      |> Jason.decode!()

    assert session_doc["agent_ids"] == []
    assert session_doc["schema_version"] == 2
  end
end
