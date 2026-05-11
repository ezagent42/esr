defmodule Esr.Resource.Workspace.JsonWriterTest do
  use ExUnit.Case, async: true
  alias Esr.Resource.Workspace.{JsonWriter, Struct}

  setup do
    tmp = Path.join(System.tmp_dir!(), "jw_test_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)
    %{tmp: tmp}
  end

  test "writes a workspace.json with the correct shape", %{tmp: tmp} do
    ws = %Struct{
      id: "7b9f3c1a-2d8e-4f1b-9a35-c4e2f8d63b71",
      name: "esr-dev",
      owner: "linyilun",
      folders: [%{path: "/tmp/repo", name: "esr"}],
      settings: %{"cc.model" => "claude-opus-4-7"},
      chats: [%{chat_id: "oc_x", app_id: "cli_y", kind: "dm"}]
    }

    path = Path.join(tmp, "workspace.json")
    assert :ok = JsonWriter.write(path, ws)

    decoded = path |> File.read!() |> Jason.decode!()
    assert decoded["schema_version"] == 1
    assert decoded["id"] == ws.id
    assert decoded["name"] == "esr-dev"
    assert decoded["owner"] == "linyilun"
    assert decoded["folders"] == [%{"path" => "/tmp/repo", "name" => "esr"}]
    assert decoded["chats"] == [%{"chat_id" => "oc_x", "app_id" => "cli_y", "kind" => "dm"}]
  end

  test "atomically writes via *.tmp + rename", %{tmp: tmp} do
    ws = %Struct{
      id: "7b9f3c1a-2d8e-4f1b-9a35-c4e2f8d63b71",
      name: "x",
      owner: "u",
      folders: [%{path: "/tmp/x", name: "x"}]
    }

    path = Path.join(tmp, "workspace.json")

    File.write!(path, "PRE-EXISTING-INVALID-JSON")
    assert :ok = JsonWriter.write(path, ws)

    decoded = path |> File.read!() |> Jason.decode!()
    assert decoded["name"] == "x"
    refute File.exists?(path <> ".tmp")
  end

  test "creates parent dir if missing", %{tmp: tmp} do
    ws = %Struct{
      id: "7b9f3c1a-2d8e-4f1b-9a35-c4e2f8d63b71",
      name: "y",
      owner: "u",
      folders: [%{path: "/tmp/y", name: "y"}]
    }

    path = Path.join([tmp, "deep", "nested", "workspace.json"])

    assert :ok = JsonWriter.write(path, ws)
    assert File.exists?(path)
  end

  describe "write/2 enforces ≥1 folder invariant" do
    test "returns {:error, :empty_folders} when struct has 0 folders" do
      ws = %Esr.Resource.Workspace.Struct{
        id: "wid-empty",
        name: "empty",
        owner: "alice",
        folders: [],
        location: {:esr_bound, "/foo"},
        transient: false,
        agent: "cc",
        settings: %{},
        env: %{},
        chats: []
      }

      path =
        Path.join(System.tmp_dir!(), "test-empty-#{:erlang.unique_integer([:positive])}.json")

      assert {:error, :empty_folders} = Esr.Resource.Workspace.JsonWriter.write(path, ws)
      refute File.exists?(path)
    end
  end

  test "round-trips through FileLoader", %{tmp: tmp} do
    # Place workspace.json in a subdir whose basename matches name
    # (so FileLoader's strict ESR-bound name=basename validation passes).
    sub = Path.join(tmp, "round-trip-ws")
    File.mkdir_p!(sub)

    ws = %Struct{
      id: "7b9f3c1a-2d8e-4f1b-9a35-c4e2f8d63b71",
      name: "round-trip-ws",
      owner: "u",
      folders: [%{path: "/p", name: "n"}],
      env: %{"K" => "V"}
    }

    path = Path.join(sub, "workspace.json")
    :ok = JsonWriter.write(path, ws)

    {:ok, loaded} = Esr.Resource.Workspace.FileLoader.load(path, location: {:esr_bound, sub})
    assert loaded.id == ws.id
    assert loaded.folders == ws.folders
    assert loaded.env == ws.env
  end
end
