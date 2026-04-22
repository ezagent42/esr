defmodule Esr.Admin.Commands.Session.AgentNew do
  @moduledoc """
  New admin command (PR-2): creates an agent-backed Session under
  `Esr.SessionsSupervisor`. Distinct from `Esr.Admin.Commands.Session.New`
  (which spawns a branch worktree — legacy; PR-3 collapses these into a
  single `session_new` with `agent` required).

  ## PR-2 scope

    1. Validate `args.agent` present (D11) and `args.dir` present (D13).
    2. Resolve the agent definition via `Esr.SessionRegistry.agent_def/1`.
    3. Verify `capabilities_required` (D18) via `Esr.Capabilities.has?/2`.
    4. Call `Esr.SessionsSupervisor.start_session/1` with the agent def
       encoded in `metadata.agent_def`.
    5. Return `{:ok, %{"session_id" => sid, "agent" => agent}}` on
       success, or a structured error otherwise.

  PR-3 wires the real pipeline spawn via `SessionRouter.create_session/2`.
  In PR-2 the session start succeeds only when the agent_def has no
  pipeline peers that require missing modules (CCProcess/CCProxy/…);
  otherwise a controlled failure is expected (see P2-13).
  """

  @type result :: {:ok, map()} | {:error, map()}

  @spec execute(map()) :: result()
  def execute(%{"submitted_by" => submitter, "args" => args})
      when is_binary(submitter) and is_map(args) do
    agent = args["agent"]
    dir = args["dir"]

    with :ok <- validate_args(agent, dir),
         {:ok, agent_def} <- fetch_agent(agent),
         :ok <- verify_caps(submitter, agent_def.capabilities_required),
         {:ok, sid} <- start_session(agent, agent_def, dir, submitter) do
      {:ok, %{"session_id" => sid, "agent" => agent}}
    end
  end

  def execute(_),
    do:
      {:error,
       %{"type" => "invalid_args", "message" => "submitted_by + args required"}}

  defp validate_args(nil, _),
    do: {:error, %{"type" => "invalid_args", "message" => "agent required"}}

  defp validate_args(_, nil),
    do: {:error, %{"type" => "invalid_args", "message" => "dir required"}}

  defp validate_args(_, _), do: :ok

  defp fetch_agent(name) do
    case Esr.SessionRegistry.agent_def(name) do
      {:ok, d} -> {:ok, d}
      {:error, :not_found} -> {:error, %{"type" => "unknown_agent", "agent" => name}}
    end
  end

  defp verify_caps(submitter, caps) when is_list(caps) do
    missing = for c <- caps, not Esr.Capabilities.has?(submitter, c), do: c
    if missing == [], do: :ok, else: {:error, %{"type" => "missing_capabilities", "caps" => missing}}
  end

  defp verify_caps(_submitter, _other), do: :ok

  defp start_session(agent, agent_def, dir, submitter) do
    sid = :crypto.strong_rand_bytes(12) |> Base.encode32(padding: false)

    case Esr.SessionsSupervisor.start_session(%{
           session_id: sid,
           agent_name: agent,
           dir: dir,
           chat_thread_key: %{chat_id: "pending", thread_id: "pending"},
           metadata: %{principal_id: submitter, agent_def: agent_def}
         }) do
      {:ok, _sup} -> {:ok, sid}
      {:error, reason} -> {:error, %{"type" => "session_start_failed", "details" => inspect(reason)}}
    end
  end
end
