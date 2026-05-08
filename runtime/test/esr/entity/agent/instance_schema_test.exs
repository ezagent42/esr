defmodule Esr.Entity.Agent.InstanceSchemaTest do
  use ExUnit.Case, async: true

  @session_uuid "a1b2c3d4-e5f6-4a7b-8c9d-e0f1a2b3c4d5"
  @instance_uuid "b2c3d4e5-f6a7-4b8c-9d0e-f1a2b3c4d5e6"

  @valid %{
    "schema_version" => 1,
    "id" => @instance_uuid,
    "session_id" => @session_uuid,
    "type" => "cc",
    "name" => "esr-dev",
    "config" => %{},
    "created_at" => "2026-05-07T12:00:00Z"
  }

  defp schema_path do
    Application.app_dir(:esr, "priv/schemas/agent_instance.v1.json")
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

  test "missing required field type fails" do
    bad = Map.delete(@valid, "type")
    assert {:error, _} = validate(bad)
  end

  test "missing required field name fails" do
    bad = Map.delete(@valid, "name")
    assert {:error, _} = validate(bad)
  end

  test "missing required field session_id fails" do
    bad = Map.delete(@valid, "session_id")
    assert {:error, _} = validate(bad)
  end

  test "wrong schema_version fails" do
    bad = Map.put(@valid, "schema_version", 2)
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
end
