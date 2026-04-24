defmodule Esr.Permissions.BootstrapTest do
  use ExUnit.Case, async: false

  alias Esr.Permissions.Bootstrap
  alias Esr.Permissions.Registry

  setup do
    # Registry is started by Esr.Application via Esr.Capabilities.Supervisor.
    # Fall back to start_supervised! only if the app-level singleton is absent.
    if Process.whereis(Registry) == nil do
      start_supervised!(Registry)
    end

    # Reset state between tests — the app-level Registry is long-lived and
    # may already have been populated by previous suites (or by the app
    # boot path itself, which is the system-under-test here).
    Registry.reset()
    :ok = Bootstrap.bootstrap()
    :ok
  end

  test "subsystem-intrinsic permissions are registered" do
    assert Registry.declared?("cap.manage")
    assert Registry.declared?("cap.read")
  end

  test "handler-declared permissions from Esr.PeerServer are registered" do
    # PeerServer declares the built-in MCP tools (reply, send_file,
    # _echo, session.signal_cleanup). CAP-4 would deny every
    # tool_invoke without these in the Registry, so coverage here
    # guards the happy path. PR-9 T5 removed `react` — it's now a
    # per-IM-proxy concern emitted by FeishuChatProxy, not a
    # CC-facing MCP tool.
    assert Registry.declared?("reply")
    refute Registry.declared?("react")
    assert Registry.declared?("send_file")
    assert Registry.declared?("_echo")
    assert Registry.declared?("session.signal_cleanup")
  end

  test "bootstrap is idempotent (safe to re-run)" do
    assert :ok = Bootstrap.bootstrap()
    assert :ok = Bootstrap.bootstrap()
    assert Registry.declared?("cap.manage")
  end

  test "Esr.PeerServer implements the Esr.Handler behaviour" do
    # The MCP tool names come from PeerServer.permissions/0 — verify
    # the callback shape directly so a future rename to the behaviour
    # surface gets caught here rather than via a cryptic missed grant.
    assert function_exported?(Esr.PeerServer, :permissions, 0)

    assert Esr.PeerServer.permissions() == [
             "reply",
             "send_file",
             "_echo",
             "session.signal_cleanup"
           ]
  end
end
