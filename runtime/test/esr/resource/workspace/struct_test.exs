defmodule Esr.Resource.Workspace.StructTest do
  use ExUnit.Case, async: true

  describe "valid?/1" do
    test "true when folders has ≥1 entry" do
      ws = %Esr.Resource.Workspace.Struct{
        id: "wid-1",
        name: "demo",
        owner: "alice",
        folders: [%{path: "/tmp/x", name: "x"}],
        location: {:repo_bound, "/tmp/x"},
        transient: false,
        agent: "cc",
        settings: %{},
        env: %{},
        chats: []
      }

      assert Esr.Resource.Workspace.Struct.valid?(ws) == true
    end

    test "false when folders is empty list" do
      ws = %Esr.Resource.Workspace.Struct{
        id: "wid-2",
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

      assert Esr.Resource.Workspace.Struct.valid?(ws) == false
    end

    test "false when folders is not a list" do
      ws = %Esr.Resource.Workspace.Struct{
        id: "wid-3",
        name: "bad",
        owner: "alice",
        folders: nil,
        location: {:esr_bound, "/foo"},
        transient: false,
        agent: "cc",
        settings: %{},
        env: %{},
        chats: []
      }

      assert Esr.Resource.Workspace.Struct.valid?(ws) == false
    end
  end
end
