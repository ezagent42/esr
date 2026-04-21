defmodule Esr.Capabilities.WatcherTest do
  use ExUnit.Case, async: false

  alias Esr.Capabilities.{Watcher, Grants}
  alias Esr.Permissions.Registry

  setup do
    if Process.whereis(Registry) == nil, do: start_supervised!(Registry)
    if Process.whereis(Grants) == nil, do: start_supervised!(Grants)

    # The app-level Esr.Capabilities.Supervisor already runs a Watcher under
    # the same name; terminate + delete the child so this test can start its
    # own. Restore it via on_exit so later tests (in other suites) still see
    # the production watcher.
    sup = Esr.Capabilities.Supervisor

    if Process.whereis(Watcher) do
      _ = Supervisor.terminate_child(sup, Esr.Capabilities.Watcher)
      _ = Supervisor.delete_child(sup, Esr.Capabilities.Watcher)
    end

    on_exit(fn ->
      # Best-effort re-add the production watcher pointing at the default
      # path. Ignore errors if it can't restart (no capabilities.yaml yet).
      prod_path =
        (System.get_env("ESRD_HOME") || Path.expand("~/.esrd"))
        |> Path.join("default/capabilities.yaml")

      _ =
        Supervisor.start_child(sup, %{
          id: Esr.Capabilities.Watcher,
          start: {Esr.Capabilities.Watcher, :start_link, [[path: prod_path]]}
        })
    end)

    # Reset Registry + Grants state for deterministic test starts.
    Registry.reset()
    Grants.load_snapshot(%{})
    Registry.register("msg.send", declared_by: Test)

    tmp = Path.join(System.tmp_dir!(), "cap_watch_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    file = Path.join(tmp, "capabilities.yaml")

    File.write!(file, """
    principals:
      - id: ou_a
        capabilities: ["workspace:x/msg.send"]
    """)

    on_exit(fn -> File.rm_rf!(tmp) end)
    {:ok, cap_file: file, dir: tmp}
  end

  test "initial load on start", %{cap_file: file} do
    start_supervised!({Watcher, path: file})
    assert Grants.has?("ou_a", "workspace:x/msg.send")
  end

  test "reload on file change", %{cap_file: file} do
    start_supervised!({Watcher, path: file})
    refute Grants.has?("ou_b", "workspace:x/msg.send")

    # Give mac_listener / inotify backend a moment to fully arm the watch
    # before we write. Without this the first write can precede the kernel
    # subscription under heavy concurrent test load (flake observed ~3/8).
    Process.sleep(300)

    File.write!(file, """
    principals:
      - id: ou_b
        capabilities: ["workspace:x/msg.send"]
    """)

    # fs_system debounce + our handler: poll up to ~10s to ride out
    # mac FSEvents latency jitter under full-suite load.
    assert eventually(fn -> Grants.has?("ou_b", "workspace:x/msg.send") end, 10_000)

    assert Grants.has?("ou_b", "workspace:x/msg.send")
    refute Grants.has?("ou_a", "workspace:x/msg.send")
  end

  # Polls a predicate at 50ms granularity until it returns truthy or the
  # budget runs out. Returns true iff the predicate eventually becomes truthy.
  defp eventually(_fun, remaining_ms) when remaining_ms <= 0, do: false

  defp eventually(fun, remaining_ms) do
    if fun.() do
      true
    else
      Process.sleep(50)
      eventually(fun, remaining_ms - 50)
    end
  end
end
