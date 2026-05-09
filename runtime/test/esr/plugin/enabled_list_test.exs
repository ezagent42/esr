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

  test "yaml with `config:` key raises (yaml-layout-v2 hard cutover)" do
    # Per spec § 4.2: `plugins.yaml` is enabled-only. Per-plugin config
    # moved to `plugins/<name>/config.yaml`. Any leftover `config:`
    # block is operator error and surfaces as a raise.
    path =
      write!("""
      enabled:
        - feishu
      config:
        feishu:
          app_secret: "leftover"
      """)

    assert_raise RuntimeError, ~r/plugins\.yaml.*non-enabled top-level keys.*\["config"\]/s, fn ->
      EnabledList.read(path)
    end
  end

  test "yaml with arbitrary other top-level key raises" do
    path = write!("other_key: 1\n")

    assert_raise RuntimeError, ~r/non-enabled top-level keys/, fn ->
      EnabledList.read(path)
    end
  end

  test "malformed yaml falls back to legacy default" do
    path = write!("enabled: \"unterminated\n")
    assert ["feishu", "claude_code"] == EnabledList.read(path)
  end

  test "legacy_default/0 exposes the fallback list" do
    assert EnabledList.legacy_default() == ["feishu", "claude_code"]
  end
end
