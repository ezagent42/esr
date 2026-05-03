defmodule Esr.Entity.User.FileLoaderTest do
  use ExUnit.Case, async: false

  alias Esr.Entity.User.FileLoader
  alias Esr.Entity.User.Registry

  setup do
    if Process.whereis(Registry) == nil, do: start_supervised!(Registry)
    Registry.load_snapshot(%{})

    tmp_dir = System.tmp_dir!() |> Path.join("esr-users-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)

    on_exit(fn -> File.rm_rf(tmp_dir) end)
    {:ok, tmp_dir: tmp_dir}
  end

  test "load valid file populates Registry", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "users.yaml")

    File.write!(path, """
    users:
      linyilun:
        feishu_ids:
          - ou_AAA
          - ou_BBB
      yaoshengyue:
        feishu_ids:
          - ou_CCC
    """)

    assert :ok = FileLoader.load(path)
    assert {:ok, "linyilun"} = Registry.lookup_by_feishu_id("ou_AAA")
    assert {:ok, "linyilun"} = Registry.lookup_by_feishu_id("ou_BBB")
    assert {:ok, "yaoshengyue"} = Registry.lookup_by_feishu_id("ou_CCC")
    assert length(Registry.list()) == 2
  end

  test "missing file → empty snapshot, no error" do
    assert :ok = FileLoader.load("/tmp/does-not-exist-#{System.unique_integer([:positive])}.yaml")
    assert Registry.list() == []
  end

  test "malformed yaml → error, prior snapshot kept", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "users.yaml")

    File.write!(path, """
    users:
      linyilun:
        feishu_ids:
          - ou_AAA
    """)

    :ok = FileLoader.load(path)
    assert {:ok, "linyilun"} = Registry.lookup_by_feishu_id("ou_AAA")

    File.write!(path, "users:\n  - this is not a map\n  unbalanced: [")
    assert {:error, {:yaml_parse, _}} = FileLoader.load(path)

    # Prior snapshot survives
    assert {:ok, "linyilun"} = Registry.lookup_by_feishu_id("ou_AAA")
  end

  test "user with no feishu_ids is admitted with empty list", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "users.yaml")

    File.write!(path, """
    users:
      orphan:
        feishu_ids: []
      ghost: {}
    """)

    assert :ok = FileLoader.load(path)
    assert {:ok, %{feishu_ids: []}} = Registry.get("orphan")
    assert {:ok, %{feishu_ids: []}} = Registry.get("ghost")
  end

  test "non-conforming username admitted with warning", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "users.yaml")

    File.write!(path, """
    users:
      "user with spaces":
        feishu_ids: [ou_X]
    """)

    # Logger is captured implicitly; we just assert the load succeeds and
    # the user is queryable. Operators editing the file by hand shouldn't
    # see a hard reject.
    assert :ok = FileLoader.load(path)
    assert {:ok, _} = Registry.get("user with spaces")
  end
end
