defmodule Esr.Resource.Session.RegistryTest do
  use ExUnit.Case, async: false
  alias Esr.Resource.Session.{Registry, Struct}

  @uuid "a1b2c3d4-e5f6-4a7b-8c9d-e0f1a2b3c4d5"
  @owner_uuid "b2c3d4e5-f6a7-4b8c-9d0e-f1a2b3c4d5e6"
  @ws_uuid "c3d4e5f6-a7b8-4c9d-0e1f-a2b3c4d5e6f7"

  setup do
    tmp = Path.join(System.tmp_dir!(), "sreg_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(tmp)
    System.put_env("ESRD_HOME", tmp)
    System.put_env("ESR_INSTANCE", "default")
    File.mkdir_p!(Path.join([tmp, "default", "sessions"]))

    on_exit(fn ->
      System.delete_env("ESRD_HOME")
      System.delete_env("ESR_INSTANCE")
      File.rm_rf!(tmp)
    end)

    unless Process.whereis(Registry), do: Registry.start_link([])
    Registry.reload()
    %{tmp: tmp}
  end

  defp write_session(tmp, uuid, name, owner_uuid) do
    dir = Path.join([tmp, "default", "sessions", uuid])
    File.mkdir_p!(dir)
    data = %{
      "schema_version" => 1,
      "id" => uuid,
      "name" => name,
      "owner_user" => owner_uuid,
      "workspace_id" => @ws_uuid,
      "agents" => [],
      "primary_agent" => nil,
      "attached_chats" => [],
      "created_at" => "2026-05-07T12:00:00Z",
      "transient" => false
    }
    File.write!(Path.join(dir, "session.json"), Jason.encode!(data))
    dir
  end

  test "starts empty", _ctx do
    assert Registry.list_all() == []
  end

  test "get_by_id returns :not_found for unknown", _ctx do
    assert :not_found = Registry.get_by_id("00000000-0000-4000-8000-000000000000")
  end

  test "reload discovers sessions on disk", %{tmp: tmp} do
    write_session(tmp, @uuid, "esr-dev", @owner_uuid)
    Registry.reload()
    assert {:ok, %Struct{id: @uuid, name: "esr-dev"}} = Registry.get_by_id(@uuid)
  end

  test "list_all returns all loaded sessions", %{tmp: tmp} do
    uuid2 = "b2c3d4e5-f6a7-4b8c-9d0e-f1a2b3c4d5e6"
    write_session(tmp, @uuid, "esr-dev", @owner_uuid)
    write_session(tmp, uuid2, "docs", @owner_uuid)
    Registry.reload()
    ids = Registry.list_all() |> Enum.map(& &1.id) |> Enum.sort()
    assert ids == Enum.sort([@uuid, uuid2])
  end

  test "get_by_id returns correct struct after reload", %{tmp: tmp} do
    write_session(tmp, @uuid, "my-session", @owner_uuid)
    Registry.reload()
    assert {:ok, sess} = Registry.get_by_id(@uuid)
    assert sess.name == "my-session"
    assert sess.owner_user == @owner_uuid
  end

  describe "add_agent_to_session/5 + persistence" do
    setup do
      # Ensure InstanceRegistry is running.
      case Process.whereis(Esr.Entity.Agent.InstanceRegistry) do
        nil -> start_supervised!(Esr.Entity.Agent.InstanceRegistry)
        _ -> :ok
      end

      :ok
    end

    test "create_session writes session.json on disk", %{tmp: tmp} do
      data_dir = Path.join([tmp, "default"])

      {:ok, session_id} =
        Registry.create_session(data_dir, %{
          name: "my-sess",
          owner_user: @owner_uuid,
          workspace_id: @ws_uuid
        })

      session_json_path = Path.join([data_dir, "sessions", session_id, "session.json"])
      assert File.exists?(session_json_path)
      {:ok, doc} = Jason.decode(File.read!(session_json_path))
      assert doc["id"] == session_id
      assert doc["name"] == "my-sess"
    end

    test "add_agent persists to session.json and updates ETS", %{tmp: tmp} do
      data_dir = Path.join([tmp, "default"])

      {:ok, session_id} =
        Registry.create_session(data_dir, %{
          name: "agent-sess",
          owner_user: @owner_uuid,
          workspace_id: @ws_uuid
        })

      :ok = Registry.add_agent_to_session(data_dir, session_id, "cc", "dev", %{})

      # Verify persisted JSON contains the agent.
      session_json_path = Path.join([data_dir, "sessions", session_id, "session.json"])
      persisted = File.read!(session_json_path) |> Jason.decode!()
      assert [%{"type" => "cc", "name" => "dev"}] = persisted["agents"]
      assert persisted["primary_agent"] == "dev"

      # Verify ETS is also updated.
      {:ok, sess} = Registry.get_session(session_id)
      assert [%{type: "cc", name: "dev"}] = sess.agents
      assert sess.primary_agent == "dev"
    end

    test "add_agent returns error on duplicate name in same session", %{tmp: tmp} do
      data_dir = Path.join([tmp, "default"])

      {:ok, session_id} =
        Registry.create_session(data_dir, %{
          name: "dup-sess",
          owner_user: @owner_uuid,
          workspace_id: @ws_uuid
        })

      :ok = Registry.add_agent_to_session(data_dir, session_id, "cc", "dev", %{})

      assert {:error, {:duplicate_agent_name, "dev"}} =
               Registry.add_agent_to_session(data_dir, session_id, "codex", "dev", %{})
    end
  end
end
