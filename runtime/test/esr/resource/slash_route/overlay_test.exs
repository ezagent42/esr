defmodule Esr.Resource.SlashRoute.OverlayTest do
  use ExUnit.Case, async: false

  alias Esr.Resource.SlashRoute.Registry, as: SlashRouteRegistry

  defp simple_route(slash, kind, mod_str \\ "Esr.Test.NoopCommand") do
    %{
      slash: slash,
      kind: kind,
      permission: nil,
      command_module: Module.concat([mod_str]),
      requires_workspace_binding: false,
      requires_user_binding: false,
      category: "test",
      description: "test",
      args: [],
      aliases: []
    }
  end

  defp base_snapshot(slashes \\ [], internal \\ []) do
    %{slashes: slashes, internal_kinds: internal}
  end

  setup do
    # Reset to a known baseline so tests don't depend on each other.
    :ok = SlashRouteRegistry.load_snapshot(base_snapshot([simple_route("/help", "help")]))
    :ok = SlashRouteRegistry.unregister_overlay("test_a")
    :ok = SlashRouteRegistry.unregister_overlay("test_b")

    # Clean up overlays at end too — otherwise the last test in this file
    # leaves overlay state in the singleton SlashRouteRegistry and pollutes
    # downstream test files (e.g. `Esr.SlashRoutesTest` whose `list_*` /
    # `dump/1` assertions count entries in the merged ETS view, with no
    # way to filter out overlays). Restore the priv default snapshot so
    # subsequent tests see the production base table.
    on_exit(fn ->
      :ok = SlashRouteRegistry.unregister_overlay("test_a")
      :ok = SlashRouteRegistry.unregister_overlay("test_b")

      priv = Application.app_dir(:esr, "priv/slash-routes.default.yaml")

      if File.exists?(priv) do
        Esr.Resource.SlashRoute.Registry.FileLoader.load(priv)
      end
    end)

    :ok
  end

  describe "register_overlay/2" do
    test "installs a plugin's slashes alongside the base table" do
      :ok =
        SlashRouteRegistry.register_overlay("test_a", base_snapshot([simple_route("/test_a:foo", "test_a_foo")]))

      assert {:ok, _} = SlashRouteRegistry.lookup("/help")
      assert {:ok, _} = SlashRouteRegistry.lookup("/test_a:foo")
      assert SlashRouteRegistry.command_module_for("test_a_foo") == Esr.Test.NoopCommand
    end

    test "rejects an overlay that collides with the base on a slash key" do
      assert {:error, {:slash_collision, "/help"}} =
               SlashRouteRegistry.register_overlay(
                 "test_a",
                 base_snapshot([simple_route("/help", "test_a_help")])
               )

      # The rejected overlay's kind must NOT have been installed —
      # rollback rebuilt the merged view from the pre-call state.
      assert SlashRouteRegistry.command_module_for("test_a_help") == :not_found
    end

    test "rejects an overlay that collides with another overlay on a kind" do
      :ok =
        SlashRouteRegistry.register_overlay("test_a", base_snapshot([], [simple_route("/test_a:x", "shared_kind")]))

      assert {:error, {:kind_collision, "shared_kind"}} =
               SlashRouteRegistry.register_overlay(
                 "test_b",
                 base_snapshot([], [simple_route("/test_b:y", "shared_kind")])
               )
    end
  end

  describe "unregister_overlay/1" do
    test "removes the overlay's entries from the merged view" do
      :ok =
        SlashRouteRegistry.register_overlay("test_a", base_snapshot([simple_route("/test_a:foo", "test_a_foo")]))

      :ok = SlashRouteRegistry.unregister_overlay("test_a")

      assert :not_found = SlashRouteRegistry.lookup("/test_a:foo")
    end

    test "is idempotent" do
      assert :ok = SlashRouteRegistry.unregister_overlay("never_registered")
    end
  end

  describe "load_snapshot preserves overlays" do
    test "reloading the base file does not wipe a registered overlay" do
      :ok =
        SlashRouteRegistry.register_overlay("test_a", base_snapshot([simple_route("/test_a:foo", "test_a_foo")]))

      :ok =
        SlashRouteRegistry.load_snapshot(
          base_snapshot([simple_route("/help", "help"), simple_route("/info", "info")])
        )

      assert {:ok, _} = SlashRouteRegistry.lookup("/test_a:foo")
      assert {:ok, _} = SlashRouteRegistry.lookup("/info")
    end
  end
end
