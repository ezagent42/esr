defmodule Esr.Resource.Media.PhaserRegistry do
  @moduledoc """
  Dispatches a resource URI to the appropriate per-media-type Phaser.

  Per spec `docs/superpowers/specs/2026-05-08-multimedia-content-protocol-design.md` §3.4.

  Pipeline:
    1. Parse URI via `Esr.Uri.parse_resource/1` to extract media_type
    2. Resolve URI via `Esr.Resource.Media.resolve/1` to get a local Path
    3. Dispatch `{:path, path}` to the registered Phaser for that media_type
    4. Phaser converts to the caller's requested target format

  Phasers are statically registered (compile-time map). Future PRs
  add audio / video / etc. by extending @phasers.
  """

  alias Esr.Resource.Media
  alias Esr.Resource.Media.{ImagePhaser, FilePhaser}

  @phasers %{
    image: ImagePhaser,
    file: FilePhaser
    # audio: AudioPhaser  — future PR
  }

  @doc """
  Returns the list of media_type atoms that have a registered Phaser.
  Used by capability checks + diagnostics.
  """
  @spec registered_media_types() :: [atom()]
  def registered_media_types, do: Map.keys(@phasers)

  @doc """
  Transforms a resource URI into the target format via the appropriate Phaser.

  Returns `{:ok, transformed}` on success.

  Errors:
  - `{:error, :invalid_uri}` — URI parse failed
  - `{:error, :wrong_env}` — URI's env doesn't match local
  - `{:error, :not_found}` — file doesn't exist on disk
  - `{:error, :no_phaser_for_media_type}` — no registered Phaser for the URI's media_type
  - `{:error, {:unsupported_target, target}}` — Phaser doesn't support the target format
  - any other Phaser-returned `{:error, _}` propagated as-is
  """
  @spec transform(String.t(), atom()) :: {:ok, term()} | {:error, term()}
  def transform(uri, target) when is_binary(uri) and is_atom(target) do
    with {:ok, %{media_type: mt}} <- normalize_parse_error(Esr.Uri.parse_resource(uri)),
         {:ok, path} <- Media.resolve(uri),
         phaser when not is_nil(phaser) <- Map.get(@phasers, mt) do
      phaser.transform({:path, path}, target)
    else
      nil -> {:error, :no_phaser_for_media_type}
      {:error, _} = err -> err
    end
  end

  # Normalize any Esr.Uri.parse_resource/1 error into :invalid_uri so the
  # documented error surface is stable regardless of the internal parse detail.
  defp normalize_parse_error({:ok, _} = ok), do: ok
  defp normalize_parse_error({:error, :invalid_uri}), do: {:error, :invalid_uri}
  defp normalize_parse_error({:error, _}), do: {:error, :invalid_uri}
end
