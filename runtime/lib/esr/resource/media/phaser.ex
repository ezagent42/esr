defmodule Esr.Resource.Media.Phaser do
  @moduledoc """
  Behaviour for per-media-type format converters. See spec
  `docs/superpowers/specs/2026-05-08-multimedia-content-protocol-design.md` §3.3.

  Phasers transform a `{format, value}` input tuple into a target
  format. In MVP, input is always `{:path, Path.t()}` (the
  Resolver always yields a Path). Output formats vary per media
  type — image supports `:base64_data_url`, file supports
  `:inline_text` for small text files, etc.

  `streaming?/0` is reserved for future streaming Phasers
  (audio / video real-time); MVP implementations return `false`.
  """

  @callback media_type() :: atom()
  @callback input_formats() :: [atom()]
  @callback output_formats() :: [atom()]
  @callback streaming?() :: boolean()
  @callback transform(input :: {atom(), term()}, target :: atom()) ::
              {:ok, term()} | {:error, term()}
end
