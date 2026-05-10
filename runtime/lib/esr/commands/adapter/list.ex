defmodule Esr.Commands.Adapter.List do
  @moduledoc """
  `/adapter:list` slash command — list configured adapter instances
  from the per-thing-directory layout (`adapters/<name>/config.yaml`).

  Per yaml-layout-v2 (spec § 4.5, § 4.6) — moved from
  `Esr.Commands.Adapters.List` (plural) to `Esr.Commands.Adapter.List`
  (singular). Backed by `Esr.Adapters.list/0` + `list_disabled/0`
  instead of inline yaml read.

  Carries no secrets — exposes both slash + CLI per spec § 4.6.

  Output format:

      <instance_name>  type=<type>  [app_id=<id>] [app_secret=***]
      ...
      _disabled (paused):
      <instance_name>  type=<type>  [app_id=<id>]
  """

  use Esr.Commands.Meta

  command :adapter_list do
    slash         "/adapter:list"
    category      "Adapters"
    description   "列 adapters/ 下的 adapter 实例（type / app_id）+ adapters/_disabled/ 下的暂停实例"
    permission    nil
    requires_user_binding      false
    requires_workspace_binding false
  end

  @behaviour Esr.Role.Control

  @type result :: {:ok, map()}

  @spec execute(map()) :: result()
  def execute(_cmd) do
    active = Esr.Adapters.list()
    disabled = Esr.Adapters.list_disabled()

    text =
      [render_section(active, header: nil, label_when_empty: "no adapter instances configured"),
       render_section(disabled, header: "_disabled (paused):", label_when_empty: nil)]
      |> Enum.reject(&(&1 == nil or &1 == ""))
      |> Enum.join("\n\n")

    {:ok, %{"text" => text}}
  end

  defp render_section([], opts) do
    case Keyword.get(opts, :label_when_empty) do
      nil -> nil
      label -> label
    end
  end

  defp render_section(list, opts) do
    body = Enum.map_join(list, "\n", &format_row/1)

    case Keyword.get(opts, :header) do
      nil -> body
      header -> header <> "\n" <> body
    end
  end

  defp format_row(%{name: name, type: type, config: config}) do
    parts =
      ["type=#{type}"]
      |> maybe_append(config["app_id"], &"app_id=#{&1}")
      |> maybe_append(config["base_url"], &"base_url=#{&1}")
      |> maybe_append(config["app_secret"], fn _ -> "app_secret=***" end)

    "#{name}  " <> Enum.join(parts, "  ")
  end

  defp maybe_append(parts, nil, _formatter), do: parts
  defp maybe_append(parts, "", _formatter), do: parts
  defp maybe_append(parts, value, formatter), do: parts ++ [formatter.(value)]
end
