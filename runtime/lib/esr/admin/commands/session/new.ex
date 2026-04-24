defmodule Esr.Admin.Commands.Session.New do
  @moduledoc """
  `Esr.Admin.Commands.Session.New` — the consolidated agent-session
  command (spec D15 collapse). Creates an agent-backed Session under
  `Esr.SessionsSupervisor` from an `agents.yaml` definition.

  Dispatcher kind: `session_new`. The legacy branch-worktree command
  lives in `Esr.Admin.Commands.Session.BranchNew` (kind
  `session_branch_new`) after PR-3 P3-8.

  ## Flow

    1. Validate `args.agent` present (D11) and `args.dir` present (D13).
    2. Resolve the agent definition via `Esr.SessionRegistry.agent_def/1`.
    3. Batch-verify `capabilities_required` (D18) via
       `Esr.Capabilities.has_all?/2` — returns every missing cap at once
       so the operator can see the full gap in a single reply.
    4. Call `Esr.SessionsSupervisor.start_session/1` with the agent def
       encoded in `metadata.agent_def`.
    5. Return `{:ok, %{"session_id" => sid, "agent" => agent}}` on
       success, or a structured error otherwise.

  The `Grants.matches?/2` contract requires permissions in the canonical
  `prefix:name/perm` shape (see `docs/notes/capability-name-format-mismatch.md`);
  agents.yaml fixtures + spec examples were canonicalized in P3-8.4.

  PR-3 wires the real pipeline spawn via `SessionRouter.create_session/2`.
  In PR-2 the session start succeeds only when the agent_def has no
  pipeline peers that require missing modules (CCProcess/CCProxy/…);
  otherwise a controlled failure is expected (see P2-13).
  """

  @type result :: {:ok, map()} | {:error, map()}

  # Default start_session hook — injectable in tests via `execute/2 [start_session_fn: ...]`.
  # Mirrors the `spawn_fn` pattern in `Esr.Admin.Commands.RegisterAdapter.execute/2` so
  # tests can stub the supervisor call without actually spawning a Session tree.
  @default_start_session_fn &Esr.SessionsSupervisor.start_session/1

  @spec execute(map()) :: result()
  def execute(cmd), do: execute(cmd, [])

  @spec execute(map(), keyword()) :: result()
  def execute(%{"submitted_by" => submitter, "args" => args}, opts)
      when is_binary(submitter) and is_map(args) and is_list(opts) do
    agent = args["agent"]
    dir = args["dir"]
    # PR-8 T2: thread the originating Feishu chat through the supervisor call so
    # the session is registered under the real {chat_id, thread_id} key (not the
    # "pending" placeholder). Falls back to "pending" when args don't carry them
    # (e.g. `esr admin submit session_new --arg agent=... --arg dir=...`).
    chat_id = Map.get(args, "chat_id", "pending")
    thread_id = Map.get(args, "thread_id", "pending")
    start_session_fn = Keyword.get(opts, :start_session_fn, @default_start_session_fn)

    with :ok <- validate_args(agent, dir),
         {:ok, agent_def} <- fetch_agent(agent),
         :ok <- verify_caps(submitter, agent_def.capabilities_required),
         {:ok, sid} <-
           start_session(agent, agent_def, dir, submitter, chat_id, thread_id, start_session_fn) do
      {:ok, %{"session_id" => sid, "agent" => agent}}
    end
  end

  def execute(_, _opts),
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

  # Batch-verifies every permission in one shot via has_all?/2 so the
  # error payload enumerates the full gap (not just the first miss).
  # Returns the Session.New structured error shape, which SlashHandler's
  # format_result/1 clause for {:error, %{"type" => "missing_capabilities"}}
  # renders for the user.
  defp verify_caps(submitter, caps) when is_list(caps) do
    case Esr.Capabilities.has_all?(submitter, caps) do
      :ok ->
        :ok

      {:missing, missing} ->
        {:error, %{"type" => "missing_capabilities", "caps" => missing}}
    end
  end

  defp verify_caps(_submitter, _other), do: :ok

  defp start_session(agent, agent_def, dir, submitter, chat_id, thread_id, start_session_fn) do
    sid = :crypto.strong_rand_bytes(12) |> Base.encode32(padding: false)

    case start_session_fn.(%{
           session_id: sid,
           agent_name: agent,
           dir: dir,
           chat_thread_key: %{chat_id: chat_id, thread_id: thread_id},
           metadata: %{principal_id: submitter, agent_def: agent_def}
         }) do
      {:ok, _sup} -> {:ok, sid}
      {:error, reason} -> {:error, %{"type" => "session_start_failed", "details" => inspect(reason)}}
    end
  end
end
