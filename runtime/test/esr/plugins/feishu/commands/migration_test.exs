defmodule Esr.Plugins.Feishu.MigrationTest do
  @moduledoc """
  Audit #6 rev-3 (2026-05-08-plugin-command-registration) gate test.

  Locks the post-migration kind dispatch contract: the three
  plugin-owned commands (notify, bind-feishu, unbind-feishu) now
  resolve under their new rev-3 kind names, and the OLD kind names
  return `:not_found` (no back-compat shim).

  This test is deliberately runtime-coupled — it asserts on the live
  SlashRouteRegistry's overlay state. In test env, runtime.exs auto-
  enables the feishu plugin via Esr.Plugin.EnabledList's legacy
  default, so the feishu overlay is registered at app boot. The tests
  rely on that registration; if a future refactor changes how plugins
  load in test env, this test will need a corresponding setup that
  explicitly registers the feishu overlay.
  """

  use ExUnit.Case, async: false

  alias Esr.Resource.SlashRoute.Registry, as: SlashRouteRegistry

  describe "post-migration kind dispatch (audit #6 rev-3)" do
    test "kind: feishu_notify resolves to the new module" do
      assert Esr.Plugins.Feishu.Commands.Notify ==
               SlashRouteRegistry.command_module_for("feishu_notify")
    end

    test "kind: feishu_bind resolves to BindUser" do
      assert Esr.Plugins.Feishu.Commands.BindUser ==
               SlashRouteRegistry.command_module_for("feishu_bind")
    end

    test "kind: feishu_unbind resolves to UnbindUser" do
      assert Esr.Plugins.Feishu.Commands.UnbindUser ==
               SlashRouteRegistry.command_module_for("feishu_unbind")
    end

    test "old kind names no longer resolve (no back-compat)" do
      assert :not_found = SlashRouteRegistry.command_module_for("notify")
      assert :not_found = SlashRouteRegistry.command_module_for("user_bind_feishu")
      assert :not_found = SlashRouteRegistry.command_module_for("user_unbind_feishu")
    end
  end
end
