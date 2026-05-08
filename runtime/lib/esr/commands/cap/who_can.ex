defmodule Esr.Commands.Cap.WhoCan do
  @moduledoc """
  `cap_who_can` slash / admin-queue command — reverse lookup. List
  every principal whose held capabilities grant `permission`.

  Reads `capabilities.yaml` directly. Wildcard rules follow the same
  semantics as `Esr.Resource.Capability.Grants.matches?/2` so a held
  `prefix:*/perm` grants any `prefix:<scope>/perm` etc. Mirrors Python
  `esr cap who-can <permission>`.

  Phase B-2 of the Phase 3/4 finish (2026-05-05).
  """

  @behaviour Esr.Role.Control

  alias Esr.Resource.Capability.UuidTranslator

  @type result :: {:ok, map()} | {:error, map()}

  @spec execute(map()) :: result()
  def execute(%{"args" => %{"permission" => perm}}) when is_binary(perm) and perm != "" do
    case UuidTranslator.name_to_uuid(perm) do
      {:ok, translated_perm} ->
        do_who_can(translated_perm)

      {:error, :unknown_workspace} ->
        {:error,
         %{
           "type" => "unknown_workspace",
           "message" => "no workspace named in capability: #{perm}"
         }}
    end
  end

  def execute(_cmd) do
    {:error,
     %{
       "type" => "invalid_args",
       "message" => "cap_who_can requires args.permission (non-empty string)"
     }}
  end

  defp do_who_can(translated_perm) do
    path = Esr.Paths.capabilities_yaml()

    matches =
      case YamlElixir.read_from_file(path) do
        {:ok, %{"principals" => principals}} when is_list(principals) ->
          principals
          |> Enum.filter(fn p ->
            is_map(p) and any_cap_grants?(p["capabilities"] || [], translated_perm)
          end)
          |> Enum.map(fn p -> p["id"] end)
          |> Enum.reject(&is_nil/1)
          |> Enum.sort()

        _ ->
          []
      end

    body =
      case matches do
        [] -> "no principals can do '#{translated_perm}'"
        ids -> Enum.join(ids, "\n")
      end

    {:ok, %{"text" => body}}
  end

  defp any_cap_grants?(caps, perm) when is_list(caps) do
    Enum.any?(caps, fn held -> is_binary(held) and cap_matches?(held, perm) end)
  end

  defp any_cap_grants?(_, _), do: false

  # Mirrors Esr.Resource.Capability.Grants matching rules (that function is
  # private; we duplicate the small predicate here since WhoCan reads YAML
  # directly rather than querying ETS via Grants.has?/2).
  defp cap_matches?("*", _required), do: true
  defp cap_matches?(held, required) when held == required, do: true

  defp cap_matches?(held, required) do
    with {:ok, {h_prefix, h_name, h_perm}} <- split_cap(held),
         {:ok, {r_prefix, r_name, r_perm}} <- split_cap(required),
         true <- h_prefix == r_prefix do
      segment_match?(h_name, r_name) and segment_match?(h_perm, r_perm)
    else
      _ -> false
    end
  end

  defp split_cap(str) do
    with [scope, perm] <- String.split(str, "/", parts: 2),
         [prefix, name] <- String.split(scope, ":", parts: 2) do
      {:ok, {prefix, name, perm}}
    else
      _ -> :error
    end
  end

  defp segment_match?("*", _), do: true
  defp segment_match?(a, a), do: true
  defp segment_match?(_, _), do: false
end
