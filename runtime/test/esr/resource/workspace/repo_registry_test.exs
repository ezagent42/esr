defmodule Esr.Resource.Workspace.RepoRegistryTest do
  use ExUnit.Case, async: true
  alias Esr.Resource.Workspace.RepoRegistry

  setup do
    tmp = Path.join(System.tmp_dir!(), "rr_test_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(tmp)
    yaml = Path.join(tmp, "registered_repos.yaml")
    on_exit(fn -> File.rm_rf!(tmp) end)
    %{yaml: yaml}
  end

  test "load empty when file missing", %{yaml: yaml} do
    assert {:ok, []} = RepoRegistry.load(yaml)
  end

  test "load valid yaml", %{yaml: yaml} do
    File.write!(yaml, """
    schema_version: 1
    repos:
      - path: /Users/h2oslabs/Workspace/esr
      - path: /Users/h2oslabs/Workspace/cc-openclaw
        name: cc-openclaw
    """)

    assert {:ok, [r1, r2]} = RepoRegistry.load(yaml)
    assert r1.path == "/Users/h2oslabs/Workspace/esr"
    assert r1.name == nil
    assert r2.path == "/Users/h2oslabs/Workspace/cc-openclaw"
    assert r2.name == "cc-openclaw"
  end

  test "register/unregister round-trip", %{yaml: yaml} do
    :ok = RepoRegistry.register(yaml, "/repo/a")
    :ok = RepoRegistry.register(yaml, "/repo/b", name: "bee")

    {:ok, repos} = RepoRegistry.load(yaml)
    assert Enum.map(repos, & &1.path) == ["/repo/a", "/repo/b"]
    assert Enum.find(repos, &(&1.path == "/repo/b")).name == "bee"

    :ok = RepoRegistry.unregister(yaml, "/repo/a")
    {:ok, repos} = RepoRegistry.load(yaml)
    assert Enum.map(repos, & &1.path) == ["/repo/b"]
  end

  test "register is idempotent (no duplicates)", %{yaml: yaml} do
    :ok = RepoRegistry.register(yaml, "/repo/x")
    :ok = RepoRegistry.register(yaml, "/repo/x")
    {:ok, repos} = RepoRegistry.load(yaml)
    assert length(repos) == 1
  end

  test "unregister non-existent path is ok", %{yaml: yaml} do
    assert :ok = RepoRegistry.unregister(yaml, "/never/registered")
  end
end
