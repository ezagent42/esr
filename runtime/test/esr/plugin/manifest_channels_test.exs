defmodule Esr.Plugin.ManifestChannelsTest do
  @moduledoc """
  Tests for the `channels:` block on `Esr.Plugin.Manifest`.

  Spec: `docs/superpowers/specs/2026-05-10-session-template-and-channel.md`,
  Phase 1.

  Top-level (sibling of `name:`/`version:`) yaml block; lifted onto the
  struct as `manifest.channels` (a list of maps with `:name`, `:module`,
  and optional `:config_schema`). Validation enforces:
    * each entry has `name` and `module` strings
    * `module` resolves via `Code.ensure_loaded?/1`
    * malformed shape → `{:error, {:invalid_channel, reason}}`

  We use `Esr.Plugin.Manifest.parse_string/1` since the existing test
  suite uses it elsewhere; the file-based `parse/1` shares the same
  internals via `parse_raw/1`.
  """
  use ExUnit.Case, async: true

  alias Esr.Plugin.Manifest

  test "parse with channels: block populates Esr.Plugin.Manifest.channels" do
    yaml = ~S"""
    name: test-plugin
    version: 0.1.0
    channels:
      - name: chat_proxy
        module: Esr.Entity.Server
      - name: mcp_stdio
        module: Esr.Entity.PtyProcess
        config_schema:
          type: object
          properties:
            port: { type: integer }
    """

    {:ok, manifest} = Manifest.parse_string(yaml)

    assert length(manifest.channels) == 2
    assert Enum.find(manifest.channels, &(&1.name == "chat_proxy"))
    assert Enum.find(manifest.channels, &(&1.name == "mcp_stdio")).config_schema != nil
  end

  test "parse with channels: block referencing missing module returns error" do
    yaml = ~S"""
    name: test-plugin
    version: 0.1.0
    channels:
      - name: bogus
        module: Esr.NonExistent.Channel
    """

    assert {:error, _} = Manifest.parse_string(yaml)
  end

  test "parse with no channels: block leaves manifest.channels empty" do
    yaml = ~S"""
    name: test-plugin
    version: 0.1.0
    """

    {:ok, manifest} = Manifest.parse_string(yaml)
    assert manifest.channels == []
  end

  test "parse with channel entry missing :name returns error" do
    yaml = ~S"""
    name: test-plugin
    version: 0.1.0
    channels:
      - module: Esr.Entity.Server
    """

    assert {:error, {:invalid_channel, _}} = Manifest.parse_string(yaml)
  end

  test "parse with channel entry missing :module returns error" do
    yaml = ~S"""
    name: test-plugin
    version: 0.1.0
    channels:
      - name: orphaned
    """

    assert {:error, {:invalid_channel, _}} = Manifest.parse_string(yaml)
  end

  test "module is resolved to an atom on the struct" do
    yaml = ~S"""
    name: test-plugin
    version: 0.1.0
    channels:
      - name: stub
        module: Esr.Entity.Server
    """

    {:ok, manifest} = Manifest.parse_string(yaml)
    [%{name: "stub", module: mod}] = manifest.channels
    assert mod == Esr.Entity.Server
  end

  test "channels: not-a-list (e.g. a map) returns error" do
    yaml = ~S"""
    name: test-plugin
    version: 0.1.0
    channels:
      foo: bar
    """

    assert {:error, {:invalid_channel, _}} = Manifest.parse_string(yaml)
  end
end
