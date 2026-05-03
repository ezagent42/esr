defmodule Esr.Pools do
  @moduledoc """
  Reader for optional `${ESRD_HOME}/<instance>/pools.yaml`. Returns
  per-pool max-worker overrides, clamped to `Esr.Entity.Pool.default_max_workers/0`
  (128) and floored to 1.

  Voice pools default to 4. Pools not mentioned in the `@defaults` map
  below and not present in `pools.yaml` return the global cap — we
  assume the caller has verified that this is a pool that should exist;
  we just don't have an opinion on a smaller default.

  `pools.yaml` shape:

      pools:
        voice_asr_pool: 8
        voice_tts_pool: 6

  Missing/unreadable yaml is treated as "use defaults everywhere".

  Spec §8.1 footnote; reserved for PR-5 to add a writer CLI /
  hot-reload. Expansion P4a-7.
  """
  @voice_default 4
  @defaults %{
    voice_asr_pool: @voice_default,
    voice_tts_pool: @voice_default
  }

  @doc """
  Return the max-worker count for `pool`, consulting `pools.yaml` at
  `path` if provided and readable. Always in `[1, default_max_workers]`.

  Callers pass `nil` for `path` to skip the yaml read entirely (prod
  default when `pools.yaml` is absent).
  """
  @spec pool_max(atom(), Path.t() | nil) :: pos_integer()
  def pool_max(pool, path) do
    default = Map.get(@defaults, pool, Esr.Entity.Pool.default_max_workers())
    cap = Esr.Entity.Pool.default_max_workers()

    raw =
      case read_yaml(path) do
        {:ok, data} ->
          case Map.fetch(data, Atom.to_string(pool)) do
            {:ok, v} when is_integer(v) -> v
            _ -> default
          end

        :error ->
          default
      end

    raw |> min(cap) |> max(1)
  end

  defp read_yaml(nil), do: :error

  defp read_yaml(path) do
    with true <- File.exists?(path),
         {:ok, parsed} <- YamlElixir.read_from_file(path),
         pools when is_map(pools) <- parsed["pools"] || %{} do
      {:ok, pools}
    else
      _ -> :error
    end
  end
end
