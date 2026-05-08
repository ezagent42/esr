defmodule Esr.Resource.Workspace.FileLoaderTest do
  use ExUnit.Case, async: true
  alias Esr.Resource.Workspace.{FileLoader, Struct}

  @valid %{
    "$schema" => "ignored",
    "schema_version" => 1,
    "id" => "7b9f3c1a-2d8e-4f1b-9a35-c4e2f8d63b71",
    "name" => "esr-dev",
    "owner" => "linyilun",
    "folders" => [%{"path" => "/tmp/repo", "name" => "esr"}],
    "agent" => "cc",
    "settings" => %{"cc.model" => "claude-opus-4-7"},
    "env" => %{"FOO" => "bar"},
    "chats" => [%{"chat_id" => "oc_x", "app_id" => "cli_y", "kind" => "dm"}],
    "transient" => false
  }

  setup do
    tmp = Path.join(System.tmp_dir!(), "fl_test_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)
    %{tmp: tmp}
  end

  test "parses a valid workspace.json (ESR-bound)", %{tmp: tmp} do
    ws_dir = Path.join(tmp, "esr-dev")
    File.mkdir_p!(ws_dir)
    path = Path.join(ws_dir, "workspace.json")
    File.write!(path, Jason.encode!(@valid))

    assert {:ok, %Struct{} = ws} = FileLoader.load(path, location: {:esr_bound, ws_dir})
    assert ws.id == "7b9f3c1a-2d8e-4f1b-9a35-c4e2f8d63b71"
    assert ws.name == "esr-dev"
    assert ws.owner == "linyilun"
    assert ws.folders == [%{path: "/tmp/repo", name: "esr"}]
    assert ws.agent == "cc"
    assert ws.settings == %{"cc.model" => "claude-opus-4-7"}
    assert ws.env == %{"FOO" => "bar"}
    assert ws.chats == [%{chat_id: "oc_x", app_id: "cli_y", kind: "dm"}]
    assert ws.transient == false
    assert ws.location == {:esr_bound, ws_dir}
  end

  test "rejects schema_version != 1", %{tmp: tmp} do
    ws_dir = Path.join(tmp, "esr-dev")
    File.mkdir_p!(ws_dir)
    path = Path.join(ws_dir, "workspace.json")
    File.write!(path, Jason.encode!(Map.put(@valid, "schema_version", 2)))

    assert {:error, {:bad_schema_version, 2}} = FileLoader.load(path, location: {:esr_bound, ws_dir})
  end

  test "rejects malformed UUID", %{tmp: tmp} do
    ws_dir = Path.join(tmp, "esr-dev")
    File.mkdir_p!(ws_dir)
    path = Path.join(ws_dir, "workspace.json")
    bad = Map.put(@valid, "id", "not-a-uuid")
    File.write!(path, Jason.encode!(bad))

    assert {:error, {:bad_uuid, "not-a-uuid"}} = FileLoader.load(path, location: {:esr_bound, ws_dir})
  end

  test "rejects missing required fields", %{tmp: tmp} do
    ws_dir = Path.join(tmp, "esr-dev")
    File.mkdir_p!(ws_dir)
    path = Path.join(ws_dir, "workspace.json")
    File.write!(path, Jason.encode!(Map.delete(@valid, "owner")))

    assert {:error, {:missing_field, "owner"}} = FileLoader.load(path, location: {:esr_bound, ws_dir})
  end

  test "rejects ESR-bound name != basename(parent)", %{tmp: tmp} do
    sub = Path.join(tmp, "esr-dev")
    File.mkdir_p!(sub)
    path = Path.join(sub, "workspace.json")
    File.write!(path, Jason.encode!(Map.put(@valid, "name", "different")))

    assert {:error, {:name_mismatch, "different", "esr-dev"}} =
             FileLoader.load(path, location: {:esr_bound, sub})
  end

  test "rejects transient: true on repo-bound", %{tmp: tmp} do
    repo_esr = Path.join([tmp, ".esr"])
    File.mkdir_p!(repo_esr)
    path = Path.join(repo_esr, "workspace.json")
    File.write!(path, Jason.encode!(Map.put(@valid, "transient", true)))

    assert {:error, :transient_repo_bound_forbidden} =
             FileLoader.load(path, location: {:repo_bound, tmp})
  end

  test "returns :file_missing if path doesn't exist" do
    assert {:error, :file_missing} =
             FileLoader.load("/nonexistent/workspace.json", location: {:esr_bound, "/nonexistent"})
  end
end
