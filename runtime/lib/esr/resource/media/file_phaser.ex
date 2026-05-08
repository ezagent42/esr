defmodule Esr.Resource.Media.FilePhaser do
  @moduledoc """
  Generic file content Phaser. Converts a resolved file Path to:
  - `:path` (identity)
  - `:bytes` (raw file contents)
  - `:inline_text` (text content if file is ≤ 100 KB; otherwise error)
  """
  @behaviour Esr.Resource.Media.Phaser

  @inline_text_max 100_000

  @impl true
  def media_type, do: :file

  @impl true
  def input_formats, do: [:path]

  @impl true
  def output_formats, do: [:path, :bytes, :inline_text]

  @impl true
  def streaming?, do: false

  @impl true
  def transform({:path, p}, :path), do: {:ok, p}

  def transform({:path, p}, :bytes), do: File.read(p)

  def transform({:path, p}, :inline_text) do
    case File.stat(p) do
      {:ok, %File.Stat{size: size}} when size <= @inline_text_max ->
        File.read(p)

      {:ok, _} ->
        {:error, :too_large_for_inline}

      err ->
        err
    end
  end

  def transform(_input, target), do: {:error, {:unsupported_target, target}}
end
