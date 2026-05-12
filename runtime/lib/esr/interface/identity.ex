defmodule Esr.Interface.Identity do
  @moduledoc """
  Identity contract per session.md §五 User:

  > 实现的 Interface:
  > - `MemberInterface` — 加入 Scope 时
  > - `IdentityInterface` — username 唯一性、外部平台 ID 解析

  Current implementer (post-R11): aspirational. The user identity
  state (username + feishu_id binding) now lives in the URI store
  (`:esr_uri_store`); read via `Esr.Uri.Compat.*` wrappers or
  `Esr.Uri.get_entity/1` directly. Future R-batch may extract a
  proper `@behaviour` declaration.

  See session.md §七 (IdentityInterface).
  """

  @doc "Resolve a username (canonical id) from an external platform's id."
  @callback resolve_external(platform :: atom(), external_id :: String.t()) ::
              {:ok, username :: String.t()} | :error

  @doc "List the external platform bindings for a given username."
  @callback bindings(username :: String.t()) :: [{platform :: atom(), external_id :: String.t()}]
end
