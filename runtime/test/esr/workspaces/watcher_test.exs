defmodule Esr.Workspaces.WatcherTest do
  @moduledoc """
  Spec 2026-04-27 actor-topology-routing §7 hot-reload — eager-add /
  lazy-remove via PubSub broadcast.

  These tests don't depend on a real fs_watch event — they exercise
  the reload + diff + broadcast pipeline directly via the watcher's
  GenServer message handlers. fs_watch behaviour itself is covered by
  capabilities/watcher_test.exs (same library, same wiring).
  """
  use ExUnit.Case, async: false

  alias Esr.Workspaces.Registry, as: WS
  alias Esr.Workspaces.Watcher

  setup do
    # Clear ETS between tests; the registry GenServer is app-level.
    for {name, _} <- :ets.tab2list(:esr_workspaces), do: :ets.delete(:esr_workspaces, name)

    on_exit(fn ->
      for {name, _} <- :ets.tab2list(:esr_workspaces), do: :ets.delete(:esr_workspaces, name)
    end)

    tmp = Path.join(System.tmp_dir!(), "esr-watcher-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    path = Path.join(tmp, "workspaces.yaml")
    on_exit(fn -> File.rm_rf!(tmp) end)

    %{tmp: tmp, path: path}
  end

  test "init/1 loads the file when present", %{path: path} do
    File.write!(path, """
    workspaces:
      ws_init:
        cwd: /tmp/x
        chats:
          - {chat_id: oc_init, app_id: cli_init, kind: group}
    """)

    {:ok, _pid} =
      Watcher.start_link(path: path, name: :"watcher_test_init_#{System.unique_integer([:positive])}")

    assert {:ok, ws} = WS.get("ws_init")
    assert ws.name == "ws_init"
  end

  test "init/1 with missing file logs warning and stays alive", %{tmp: tmp} do
    missing = Path.join(tmp, "no_such_file.yaml")

    {:ok, pid} =
      Watcher.start_link(
        path: missing,
        name: :"watcher_test_missing_#{System.unique_integer([:positive])}"
      )

    assert Process.alive?(pid)
  end

  test "fs_watch event triggers reload + neighbour-added broadcast",
       %{path: path} do
    # Initial yaml: ws_a alone, no neighbours.
    File.write!(path, """
    workspaces:
      ws_a:
        cwd: /tmp/a
        chats:
          - {chat_id: oc_a, app_id: cli_a, kind: group}
    """)

    {:ok, pid} =
      Watcher.start_link(
        path: path,
        name: :"watcher_test_event_#{System.unique_integer([:positive])}"
      )

    # Subscribe to ws_a's per-workspace topology topic before the
    # reload so the broadcast finds us.
    :ok = Phoenix.PubSub.subscribe(EsrWeb.PubSub, "topology:ws_a")

    # Live-edit yaml: add ws_b + declare it as ws_a's neighbour.
    File.write!(path, """
    workspaces:
      ws_a:
        cwd: /tmp/a
        chats:
          - {chat_id: oc_a, app_id: cli_a, kind: group}
        neighbors:
          - workspace:ws_b
      ws_b:
        cwd: /tmp/b
        chats:
          - {chat_id: oc_b, app_id: cli_b, kind: group}
    """)

    # Drive the watcher synchronously by sending a synthetic fs event.
    send(pid, {:file_event, self(), {path, [:modified]}})

    # Expect the eager-add broadcast carrying ws_b's chat URI.
    expected_uri = "esr://localhost/workspaces/ws_b/chats/oc_b"
    assert_receive {:topology_neighbour_added, "ws_a", ^expected_uri}, 1000
  end

  test "removed neighbour does NOT broadcast (lazy-remove per spec §7)",
       %{path: path} do
    File.write!(path, """
    workspaces:
      ws_a:
        cwd: /tmp/a
        chats:
          - {chat_id: oc_a, app_id: cli_a, kind: group}
        neighbors:
          - workspace:ws_b
      ws_b:
        cwd: /tmp/b
        chats:
          - {chat_id: oc_b, app_id: cli_b, kind: group}
    """)

    {:ok, pid} =
      Watcher.start_link(
        path: path,
        name: :"watcher_test_lazy_#{System.unique_integer([:positive])}"
      )

    # Subscribe AFTER initial load so the initial broadcast didn't go to us.
    :ok = Phoenix.PubSub.subscribe(EsrWeb.PubSub, "topology:ws_a")

    File.write!(path, """
    workspaces:
      ws_a:
        cwd: /tmp/a
        chats:
          - {chat_id: oc_a, app_id: cli_a, kind: group}
        neighbors: []
      ws_b:
        cwd: /tmp/b
        chats:
          - {chat_id: oc_b, app_id: cli_b, kind: group}
    """)

    send(pid, {:file_event, self(), {path, [:modified]}})

    # Removal should NOT produce a broadcast (lazy-remove).
    refute_receive {:topology_neighbour_added, _, _}, 200
  end
end
