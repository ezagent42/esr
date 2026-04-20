defmodule Esr.Capabilities.FileLoaderTest do
  use ExUnit.Case, async: false

  alias Esr.Capabilities.{FileLoader, Grants}
  alias Esr.Permissions.Registry

  @fixtures "test/support/capabilities_fixtures"

  setup do
    start_supervised!(Registry)
    start_supervised!(Grants)
    # Registry must declare the permissions used in fixtures
    Registry.register("msg.send", declared_by: Test)
    Registry.register("session.create", declared_by: Test)
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
end
