defmodule Esr.Resource.Media.Inbound do
  @moduledoc """
  Orchestrates non-text inbound flow per spec
  `docs/superpowers/specs/2026-05-08-multimedia-content-protocol-design.md`
  §"Inbound flow":

    1. Capability check via `PluginRegistry.supports?(target, :inbound, kind)`
    2. Return a directive descriptor — caller emits `download_file` and
       resumes the flow asynchronously when the directive_ack arrives

  Pre-2026-05-09 this module took a `directive_fn` closure and blocked
  on a synchronous receive inside the caller's GenServer mailbox. That
  stalled the entire FeishuChatProxy mailbox for up to 30 s while
  waiting on Feishu's download. The function now returns a directive
  descriptor and lets the caller (FCP) own the async glue
  (`pending_media`, timeout timers, `handle_info({:directive_ack, ...})`).
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

  @type directive_ctx :: %{
          msg_type: String.t(),
          meta: map()
        }

  @doc """
  Capability-check a non-text inbound and return a directive descriptor
  the caller can dispatch on the source adapter.

  The `opts` keyword list is reserved for forward-compatible flags but
  is unused today — kept in the signature so call sites won't have to
  churn when (e.g.) phaser-selection options land.

  Returns:

    * `{:directive, action, args, ctx}` — capability check passed; caller
      should emit `action` (currently always `"download_file"`) with
      `args` on the source adapter, then resume on directive_ack arrival
      using `ctx` (a `%{msg_type, meta}` map) to build the downstream
      envelope.
    * `{:error, :unsupported_kind}` — target plugin does not declare the
      msg_type as a supported inbound kind. Caller is expected to emit a
      "media unsupported" DM via `Esr.Entity.CapGuard`.
  """
  @spec handle(inbound(), keyword()) ::
          {:directive, String.t(), map(), directive_ctx()}
          | {:error, :unsupported_kind}
  def handle(inbound, _opts \\ []) do
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
        {:directive, "download_file", inbound.adapter_msg,
         %{msg_type: inbound.msg_type, meta: inbound.meta}}
    end
  end
end
