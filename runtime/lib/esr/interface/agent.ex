defmodule Esr.Interface.Agent do
  @moduledoc """
  Agent contract per session.md §五 Agent:

  > 实现的 Interface:
  > - `MemberInterface` — 在 outer Scope 中作为 member
  > - `AgentInterface` — 处理 mention / reply 的 AI-specific 接口
  >   (如 think / plan / act)

  Current implementer (post-R11): aspirational. Today's CC (Claude
  Code) Agent is wired through `Esr.Entity.CCProcess` + `Esr.Entity.CCProxy`
  + `Esr.Entity.PtyProcess` collectively — no single module declares
  Agent contract. Future R-batch may consolidate when GroupChatScope
  + multi-Agent support land.

  See session.md §七 (AgentInterface).
  """

  @doc """
  Reason about an inbound message and decide what to do (think phase).
  Returns a plan that the runtime executes via subsequent calls.
  """
  @callback think(envelope :: map(), state :: term()) ::
              {:ok, plan :: term(), state :: term()} | {:error, term()}

  @doc "Construct a concrete action sequence from a plan."
  @callback plan(plan :: term(), state :: term()) ::
              {:ok, actions :: [term()], state :: term()}

  @doc "Execute a single action; emit any resulting envelopes via the agent's channels."
  @callback act(action :: term(), state :: term()) ::
              {:ok, state :: term()} | {:error, term()}
end
