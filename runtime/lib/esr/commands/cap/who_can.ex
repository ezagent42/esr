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

  alias Esr.Resource.Capability.Grants

  @type result :: {:ok, map()} | {:error, map()}

  @spec execute(map()) :: result()
  def execute(%{"args" => %{"permission" => perm}}) when is_binary(perm) and perm != "" do
    path = Esr.Paths.capabilities_yaml()

    matches =
      case YamlElixir.read_from_file(path) do
        {:ok, %{"principals" => principals}} when is_list(principals) ->
          principals
          |> Enum.filter(fn p ->
            is_map(p) and any_cap_grants?(p["capabilities"] || [], perm)
          end)
          |> Enum.map(fn p -> p["id"] end)
          |> Enum.reject(&is_nil/1)
          |> Enum.sort()

        _ ->
          []
      end

    body =
      case matches do
        [] -> "no principals can do '#{perm}'"
        ids -> Enum.join(ids, "\n")
      end

    {:ok, %{"text" => body}}
  end

  def execute(_cmd) do
    {:error,
     %{
       "type" => "invalid_args",
       "message" => "cap_who_can requires args.permission (non-empty string)"
     }}
  end

  defp any_cap_grants?(caps, perm) when is_list(caps) do
    Enum.any?(caps, fn held -> is_binary(held) and Grants.matches?(held, perm) end)
  end

  defp any_cap_grants?(_, _), do: false
end
