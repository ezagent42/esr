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
  end

  test "load_from_file/1 missing file returns empty map" do
    {:ok, %{}} = Registry.load_from_file("/nonexistent/path")
  end
end
