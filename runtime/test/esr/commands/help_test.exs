defmodule Esr.Commands.HelpTest do
  @moduledoc """
  Tests for `Esr.Commands.Help` (PR-21κ).

  The Help module renders from `Esr.Resource.SlashRoute.Registry.list_slashes/0`. We
  load a small synthetic snapshot via `SlashRouteRegistry.load_snapshot/1` so
  the test doesn't depend on the priv default yaml shape.
  """

  use ExUnit.Case, async: false

  alias Esr.Commands.Help
  alias Esr.Resource.SlashRoute.Registry, as: SlashRouteRegistry

  setup do
    if Process.whereis(SlashRouteRegistry) == nil, do: start_supervised!(SlashRouteRegistry)
    SlashRouteRegistry.load_snapshot(%{slashes: [], internal_kinds: []})

    # Restore the priv default after the test so cross-file Dispatcher
    # tests (which look up kind → permission via SlashRouteRegistry ETS) keep
    # working post-PR-21κ Phase 6.
    on_exit(fn ->
      priv = Application.app_dir(:esr, "priv/slash-routes.default.yaml")
      if File.exists?(priv), do: Esr.Resource.SlashRoute.Registry.FileLoader.load(priv)
    end)

    :ok
  end

  test "execute/1 returns text under :ok tuple" do
    load_snapshot([
      route("/help", "help", category: "诊断", description: "show command reference"),
      route("/sessions", "session_list", category: "Sessions", description: "list sessions")
    ])

    assert {:ok, %{"text" => text}} = Help.execute(%{})
    assert is_binary(text)
    assert text =~ "ESR slash commands"
  end

  test "groups by category and orders 诊断 before Sessions" do
    load_snapshot([
      route("/sessions", "session_list", category: "Sessions"),
      route("/help", "help", category: "诊断")
    ])

    {:ok, %{"text" => text}} = Help.execute(%{})

    diag_idx = :binary.match(text, "诊断") |> elem(0)
    sess_idx = :binary.match(text, "Sessions") |> elem(0)
    assert diag_idx < sess_idx
  end

  test "renders required and optional args differently" do
    load_snapshot([
      route("/new-session", "session_new",
        category: "Sessions",
        description: "create",
        args: [
          %{name: "name", required: true},
          %{name: "root", required: false}
        ]
      )
    ])

    {:ok, %{"text" => text}} = Help.execute(%{})
    assert text =~ "name=<…>"
    assert text =~ "[root=<…>]"
  end

  test "uncategorized routes go to 其他 last" do
    load_snapshot([
      route("/help", "help", category: "诊断"),
      route("/orphan", "orphan", category: nil)
    ])

    {:ok, %{"text" => text}} = Help.execute(%{})
    assert text =~ "其他"
    other_idx = :binary.match(text, "其他") |> elem(0)
    diag_idx = :binary.match(text, "诊断") |> elem(0)
    assert diag_idx < other_idx
  end

  defp route(slash, kind, opts) do
    %{
      slash: slash,
      kind: kind,
      permission: nil,
      command_module: Esr.Commands.Notify,
      requires_workspace_binding: false,
      requires_user_binding: false,
      category: Keyword.get(opts, :category),
      description: Keyword.get(opts, :description, ""),
      aliases: [],
      args: Keyword.get(opts, :args, [])
    }
  end

  defp load_snapshot(routes) do
    SlashRouteRegistry.load_snapshot(%{slashes: routes, internal_kinds: []})
  end
end
