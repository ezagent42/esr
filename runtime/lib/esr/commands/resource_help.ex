defmodule Esr.Commands.ResourceHelp do
  @moduledoc """
  Handles bare-prefix help: `/workspace`, `/<resource>:help`, and the
  `/` (no resource) fallback. Pulls route metadata from
  `Esr.Resource.SlashRoute.Registry.list_slashes/0`.

  Wired by `Esr.Entity.SlashHandler` (Phase 6) when input matches a
  bare resource prefix.

  Phase 1 / step 4 of unified-grammar migration. Phase 6 wires this
  into the slash dispatch path.
  """

  @behaviour Esr.Role.Control

  alias Esr.Resource.SlashRoute.Registry

  @spec execute(map()) :: {:ok, %{required(String.t()) => String.t()}}
  def execute(%{"args" => %{"resource" => res}}) when is_binary(res) and res != "" do
    routes = list_routes_for_resource(res)

    text =
      case routes do
        [] -> unknown_resource_text(res)
        rs -> render_resource(res, rs)
      end

    {:ok, %{"text" => text}}
  end

  def execute(_), do: {:ok, %{"text" => render_top_level()}}

  defp list_routes_for_resource(res) do
    Registry.list_slashes()
    |> Enum.filter(fn route ->
      slash = route[:slash] || ""
      String.starts_with?(slash, "/" <> res <> ":")
    end)
    |> Enum.sort_by(& &1.kind)
  end

  defp render_resource(res, routes) do
    body =
      routes
      |> Enum.map_join("\n", fn route ->
        args_seg = render_args(route.args || [])
        arg_str = if args_seg == "", do: "", else: " " <> args_seg
        "  #{route.slash}#{arg_str}\n                   — #{route.description}"
      end)

    """
    📖 /#{res} — methods

    #{body}

    输入 /<command>:<method> [args...] 调用具体命令；/help 看完整清单。
    """
  end

  defp unknown_resource_text(res) do
    """
    ❌ 未知 resource: `#{res}`

    可用的 top-level resources:

    #{render_top_level_list()}

    输入 /help 看完整命令清单。
    """
  end

  defp render_top_level do
    """
    📖 ESR top-level resources

    #{render_top_level_list()}

    输入 /<resource> 或 /<resource>:help 看该 resource 的方法。
    /help 看完整命令清单。
    """
  end

  defp render_top_level_list do
    Registry.list_slashes()
    |> Enum.map(fn route -> route[:slash] || "" end)
    |> Enum.flat_map(fn
      "/" <> rest ->
        case String.split(rest, ":", parts: 2) do
          [resource, _method] -> [resource]
          _ -> []
        end

      _ ->
        []
    end)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.map_join("\n", fn r -> "  /#{r}" end)
  end

  defp render_args(args) do
    args
    |> Enum.map(fn
      %{name: n, required: true} -> "#{n}=<…>"
      %{name: n} -> "[#{n}=<…>]"
    end)
    |> Enum.join(" ")
  end
end
