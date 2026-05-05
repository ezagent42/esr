defmodule Esr.Commands.Help do
  @moduledoc """
  `/help` slash command — renders the slash command reference from
  `Esr.Resource.SlashRoute.Registry.list_slashes/0` (PR-21κ, 2026-04-30).

  Pre-PR-21κ this text was a hardcoded heredoc in
  `Esr.Entity.FeishuAppAdapter.help_text/0`. Now it's data-driven from
  `slash-routes.yaml`: each slash's `description` + `category` + `args`
  spec composes the rendered output.

  Returns a string under `"text"` for the SlashHandler reply path.
  """

  @behaviour Esr.Role.Control

  @type result :: {:ok, map()}

  @spec execute(map()) :: result()
  def execute(_cmd) do
    text = render()
    {:ok, %{"text" => text}}
  end

  @doc false
  # Render the help text by grouping slashes by category and emitting
  # `<slash> <args>` lines with the description below. Categories
  # appear in deterministic order; "其他" sorts last.
  def render do
    slashes = Esr.Resource.SlashRoute.Registry.list_slashes()

    sections =
      slashes
      |> Enum.group_by(fn route -> route[:category] || "其他" end)
      |> Enum.sort_by(fn {cat, _} -> category_order(cat) end)
      |> Enum.map_join("\n\n", &render_section/1)

    """
    📖 ESR slash commands

    #{sections}

    诊断细节（cap、URI、状态）请用 /doctor。
    """
  end

  defp category_order("诊断"), do: 0
  defp category_order("Workspace"), do: 1
  defp category_order("Sessions"), do: 2
  defp category_order("Agents"), do: 3
  defp category_order("其他"), do: 99
  defp category_order(_), do: 50

  defp render_section({category, routes}) do
    body =
      routes
      |> Enum.sort_by(& &1.kind)
      |> Enum.map_join("\n", &render_route/1)

    "#{category}：\n#{body}"
  end

  defp render_route(route) do
    args = render_args(route.args)
    arg_str = if args == "", do: "", else: " " <> args

    "  #{route.slash}#{arg_str}\n                   — #{route.description}"
  end

  defp render_args([]), do: ""

  defp render_args(args) do
    args
    |> Enum.map(fn
      %{name: name, required: true} -> "#{name}=<…>"
      %{name: name} -> "[#{name}=<…>]"
    end)
    |> Enum.join(" ")
  end
end
