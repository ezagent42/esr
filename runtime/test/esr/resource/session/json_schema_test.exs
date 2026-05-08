defmodule Esr.Resource.Session.JsonSchemaTest do
  use ExUnit.Case, async: true

  @uuid_v4 "a1b2c3d4-e5f6-4a7b-8c9d-e0f1a2b3c4d5"
  @owner_uuid "b2c3d4e5-f6a7-4b8c-9d0e-f1a2b3c4d5e6"

  @valid %{
    "schema_version" => 1,
    "id" => @uuid_v4,
    "name" => "esr-dev",
    "owner_user" => @owner_uuid,
    "workspace_id" => @uuid_v4,
    "agents" => [%{"type" => "cc", "name" => "esr-dev", "config" => %{}}],
    "primary_agent" => "esr-dev",
    "attached_chats" => [],
    "created_at" => "2026-05-07T12:00:00Z",
    "transient" => false
  }

  defp schema_path do
    Application.app_dir(:esr, "priv/schemas/session.v1.json")
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

  test "missing required field id fails" do
    bad = Map.delete(@valid, "id")
    assert {:error, _} = validate(bad)
  end

  test "missing required field owner_user fails" do
    bad = Map.delete(@valid, "owner_user")
    assert {:error, _} = validate(bad)
  end

  test "invalid uuid in id fails" do
    bad = Map.put(@valid, "id", "not-a-uuid")
    assert {:error, _} = validate(bad)
  end

  test "wrong schema_version fails" do
    bad = Map.put(@valid, "schema_version", 2)
    assert {:error, _} = validate(bad)
  end

  test "transient as non-boolean fails" do
    bad = Map.put(@valid, "transient", "yes")
    assert {:error, _} = validate(bad)
  end
end
