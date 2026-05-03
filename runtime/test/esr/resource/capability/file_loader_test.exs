defmodule Esr.Resource.Capability.FileLoaderTest do
  use ExUnit.Case, async: false

  alias Esr.Resource.Capability.{FileLoader, Grants}
  alias Esr.Resource.Permission.Registry

  @fixtures "test/support/capabilities_fixtures"

  setup do
    if Process.whereis(Registry) == nil, do: start_supervised!(Registry)
    if Process.whereis(Grants) == nil, do: start_supervised!(Grants)

    # Reset state between tests — the app-level processes are long-lived.
    Registry.reset()
    Grants.load_snapshot(%{})

    # Registry must declare the permissions used in fixtures
    Registry.register("msg.send", declared_by: Test)
    Registry.register("session.create", declared_by: Test)
    Registry.register("session:default/create", declared_by: Test)
    Registry.register("session:default/end", declared_by: Test)
    :ok
  end

  test "load valid file" do
    assert :ok = FileLoader.load(Path.join(@fixtures, "valid.yaml"))
    assert Grants.has?("ou_admin", "workspace:any/any.perm")
    assert Grants.has?("ou_alice", "workspace:proj-a/msg.send")
    refute Grants.has?("ou_alice", "workspace:proj-b/msg.send")
  end

  test "missing file → empty snapshot, no error" do
    assert :ok = FileLoader.load("/tmp/does/not/exist.yaml")
    refute Grants.has?("ou_admin", "workspace:any/any")
  end

  test "malformed YAML → error, prior snapshot kept" do
    FileLoader.load(Path.join(@fixtures, "valid.yaml"))
    {:error, {:yaml_parse, _}} = FileLoader.load(Path.join(@fixtures, "invalid_yaml.yaml"))
    # admin grant from previous load survives
    assert Grants.has?("ou_admin", "workspace:any/any.perm")
  end

  test "unknown permission → error, prior snapshot kept" do
    FileLoader.load(Path.join(@fixtures, "valid.yaml"))

    {:error, {:unknown_permission, "msg.sned", "ou_typo"}} =
      FileLoader.load(Path.join(@fixtures, "unknown_permission.yaml"))

    assert Grants.has?("ou_alice", "workspace:proj-a/msg.send")
  end

  describe "PR-21γ — session: scope prefix accepted (regression for prod blocker)" do
    test "session:default/create + session:default/end load successfully" do
      yaml = """
      principals:
        - id: linyilun
          kind: esr_user
          capabilities:
            - "session:default/create"
            - "session:default/end"
      """

      path = Path.join(System.tmp_dir!(), "session_scope_caps_#{System.unique_integer()}.yaml")
      File.write!(path, yaml)
      on_exit(fn -> File.rm(path) end)

      assert :ok = FileLoader.load(path)
      assert Grants.has?("linyilun", "session:default/create")
      assert Grants.has?("linyilun", "session:default/end")
    end

    test "unknown scope prefix still fails — only `session:` and `workspace:` are accepted" do
      yaml = """
      principals:
        - id: linyilun
          kind: esr_user
          capabilities:
            - "totally-fake:thing/perm"
      """

      path = Path.join(System.tmp_dir!(), "bad_scope_caps_#{System.unique_integer()}.yaml")
      File.write!(path, yaml)
      on_exit(fn -> File.rm(path) end)

      assert {:error, {:bad_scope_prefix, "totally-fake:thing"}} = FileLoader.load(path)
    end
  end
end
