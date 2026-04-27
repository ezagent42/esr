defmodule Esr.Workspaces.RegistryTest do
  use ExUnit.Case, async: false

  alias Esr.Workspaces.Registry

  setup do
    tmp = Path.join(System.tmp_dir!(), "esr-ws-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    path = Path.join(tmp, "workspaces.yaml")
    on_exit(fn -> File.rm_rf!(tmp) end)
    %{path: path}
  end

  test "load_from_file/1 parses schema_version 1", %{path: path} do
    File.write!(path, """
    schema_version: 1
    workspaces:
      esr-dev:
        cwd: /tmp/x
        start_cmd: scripts/esr-cc.sh
        role: dev
        chats:
          - {chat_id: oc_x, app_id: cli_x, kind: dm}
    """)

    {:ok, workspaces} = Registry.load_from_file(path)
    assert Map.has_key?(workspaces, "esr-dev")
    ws = workspaces["esr-dev"]
    assert ws.cwd == "/tmp/x"
    assert ws.role == "dev"
    assert [%{"chat_id" => "oc_x"}] = ws.chats
    # PR-C: workspaces without `neighbors` parse with an empty list.
    assert ws.neighbors == []
  end

  test "load_from_file/1 missing file returns empty map" do
    {:ok, %{}} = Registry.load_from_file("/nonexistent/path")
  end

  test "load_from_file/1 parses metadata sub-tree (PR-F)", %{path: path} do
    File.write!(path, """
    workspaces:
      ws_translator:
        cwd: /tmp/translator
        chats:
          - {chat_id: oc_t, app_id: cli_t, kind: dm, name: translator-room}
        neighbors:
          - workspace:ws_processor
        metadata:
          purpose: "Translate Chinese to English"
          pipeline_position: 1
          hand_off_to: "ws_processor"
    """)

    {:ok, workspaces} = Registry.load_from_file(path)
    ws = workspaces["ws_translator"]
    assert ws.metadata == %{
             "purpose" => "Translate Chinese to English",
             "pipeline_position" => 1,
             "hand_off_to" => "ws_processor"
           }
  end

  test "load_from_file/1 defaults metadata to empty map when absent (PR-F)", %{path: path} do
    File.write!(path, """
    workspaces:
      ws_minimal:
        chats:
          - {chat_id: oc_x, app_id: cli_x, kind: dm}
    """)

    {:ok, workspaces} = Registry.load_from_file(path)
    assert workspaces["ws_minimal"].metadata == %{}
  end

  test "load_from_file/1 parses neighbors list (PR-C)", %{path: path} do
    File.write!(path, """
    schema_version: 1
    workspaces:
      ws_dev:
        cwd: /tmp/dev
        chats:
          - {chat_id: oc_dev, app_id: cli_dev, kind: group, name: dev-room}
          - {chat_id: oc_dev_dm, app_id: cli_dev, kind: dm}
        neighbors:
          - workspace:ws_kanban
          - chat:oc_legal_special
          - user:ou_admin
      ws_kanban:
        cwd: /tmp/kanban
        chats:
          - {chat_id: oc_kanban, app_id: cli_kanban, kind: group}
    """)

    {:ok, workspaces} = Registry.load_from_file(path)
    ws_dev = workspaces["ws_dev"]
    assert ws_dev.neighbors == [
             "workspace:ws_kanban",
             "chat:oc_legal_special",
             "user:ou_admin"
           ]
    # Optional `name` field on chats survives the parse.
    [%{"name" => "dev-room"} = first | _] = ws_dev.chats
    assert first["chat_id"] == "oc_dev"
    # ws_kanban omits neighbors → defaults to [].
    assert workspaces["ws_kanban"].neighbors == []
  end

  describe "workspace_for_chat/2 (PR-9 T11b.1)" do
    setup do
      # The test uses the app-level Registry (ETS) because workspace_for_chat/2
      # reads the table directly. Clean any leftovers + insert fresh rows.
      for name <- ["ws_alpha", "ws_beta", "ws_empty"] do
        :ets.delete(:esr_workspaces, name)
      end

      assert is_pid(Process.whereis(Registry))

      on_exit(fn ->
        for name <- ["ws_alpha", "ws_beta", "ws_empty"] do
          :ets.delete(:esr_workspaces, name)
        end
      end)

      :ok
    end

    test "returns {:ok, name} when an exact (chat_id, app_id) pair matches" do
      :ok =
        Registry.put(%Registry.Workspace{
          name: "ws_alpha",
          cwd: "/tmp",
          start_cmd: "",
          role: "dev",
          chats: [
            %{"chat_id" => "oc_a", "app_id" => "cli_x", "kind" => "dm"},
            %{"chat_id" => "oc_b", "app_id" => "cli_x", "kind" => "group"}
          ],
          env: %{}
        })

      assert Registry.workspace_for_chat("oc_a", "cli_x") == {:ok, "ws_alpha"}
      assert Registry.workspace_for_chat("oc_b", "cli_x") == {:ok, "ws_alpha"}
    end

    test "mismatched app_id returns :not_found even when chat_id matches" do
      :ok =
        Registry.put(%Registry.Workspace{
          name: "ws_alpha",
          cwd: "/tmp",
          start_cmd: "",
          role: "dev",
          chats: [%{"chat_id" => "oc_a", "app_id" => "cli_x", "kind" => "dm"}],
          env: %{}
        })

      assert Registry.workspace_for_chat("oc_a", "cli_other") == :not_found
    end

    test "scans across workspaces (first match wins) + no-match returns :not_found" do
      :ok =
        Registry.put(%Registry.Workspace{
          name: "ws_alpha",
          cwd: "/tmp",
          start_cmd: "",
          role: "dev",
          chats: [%{"chat_id" => "oc_a", "app_id" => "cli_x", "kind" => "dm"}],
          env: %{}
        })

      :ok =
        Registry.put(%Registry.Workspace{
          name: "ws_beta",
          cwd: "/tmp",
          start_cmd: "",
          role: "dev",
          chats: [%{"chat_id" => "oc_c", "app_id" => "cli_y", "kind" => "group"}],
          env: %{}
        })

      :ok =
        Registry.put(%Registry.Workspace{
          name: "ws_empty",
          cwd: "/tmp",
          start_cmd: "",
          role: "dev",
          chats: [],
          env: %{}
        })

      assert Registry.workspace_for_chat("oc_c", "cli_y") == {:ok, "ws_beta"}
      assert Registry.workspace_for_chat("oc_missing", "cli_x") == :not_found
    end
  end
end
