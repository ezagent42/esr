defmodule Esr.Resource.ChatScope.RegistryTest do
  use ExUnit.Case, async: false

  alias Esr.Resource.ChatScope.Registry

  setup do
    assert is_pid(Process.whereis(Registry))
    :ok
  end

  describe "default workspace" do
    # Test 1: set_default_workspace/3 + get_default_workspace/2 round-trip
    test "set_default_workspace/3 then get_default_workspace/2 returns {:ok, uuid}" do
      uuid = "cccccccc-0001-4000-8000-000000000001"

      assert :ok = Registry.set_default_workspace("oc_reg1", "cli_reg1", uuid)
      assert {:ok, ^uuid} = Registry.get_default_workspace("oc_reg1", "cli_reg1")
    end

    # Test 2: unset chat → :not_found
    test "get_default_workspace/2 for an unset chat returns :not_found" do
      assert :not_found = Registry.get_default_workspace("oc_unset", "cli_unset")
    end

    # Test 3: clear_default_workspace/2 removes mapping; idempotent double-clear
    test "clear_default_workspace/2 removes mapping; calling twice does not crash" do
      uuid = "cccccccc-0003-4000-8000-000000000003"

      :ok = Registry.set_default_workspace("oc_reg3", "cli_reg3", uuid)
      assert {:ok, ^uuid} = Registry.get_default_workspace("oc_reg3", "cli_reg3")

      assert :ok = Registry.clear_default_workspace("oc_reg3", "cli_reg3")
      assert :not_found = Registry.get_default_workspace("oc_reg3", "cli_reg3")

      # Idempotent — second clear must not crash
      assert :ok = Registry.clear_default_workspace("oc_reg3", "cli_reg3")
      assert :not_found = Registry.get_default_workspace("oc_reg3", "cli_reg3")
    end
  end

  # Phase 2.1 — multi-session attach/detach API

  describe "attach_session/3" do
    test "attaches a session and sets it as current" do
      chat_id = "oc_attach_test"
      app_id = "cli_app"
      uuid = "a1b2c3d4-e5f6-4a7b-8c9d-e0f1a2b3c4d5"

      assert :ok = Registry.attach_session(chat_id, app_id, uuid)
      assert {:ok, ^uuid} = Registry.current_session(chat_id, app_id)
      assert [^uuid] = Registry.attached_sessions(chat_id, app_id)
    end

    test "attaching a second session adds it but keeps first as current" do
      chat_id = "oc_multi_test"
      app_id = "cli_app"
      uuid1 = "a1b2c3d4-e5f6-4a7b-8c9d-e0f1a2b3c4d5"
      uuid2 = "b2c3d4e5-f6a7-4b8c-9d0e-f1a2b3c4d5e6"

      Registry.attach_session(chat_id, app_id, uuid1)
      Registry.attach_session(chat_id, app_id, uuid2)

      sessions = Registry.attached_sessions(chat_id, app_id) |> Enum.sort()
      assert Enum.sort([uuid1, uuid2]) == sessions
    end

    test "re-attaching already-attached session is idempotent" do
      chat_id = "oc_idem_test"
      app_id = "cli_app"
      uuid = "c3d4e5f6-a7b8-4c9d-0e1f-a2b3c4d5e6f7"

      Registry.attach_session(chat_id, app_id, uuid)
      Registry.attach_session(chat_id, app_id, uuid)

      assert [^uuid] = Registry.attached_sessions(chat_id, app_id)
    end
  end

  describe "detach_session/3" do
    test "detach removes session from attached set" do
      chat_id = "oc_detach1"
      app_id = "cli_app"
      uuid1 = "d4e5f6a7-b8c9-4d0e-1f2a-b3c4d5e6f7a8"
      uuid2 = "e5f6a7b8-c9d0-4e1f-2a3b-c4d5e6f7a8b9"

      Registry.attach_session(chat_id, app_id, uuid1)
      Registry.attach_session(chat_id, app_id, uuid2)

      assert :ok = Registry.detach_session(chat_id, app_id, uuid1)
      assert Registry.attached_sessions(chat_id, app_id) == [uuid2]
    end

    test "detaching current session promotes next as current" do
      chat_id = "oc_detach2"
      app_id = "cli_app"
      uuid1 = "f6a7b8c9-d0e1-4f2a-3b4c-d5e6f7a8b9c0"
      uuid2 = "a7b8c9d0-e1f2-4a3b-4c5d-e6f7a8b9c0d1"

      Registry.attach_session(chat_id, app_id, uuid1)
      Registry.attach_session(chat_id, app_id, uuid2)
      # uuid1 is current (first attached)
      assert {:ok, ^uuid1} = Registry.current_session(chat_id, app_id)

      Registry.detach_session(chat_id, app_id, uuid1)

      # uuid2 becomes current
      assert {:ok, _remaining} = Registry.current_session(chat_id, app_id)
      assert Registry.attached_sessions(chat_id, app_id) == [uuid2]
    end

    test "detaching last session leaves current as nil" do
      chat_id = "oc_detach3"
      app_id = "cli_app"
      uuid = "b8c9d0e1-f2a3-4b4c-5d6e-f7a8b9c0d1e2"

      Registry.attach_session(chat_id, app_id, uuid)
      Registry.detach_session(chat_id, app_id, uuid)

      assert :not_found = Registry.current_session(chat_id, app_id)
      assert [] = Registry.attached_sessions(chat_id, app_id)
    end
  end

  # Phase 2.2 — lookup_by_chat/2 shim (backward compat)

  describe "lookup_by_chat/2 shim (backward compat)" do
    test "returns current session in old {sid, refs} form after attach" do
      chat_id = "oc_shim_test"
      app_id = "cli_app"
      uuid = "c9d0e1f2-a3b4-4c5d-6e7f-a8b9c0d1e2f3"

      Registry.attach_session(chat_id, app_id, uuid)

      assert {:ok, ^uuid, _refs} = Registry.lookup_by_chat(chat_id, app_id)
    end

    test "returns :not_found when no session is attached" do
      assert :not_found = Registry.lookup_by_chat("oc_empty", "cli_app")
    end
  end

  # Phase 2.4 — persistence across restart

  describe "persistence across restart" do
    setup do
      tmp = Path.join(System.tmp_dir!(), "cs_persist_#{:rand.uniform(1_000_000)}")
      File.mkdir_p!(tmp)
      System.put_env("ESRD_HOME", tmp)
      System.put_env("ESR_INSTANCE", "default")
      File.mkdir_p!(Path.join([tmp, "default"]))

      on_exit(fn ->
        System.delete_env("ESRD_HOME")
        System.delete_env("ESR_INSTANCE")
        File.rm_rf!(tmp)
      end)

      %{tmp: tmp}
    end

    test "attached set is written to disk on attach", %{tmp: tmp} do
      unless Process.whereis(Registry), do: Registry.start_link([])
      Registry.reload()

      uuid = "f0e1d2c3-b4a5-4967-8b12-a3b4c5d6e7f8"
      Registry.attach_session("oc_persist", "cli_p", uuid)

      persist_path = Path.join([tmp, "default", "chat_attached.yaml"])
      assert File.exists?(persist_path)
    end

    test "boot loads persisted attached set", %{tmp: tmp} do
      unless Process.whereis(Registry), do: Registry.start_link([])

      uuid = "a0b1c2d3-e4f5-4678-9a0b-c1d2e3f4a5b6"
      persist_path = Path.join([tmp, "default", "chat_attached.yaml"])

      # Pre-write a fixture
      File.write!(persist_path, """
      chat_attached:
        - chat_id: "oc_boot"
          app_id: "cli_b"
          sessions:
            - "#{uuid}"
          current: "#{uuid}"
      """)

      Registry.reload()

      assert {:ok, ^uuid} = Registry.current_session("oc_boot", "cli_b")
    end
  end
end
