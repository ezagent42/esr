defmodule Esr.Resource.SlashRoute.Registry.LookupPrefixTest do
  @moduledoc """
  Tests for `Esr.Resource.SlashRoute.Registry.lookup_prefix/1` — the
  bare-prefix fall-back resolver wired into Phase 6 of the
  unified-command-grammar migration.

  Distinct from `lookup/1`: `lookup/1` answers "is this slash a known
  route?" and returns `{:ok, route}` or `:not_found`. `lookup_prefix/1`
  answers "if NOT a known route, was it a known *resource* prefix?" and
  returns one of the structured atoms below. SlashHandler consults it
  AFTER `@deprecated_slashes` so renamed-slash hints retain priority.
  """

  use ExUnit.Case, async: false

  alias Esr.Resource.SlashRoute.Registry

  setup do
    if Process.whereis(Registry) == nil do
      start_supervised!(Registry)
    end

    # Load a deterministic snapshot so the tests don't depend on the
    # priv yaml moving under us.
    Registry.load_snapshot(%{
      slashes: [
        %{
          slash: "/workspace:new",
          kind: "workspace_new",
          permission: nil,
          command_module: __MODULE__.NoOp,
          requires_workspace_binding: false,
          requires_user_binding: false,
          category: "Workspace",
          description: "create workspace",
          aliases: [],
          args: []
        },
        %{
          slash: "/workspace:list",
          kind: "workspace_list",
          permission: nil,
          command_module: __MODULE__.NoOp,
          requires_workspace_binding: false,
          requires_user_binding: false,
          category: "Workspace",
          description: "list workspaces",
          aliases: [],
          args: []
        },
        %{
          slash: "/session:list",
          kind: "session_list",
          permission: nil,
          command_module: __MODULE__.NoOp,
          requires_workspace_binding: false,
          requires_user_binding: false,
          category: "Session",
          description: "list sessions",
          aliases: [],
          args: []
        }
      ],
      internal_kinds: []
    })

    on_exit(fn ->
      priv = Application.app_dir(:esr, "priv/slash-routes.default.yaml")
      if File.exists?(priv), do: Esr.Resource.SlashRoute.Registry.FileLoader.load(priv)
    end)

    :ok
  end

  test "lookup_prefix/1 with /workspace returns {:resource_help, \"workspace\"}" do
    assert {:resource_help, "workspace"} = Registry.lookup_prefix("/workspace")
  end

  test "lookup_prefix/1 with /workspace:help returns {:resource_help, \"workspace\"}" do
    assert {:resource_help, "workspace"} = Registry.lookup_prefix("/workspace:help")
  end

  test "lookup_prefix/1 with /totallybogus returns {:unknown_resource, ...}" do
    assert {:unknown_resource, "totallybogus"} = Registry.lookup_prefix("/totallybogus")
  end

  test "lookup_prefix/1 with /workspace:bogusmethod returns {:unknown_method, ...}" do
    assert {:unknown_method, "workspace", "bogusmethod"} =
             Registry.lookup_prefix("/workspace:bogusmethod")
  end

  test "lookup_prefix/1 with a real slash returns :no_match" do
    # /workspace:new is a real slash; lookup_prefix shouldn't shadow lookup/1.
    assert :no_match = Registry.lookup_prefix("/workspace:new")
  end

  test "lookup_prefix/1 with empty / returns {:resource_help, nil}" do
    assert {:resource_help, nil} = Registry.lookup_prefix("/")
  end

  test "lookup_prefix/1 with trailing args ignores them" do
    assert {:resource_help, "workspace"} = Registry.lookup_prefix("/workspace foo bar")
  end

  test "lookup_prefix/1 with non-slash text returns :no_match" do
    assert :no_match = Registry.lookup_prefix("hello world")
  end
end
