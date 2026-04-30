defmodule Esr.Admin.Commands.HelpTest do
  @moduledoc """
  Tests for `Esr.Admin.Commands.Help` (PR-21κ).

  The Help module renders from `Esr.SlashRoutes.list_slashes/0`. We
  load a small synthetic snapshot via `SlashRoutes.load_snapshot/1` so
  the test doesn't depend on the priv default yaml shape.
  """

  use ExUnit.Case, async: false

  alias Esr.Admin.Commands.Help
  alias Esr.SlashRoutes

  setup do
    if Process.whereis(SlashRoutes) == nil, do: start_supervised!(SlashRoutes)
    SlashRoutes.load_snapshot(%{slashes: [], internal_kinds: []})
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
      command_module: Esr.Admin.Commands.Notify,
      requires_workspace_binding: false,
      requires_user_binding: false,
      category: Keyword.get(opts, :category),
      description: Keyword.get(opts, :description, ""),
      aliases: [],
      args: Keyword.get(opts, :args, [])
    }
  end

  defp load_snapshot(routes) do
    SlashRoutes.load_snapshot(%{slashes: routes, internal_kinds: []})
  end
end
