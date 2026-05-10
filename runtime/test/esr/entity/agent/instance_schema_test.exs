defmodule Esr.Entity.Agent.InstanceSchemaTest do
  use ExUnit.Case, async: true

  @session_uuid "a1b2c3d4-e5f6-4a7b-8c9d-e0f1a2b3c4d5"
  @session_uuid_2 "b2c3d4e5-f6a7-4b8c-9d0e-f1a2b3c4d5e6"
  @instance_uuid "c3d4e5f6-a7b8-4c9d-9e1f-a2b3c4d5e6f7"

  @valid %{
    "schema_version" => 2,
    "id" => @instance_uuid,
    "session_ids" => [@session_uuid],
    "type" => "cc",
    "name" => "esr-dev",
    "config" => %{},
    "created_at" => "2026-05-07T12:00:00Z"
  }

  defp schema_path do
    Application.app_dir(:esr, "priv/schemas/agent_instance.v2.json")
  end

  defp validate(doc) do
    schema = schema_path() |> File.read!() |> Jason.decode!() |> ExJsonSchema.Schema.resolve()
    ExJsonSchema.Validator.validate(schema, doc)
  end

  test "schema file exists" do
    assert File.exists?(schema_path())
  end

  test "valid document passes validation" do
    assert :ok = validate(@valid)
  end

  test "v2 accepts multi-session session_ids" do
    multi = Map.put(@valid, "session_ids", [@session_uuid, @session_uuid_2])
    assert :ok = validate(multi)
  end

  test "missing required field type fails" do
    bad = Map.delete(@valid, "type")
    assert {:error, _} = validate(bad)
  end

  test "missing required field name fails" do
    bad = Map.delete(@valid, "name")
    assert {:error, _} = validate(bad)
  end

  test "missing required field session_ids fails" do
    bad = Map.delete(@valid, "session_ids")
    assert {:error, _} = validate(bad)
  end

  test "empty session_ids array fails (minItems: 1)" do
    bad = Map.put(@valid, "session_ids", [])
    assert {:error, _} = validate(bad)
  end

  test "wrong schema_version fails" do
    bad = Map.put(@valid, "schema_version", 1)
    assert {:error, _} = validate(bad)
  end

  test "empty type string fails" do
    bad = Map.put(@valid, "type", "")
    assert {:error, _} = validate(bad)
  end

  test "empty name string fails" do
    bad = Map.put(@valid, "name", "")
    assert {:error, _} = validate(bad)
  end

  test "v1-shaped session_id (singular) is rejected" do
    bad =
      @valid
      |> Map.delete("session_ids")
      |> Map.put("session_id", @session_uuid)

    assert {:error, _} = validate(bad)
  end
end
