defmodule Esr.Resource.Media.ImagePhaser do
  @moduledoc """
  Image content Phaser. Converts a resolved image Path to:
  - `:path` (identity)
  - `:bytes` (raw file contents)
  - `:base64_data_url` (data:image/<mime>;base64,...)
  """
  @behaviour Esr.Resource.Media.Phaser

  @mime_by_ext %{
    "png" => "image/png",
    "jpg" => "image/jpeg",
    "jpeg" => "image/jpeg",
    "gif" => "image/gif",
    "webp" => "image/webp",
    "heic" => "image/heic"
  }

  @impl true
  def media_type, do: :image

  @impl true
  def input_formats, do: [:path]

  @impl true
  def output_formats, do: [:path, :bytes, :base64_data_url]

  @impl true
  def streaming?, do: false

  @impl true
  def transform({:path, p}, :path), do: {:ok, p}

  def transform({:path, p}, :bytes), do: File.read(p)

  def transform({:path, p}, :base64_data_url) do
    with {:ok, bytes} <- File.read(p) do
      ext = p |> Path.extname() |> String.downcase() |> String.trim_leading(".")
      mime = Map.get(@mime_by_ext, ext, "application/octet-stream")
      {:ok, "data:#{mime};base64,#{Base.encode64(bytes)}"}
    end
  end

  def transform(_input, target), do: {:error, {:unsupported_target, target}}
end
