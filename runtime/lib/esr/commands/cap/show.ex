defmodule Esr.Commands.Cap.Show do
  @moduledoc """
  `cap_show` slash / admin-queue command — read-only printing of one
  principal's entry from `capabilities.yaml`.

  Reads `capabilities.yaml` directly (no runtime RPC). Returns the
  principal's `id`, `kind`, `note`, and `capabilities` as a YAML
  fragment under `text`. Mirrors Python `esr cap show <principal_id>`.

  Phase B-2 of the Phase 3/4 finish (2026-05-05).
  """

  use Esr.Commands.Meta

  command :cap_show do
    slash         :none
    category      "Capabilities"
    description   "显示 principal 在 capabilities.yaml 里的条目"
    permission    "cap.read"
    requires_user_binding      false
    requires_workspace_binding false

    arg :target_principal_id, required: true, doc: "principal whose caps to display"

    error :invalid_args, "cap_show requires args.target_principal_id (non-empty string)"
  end

  @behaviour Esr.Role.Control

  alias Esr.Commands.Render

  @type result :: {:ok, map()} | {:error, map()}

  @spec execute(map()) :: result()
  def execute(%{"args" => %{"target_principal_id" => pid}}) when is_binary(pid) and pid != "" do
    path = Esr.Paths.capabilities_yaml()

    case YamlElixir.read_from_file(path) do
      {:ok, %{"principals" => principals}} when is_list(principals) ->
        case Enum.find(principals, fn p -> is_map(p) and p["id"] == pid end) do
          nil ->
            {:ok, %{"text" => "principal not found: #{pid}"}}

          entry ->
            {:ok, %{"text" => render_entry(entry)}}
        end

      _ ->
        {:ok, %{"text" => "no capabilities.yaml at #{path}"}}
    end
  end

  def execute(_cmd) do
    Render.error(__MODULE__.command_meta(), :invalid_args)
  end

  defp render_entry(entry) do
    caps =
      (entry["capabilities"] || [])
      |> Enum.map(&Esr.Resource.Capability.UuidTranslator.render_cap_for_display/1)

    base = "id: #{entry["id"]}\nkind: #{entry["kind"] || ""}"
    note = if entry["note"] in [nil, ""], do: "", else: "\nnote: #{inspect(entry["note"])}"

    cap_lines =
      caps
      |> Enum.map(&"  - #{&1}")
      |> Enum.join("\n")

    cap_block = if cap_lines == "", do: "\ncapabilities: []", else: "\ncapabilities:\n#{cap_lines}"

    base <> note <> cap_block
  end
end
