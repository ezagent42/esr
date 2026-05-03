defmodule Esr.ApplicationRestoreTest do
  use ExUnit.Case, async: false

  alias Esr.Resource.Workspace.Registry, as: WsReg

  setup do
    prev = System.get_env("ESRD_HOME")
    on_exit(fn ->
      if prev, do: System.put_env("ESRD_HOME", prev), else: System.delete_env("ESRD_HOME")
    end)
    :ok
  end

  test "load_workspaces_from_disk populates the Workspaces.Registry" do
    unique = System.unique_integer([:positive])
    tmp = Path.join(System.tmp_dir!(), "esr-app-test-#{unique}")
    ws_name = "test-ws-#{unique}"

    File.mkdir_p!(Path.join(tmp, "default"))
    path = Path.join([tmp, "default", "workspaces.yaml"])

    File.write!(path, """
    schema_version: 1
    workspaces:
      #{ws_name}:
        cwd: /tmp
        start_cmd: x
        role: dev
        chats:
          - {chat_id: oc, app_id: cli, kind: dm}
    """)

    System.put_env("ESRD_HOME", tmp)
    :ok = Esr.Application.load_workspaces_from_disk(tmp)

    assert {:ok, %WsReg.Workspace{name: ^ws_name, role: "dev"}} = WsReg.get(ws_name)

    File.rm_rf!(tmp)
  end

  test "load_workspaces_from_disk is a no-op when workspaces.yaml is missing" do
    tmp = Path.join(System.tmp_dir!(), "esr-app-test-empty-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)

    System.put_env("ESRD_HOME", tmp)
    assert :ok = Esr.Application.load_workspaces_from_disk(tmp)

    File.rm_rf!(tmp)
  end
end
