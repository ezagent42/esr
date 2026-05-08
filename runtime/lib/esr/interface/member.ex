defmodule Esr.Interface.Member do
  @moduledoc """
  Scope-member contract per session.md §四 GroupChatSession + §五 User/Agent:

  > 成员实现 `MemberInterface` / `ChannelInterface` 等

  Every Entity that joins a Scope (User, Agent, Adapter, Handler)
  implements this Interface. Provides hooks for join/leave/mention/reply.

  Current implementers (post-R11): aspirational. Today's Entity
  modules don't have a unified Member API surface (User has
  IdentityInterface-like methods, Agent has AgentInterface-like
  methods). A future R-batch may normalize.

  See session.md §七 (MemberInterface).
  """

  @doc "Called when this Entity joins a Scope. `ctx` contains the Scope id + neighbor refs."
  @callback handle_join(ctx :: map(), state :: term()) :: {:ok, state :: term()} | {:error, term()}

  @doc "Called when this Entity is mentioned (e.g. `@member` in a message)."
  @callback handle_mention(envelope :: map(), state :: term()) :: {:ok, state :: term()}

  @doc "Called when this Entity replies into the Scope's channel."
  @callback handle_reply(envelope :: map(), state :: term()) :: {:ok, state :: term()}

  @doc "Called when this Entity leaves the Scope (gracefully or forcibly)."
  @callback handle_leave(reason :: term(), state :: term()) :: :ok
end
