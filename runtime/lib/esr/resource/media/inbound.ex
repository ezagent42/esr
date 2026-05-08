defmodule Esr.Resource.Media.Inbound do
  @moduledoc """
  Orchestrates non-text inbound flow per spec
  `docs/superpowers/specs/2026-05-08-multimedia-content-protocol-design.md`
  §"Inbound flow":

    1. Capability check via `PluginRegistry.supports?(target, :inbound, kind)`
    2. Invoke `download_file` directive on source adapter (yields URI)
    3. Build envelope with URI content + meta, ready for downstream peer

  Caller passes `directive_fn` for testability + decoupling from the
  adapter_socket layer. In production the directive_fn is a closure
  that calls `Esr.Adapter.dispatch(:feishu, instance_id, action, args)`
  (or whatever the runtime's dispatch API is — Phase 2 Task 2.4 wires
  this from FeishuChatProxy).
  """

  alias Esr.Resource.Media.PluginRegistry

  @type inbound :: %{
          msg_type: String.t(),
          adapter_msg: map(),
          meta: %{
            required(:chat_id) => String.t(),
            required(:sender_id) => String.t(),
            required(:source_plugin) => String.t(),
            required(:target_plugin) => String.t(),
            optional(atom()) => term()
          }
        }

  @type envelope :: %{
          msg_type: String.t(),
          content: String.t(),
          meta: map()
        }

  @doc """
  Handles a non-text inbound, producing a URI-shaped envelope ready
  for downstream peer routing.

  Options:
  - `directive_fn` (REQUIRED): function `(action, args) -> {:ok, map} | {:error, term}`
    that the caller uses to dispatch directives to the source adapter.
    In tests, pass a mock; in production, pass a closure that calls the
    real adapter dispatch API.

  Returns:
  - `{:ok, envelope}` on success
  - `{:error, :unsupported_kind}` if target doesn't declare the kind
  - `{:error, {:download_failed, reason}}` if directive returns `{ok: false, error}`
  - propagates any other directive_fn error tuple as-is
  """
  @spec handle(inbound(), keyword()) :: {:ok, envelope()} | {:error, term()}
  def handle(inbound, opts) do
    directive_fn = Keyword.fetch!(opts, :directive_fn)
    target = inbound.meta.target_plugin

    kind =
      try do
        String.to_existing_atom(inbound.msg_type)
      rescue
        ArgumentError -> :__unknown_kind__
      end

    cond do
      kind == :__unknown_kind__ ->
        {:error, :unsupported_kind}

      not PluginRegistry.supports?(target, :inbound, kind) ->
        {:error, :unsupported_kind}

      true ->
        invoke_download(inbound, directive_fn)
    end
  end

  defp invoke_download(inbound, directive_fn) do
    case directive_fn.("download_file", inbound.adapter_msg) do
      {:ok, %{"ok" => true, "result" => %{"uri" => uri}}} ->
        {:ok,
         %{
           msg_type: inbound.msg_type,
           content: uri,
           meta: inbound.meta
         }}

      {:ok, %{"ok" => false, "error" => err}} ->
        {:error, {:download_failed, err}}

      {:error, _} = err ->
        err

      other ->
        {:error, {:directive_unexpected_shape, other}}
    end
  end
end
