defmodule Esr.Entity.User.JsonSchemaTest do
  use ExUnit.Case, async: true

  @uuid "a1b2c3d4-e5f6-4a7b-8c9d-e0f1a2b3c4d5"

  @valid %{
    "schema_version" => 1,
    "id" => @uuid,
    "username" => "linyilun",
    "display_name" => "林懿伦",
    "created_at" => "2026-05-07T12:00:00Z"
  }

  defp schema_path do
    Application.app_dir(:esr, "priv/schemas/user.v1.json")
  end

  defp validate(doc) do
    schema = schema_path() |> File.read!() |> Jason.decode!() |> ExJsonSchema.Schema.resolve()
    ExJsonSchema.Validator.validate(schema, doc)
  end

  test "schema file exists" do
    assert File.exists?(schema_path())
  end

  test "valid document passes" do
    assert :ok = validate(@valid)
  end

  test "missing id fails" do
    assert {:error, _} = validate(Map.delete(@valid, "id"))
  end

  test "missing username fails" do
    assert {:error, _} = validate(Map.delete(@valid, "username"))
  end

  test "invalid UUID in id fails" do
    assert {:error, _} = validate(Map.put(@valid, "id", "bad"))
  end

  test "empty username fails" do
    assert {:error, _} = validate(Map.put(@valid, "username", ""))
  end

  test "wrong schema_version fails" do
    assert {:error, _} = validate(Map.put(@valid, "schema_version", 2))
  end

  test "display_name is optional — minimal valid doc" do
    minimal = Map.take(@valid, ["schema_version", "id", "username"])
    assert :ok = validate(minimal)
  end
end
