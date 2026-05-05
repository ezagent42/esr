defmodule Esr.Plugin.EnabledListTest do
  use ExUnit.Case, async: true

  alias Esr.Plugin.EnabledList

  @tmp_dir Path.join(System.tmp_dir!(), "esr_plugin_enabled_list_test")

  setup do
    File.rm_rf!(@tmp_dir)
    File.mkdir_p!(@tmp_dir)
    on_exit(fn -> File.rm_rf!(@tmp_dir) end)
    :ok
  end

  defp write!(content) do
    path = Path.join(@tmp_dir, "plugins.yaml")
    File.write!(path, content)
    path
  end

  test "missing file returns the legacy default list" do
    assert EnabledList.read(Path.join(@tmp_dir, "ghost.yaml")) ==
             ["feishu", "claude_code"]
  end

  test "explicit empty list disables every plugin (core-only)" do
    path = write!("enabled: []\n")
    assert [] == EnabledList.read(path)
  end

  test "non-empty list returns the listed plugin names" do
    path =
      write!("""
      enabled:
        - feishu
        - claude_code
      """)

    assert ["feishu", "claude_code"] == EnabledList.read(path)
  end

  test "non-string entries are filtered out" do
    path =
      write!("""
      enabled:
        - feishu
        - 42
        - voice
      """)

    assert ["feishu", "voice"] == EnabledList.read(path)
  end

  test "missing `enabled:` key falls back to legacy default" do
    path = write!("other_key: 1\n")
    assert ["feishu", "claude_code"] == EnabledList.read(path)
  end

  test "malformed yaml falls back to legacy default" do
    path = write!("enabled: \"unterminated\n")
    assert ["feishu", "claude_code"] == EnabledList.read(path)
  end

  test "legacy_default/0 exposes the fallback list" do
    assert EnabledList.legacy_default() == ["feishu", "claude_code"]
  end
end
