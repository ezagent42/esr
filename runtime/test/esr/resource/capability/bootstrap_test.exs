defmodule Esr.Resource.Capability.BootstrapTest do
  @moduledoc """
  Capabilities spec §9.1 — first-run seed-file bootstrap.

  Covers the `Esr.Resource.Capability.Supervisor.init/1` branch that writes
  a seed `capabilities.yaml` granting the admin wildcard to the
  principal named by `ESR_BOOTSTRAP_PRINCIPAL_ID` when no file exists.
  Rationale: without this, Lane A (CAP-5) would default-deny every
  user on a fresh install.
  """
  use ExUnit.Case, async: false

  alias Esr.Resource.Capability.Supervisor, as: CapSupervisor
  alias Esr.Resource.Permission.Registry

  @env_var "ESR_BOOTSTRAP_PRINCIPAL_ID"

  setup do
    # Capture + restore the env var so tests stay hermetic even when the
    # developer runs with ESR_BOOTSTRAP_PRINCIPAL_ID set in their shell.
    prior = System.get_env(@env_var)
    on_exit(fn ->
      case prior do
        nil -> System.delete_env(@env_var)
        value -> System.put_env(@env_var, value)
      end
    end)

    # Each case owns a fresh tmp dir so file-creation assertions are
    # deterministic across parallel runs.
    tmp = Path.join(System.tmp_dir!(), "cap_bootstrap_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    path = Path.join(tmp, "capabilities.yaml")
    on_exit(fn -> File.rm_rf!(tmp) end)

    # The app-level CapSupervisor in the parent process already holds
    # the Permissions.Registry name; tests that start_supervised! their
    # own CapSupervisor would collide. Use the Supervisor module's
    # one-shot function-under-test seam by calling the env-gated helper
    # via the public init contract (see below).
    {:ok, tmp: tmp, path: path}
  end

  test "bootstrap writes seed file when env var set and no file exists",
       %{path: path} do
    System.put_env(@env_var, "ou_bootstrap_x")

    refute File.exists?(path)

    # The supervisor's init/1 runs the bootstrap as a side effect before
    # returning its child-spec list. We can't start_supervised!/1 a
    # second Capabilities.Supervisor (name collision with the app-level
    # singleton), so invoke the code path via the public init/1 — which
    # does the file write — using `Supervisor.init/2`'s guarantees.
    {:ok, _spec} = CapSupervisor.init(path: path)

    assert File.exists?(path)
    content = File.read!(path)
    assert content =~ "ou_bootstrap_x"
    assert content =~ ~s(capabilities: ["*"])
    assert content =~ "bootstrap admin"
  end

  test "bootstrap is a no-op when env var is unset", %{path: path} do
    System.delete_env(@env_var)

    refute File.exists?(path)
    {:ok, _spec} = CapSupervisor.init(path: path)
    refute File.exists?(path)
  end

  test "bootstrap is a no-op when file already exists", %{path: path} do
    System.put_env(@env_var, "ou_would_overwrite")

    File.write!(path, """
    principals:
      - id: ou_existing
        capabilities: ["*"]
    """)

    # Touch mtime to a known-old value so we can detect any spurious
    # rewrite even if the content happens to hash the same.
    old_mtime = {{2020, 1, 1}, {0, 0, 0}}
    File.touch!(path, old_mtime)

    {:ok, _spec} = CapSupervisor.init(path: path)

    # File still holds the user's content, not the bootstrap seed.
    content = File.read!(path)
    assert content =~ "ou_existing"
    refute content =~ "ou_would_overwrite"

    # Access mtime can shift on read; inode check is the invariant we care
    # about — the file was not rewritten.
    stat = File.stat!(path)
    assert stat.mtime == old_mtime
  end

  test "bootstrap is a no-op when env var is empty string", %{path: path} do
    # Treat empty string as 'not set' — avoids creating a file principled
    # under an unusable id if someone does `export VAR=`.
    System.put_env(@env_var, "")
    refute File.exists?(path)
    {:ok, _spec} = CapSupervisor.init(path: path)
    refute File.exists?(path)
  end

  test "bootstrap creates parent directories as needed", %{tmp: tmp} do
    # Nested path not yet existing — supervisor must mkdir_p before write.
    nested = Path.join([tmp, "nest", "deeper", "capabilities.yaml"])
    refute File.exists?(Path.dirname(nested))

    System.put_env(@env_var, "ou_nested_principal")
    {:ok, _spec} = CapSupervisor.init(path: nested)

    assert File.exists?(nested)
    assert File.read!(nested) =~ "ou_nested_principal"
  end

  test "seed file parses cleanly through FileLoader", %{path: path} do
    # Integration check — the bootstrap seed must be valid YAML that
    # FileLoader can ingest without warnings about missing permissions
    # (the "*" wildcard bypasses permission validation).
    System.put_env(@env_var, "ou_integration")
    {:ok, _spec} = CapSupervisor.init(path: path)

    # Permissions.Registry is already up at the app level; any declared
    # subset is fine because the seed uses "*".
    if Process.whereis(Registry) == nil, do: start_supervised!(Registry)

    assert :ok = Esr.Resource.Capability.FileLoader.load(path)
    assert Esr.Resource.Capability.Grants.has?("ou_integration", "workspace:proj-z/msg.send")
  end
end
