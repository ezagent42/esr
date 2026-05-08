defmodule Esr.Commands.Pty.List do
  @moduledoc """
  `/pty:list` — list PTY actor ids for agents in chat-current session.
  Spec rev-4 §4.2 row `/pty:list`. Phase E task E.1.

  Returns one row per agent that has a `pty` actor_id, carrying:
    * `agent_name` — the operator-facing name (alice / bob / …)
    * `agent_type` — plugin-declared type (cc / …)
    * `pty_actor_id` — the UUID PtyProcess registers under (`pty:<id>`).

  Resolves chat context via `Esr.Session.ChatRouting.Registry` —
  matches the routing semantics of `/agent:list` and the rest of the
  chat-bound family. No PtyProcess gymnastics: each %Instance{} carries
  its `actor_ids` map (Phase A.3) so this is a pure ETS read.
  """

  @behaviour Esr.Role.Control

  alias Esr.Session.ChatRouting.Registry, as: ChatRouting

  @spec execute(map()) :: {:ok, map()} | {:error, map()}
  def execute(%{
        "submitted_by" => _submitter,
        "args" => %{"chat_id" => chat_id, "app_id" => app_id}
      })
      when is_binary(chat_id) and chat_id != "" and is_binary(app_id) and app_id != "" do
    case ChatRouting.current_session(chat_id, app_id) do
      {:ok, sid} ->
        ptys =
          sid
          |> Esr.Entity.Agent.InstanceRegistry.list()
          |> Enum.map(fn inst ->
            %{
              "agent_name" => inst.name,
              "agent_type" => inst.type,
              "pty_actor_id" => get_in(inst.actor_ids || %{}, [:pty])
            }
          end)
          |> Enum.filter(& &1["pty_actor_id"])

        {:ok, %{"chat_id" => chat_id, "session_id" => sid, "ptys" => ptys}}

      :not_found ->
        {:ok, %{"chat_id" => chat_id, "session_id" => nil, "ptys" => []}}
    end
  end

  def execute(_cmd) do
    {:error,
     %{"type" => "invalid_args", "message" => "/pty:list requires chat context"}}
  end
end
