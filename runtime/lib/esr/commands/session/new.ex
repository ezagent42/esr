defmodule Esr.Commands.Session.New do
  @moduledoc """
  `Esr.Commands.Session.New` — the consolidated agent-session
  command (spec D15 collapse). Creates an agent-backed Session from an
  `agents.yaml` definition.

  Dispatcher kind: `session_new`. The legacy branch-worktree command
  lives in `Esr.Commands.Session.BranchNew` (kind
  `session_branch_new`) after PR-3 P3-8.

  ## Flow

    1. Validate `args.agent` present (D11) and `args.dir` present (D13).
    2. Resolve the agent definition via `Esr.Entity.Agent.Registry.agent_def/1`.
    3. Batch-verify `capabilities_required` (D18) via
       `Esr.Resource.Capability.has_all?/2` — returns every missing cap at once
       so the operator can see the full gap in a single reply.
    4. Spawn the session. Two branches:
         * **chat_id + thread_id present** — delegate to
           `Esr.Session.Router.create_session/1`, which runs the full
           `pipeline.inbound` (FeishuChatProxy, CCProxy, CCProcess,
           PtyProcess, …), monitors each peer, and registers the
           session under the real `{chat_id, thread_id}` key with refs
           carrying every spawned peer pid. This is the path Feishu
           slash commands take.
         * **chat_id/thread_id absent (the "pending" placeholder)** —
           direct admin-CLI submits
           (`esr admin submit session_new --arg agent=... --arg dir=...`)
           have no chat binding. Calling Scope.Router here would register
           `{"pending","pending"}` in the ETS `:set` and clobber the slot
           for any real session that later uses the placeholder key.
           Fall through to `Esr.Session.Supervisor.start_session/1` (the
           legacy base subtree) and skip registry binding — no pipeline,
           no FeishuChatProxy, but also no registry pollution.
    5. Return `{:ok, %{"session_id" => sid, "agent" => agent}}` on
       success, or a structured error otherwise.

  The `Grants.matches?/2` contract requires permissions in the canonical
  `prefix:name/perm` shape (see `docs/notes/capability-name-format-mismatch.md`);
  agents.yaml fixtures + spec examples were canonicalized in P3-8.4.

  ## PR-8 T4 — Scope.Router rewire

  Prior to T4, Session.New called `Scope.Supervisor.start_session/1`
  unconditionally, which starts only the Scope.Process + empty peers
  DynamicSupervisor. Pipeline peers were never spawned, so
  `FeishuAppAdapter.handle_upstream/2`'s `%{feishu_chat_proxy: pid}`
  pattern missed and every inbound Feishu message after the first
  `/new-session` got silently dropped. T4 routes the chat-bound path
  through `Esr.Session.Router.create_session/1` to close that loop.
  """

  @behaviour Esr.Role.Control

  alias Esr.Resource.Session.Registry, as: SessionRegistry
  alias Esr.Session.ChatRouting.Registry, as: ChatScopeRegistry

  @type result :: {:ok, map()} | {:error, map()}

  # Default hooks — both injectable via `execute/2` opts. Tests stub
  # `create_session_fn` to avoid spawning the real pipeline, and
  # `start_session_fn` to cover the "pending" admin-CLI branch.
  @default_create_session_fn &Esr.Session.Router.create_session/1
  @default_start_session_fn &Esr.Session.Supervisor.start_session/1

  @spec execute(map()) :: result()
  def execute(cmd), do: execute(cmd, [])

  @spec execute(map(), keyword()) :: result()
  def execute(%{"submitted_by" => submitter, "args" => raw_args}, opts)
      when is_binary(submitter) and is_map(raw_args) and is_list(opts) do
    # Phase 5.1/5.3: resolve workspace via 3-step fallback chain before
    # downstream processing. Short-circuits when:
    #   (a) workspace is already explicit in args, OR
    #   (b) agent is explicitly given (legacy "no workspace, agent-only" mode)
    # so existing admin-CLI tests that provide an agent without a workspace
    # continue to work unchanged.
    case resolve_workspace_if_needed(raw_args) do
      {:error, err} ->
        {:error, err}

      res ->
        args =
          case res do
            {:ok, resolved_name} -> Map.put(raw_args, "workspace", resolved_name)
            :no_resolution_needed -> raw_args
          end

        # PR-21g grammar accommodation: `cwd` (PR-21d slash) is accepted as
        # alias for `dir` (legacy / admin-CLI). When `workspace` is provided
        # without an explicit `agent`, default to "cc" — the only agent
        # currently registered in agents.yaml.
        agent = args["agent"] || (if args["workspace"], do: "cc", else: nil)
        dir = args["dir"] || args["cwd"]

        # PR-8 T2 / PR-21λ: thread the originating Feishu chat through so the
        # session is registered under the chat-current `(chat_id, app_id)`
        # slot. Falls back to "pending" when args don't carry chat_id (direct
        # admin CLI submits) — those bypass Scope.Router and so never touch
        # the registry's chat slot. `thread_id` is still propagated downstream
        # for Feishu reply rendering, but is no longer part of the routing key.
        #
        # PR-21λ-fix 2026-05-01: `app_id` was previously dropped on the floor
        # here — Session.New extracted only chat_id + thread_id, then the
        # Scope.Router `register/3` fallback pinned every chat-bound session
        # to `app_id = "default"`. Inbound messages (which carry the real
        # adapter instance id, e.g. `"esr_dev_helper"`) then lookup
        # `(chat_id, "esr_dev_helper")` and miss every time. Read app_id
        # explicitly so the registration key matches the lookup key.
        chat_id = Map.get(args, "chat_id", "pending")
        thread_id = Map.get(args, "thread_id", "")
        app_id = Map.get(args, "app_id", "pending")
        create_session_fn = Keyword.get(opts, :create_session_fn, @default_create_session_fn)
        start_session_fn = Keyword.get(opts, :start_session_fn, @default_start_session_fn)

        with :ok <- validate_args(agent, dir),
             {:ok, agent_def} <- fetch_agent(agent),
             :ok <- verify_caps(submitter, agent_def.capabilities_required),
             :ok <- check_name_unique(submitter, args["name"]),
             :ok <- maybe_create_worktree(args),
             {:ok, sid} <-
               spawn_session(
                 agent,
                 agent_def,
                 dir,
                 submitter,
                 chat_id,
                 thread_id,
                 app_id,
                 create_session_fn,
                 start_session_fn
               ),
             :ok <- maybe_claim_uri(args, sid),
             :ok <- bind_session_to_workspace(args, sid),
             :ok <- persist_session_record(args, sid, submitter, agent),
             :ok <- maybe_attach_chat(chat_id, app_id, sid) do
          # M-5 / spec §4.6: surface the resolved workspace name so the
          # operator can see which fallback layer the chain hit. nil when
          # `agent`-only legacy short-circuit was taken (no workspace).
          base = %{"session_id" => sid, "agent" => agent}

          {:ok,
           case args["workspace"] do
             ws when is_binary(ws) and ws != "" -> Map.put(base, "workspace", ws)
             _ -> base
           end}
        end
    end
  end

  # PR-22 (2026-04-29): when args carry `root` + `cwd` + `worktree`,
  # create the git worktree before spawning the CC session. `root` is
  # the git repo to fork from (per-session arg as of PR-22, was
  # workspace.root pre-PR-22). When any of the three are absent, skip
  # silently — operator may be running a workspace-only session
  # without git isolation (legacy support for tests / direct admin
  # CLI).
  defp maybe_create_worktree(%{"root" => root, "cwd" => cwd, "worktree" => branch})
       when is_binary(root) and root != "" and is_binary(cwd) and cwd != "" and
              is_binary(branch) and branch != "" do
    case Esr.Worktree.add(root, branch, cwd) do
      :ok ->
        :ok

      {:error, {:already_exists, _path}} ->
        # The worktree path already exists. Two interpretations:
        # (a) operator pointed at an existing checkout intentionally
        #     (e.g., session reuse) — proceed without re-running git
        # (b) collision with another session's worktree — would have
        #     been caught by Esr.Resource.ChatScope.Registry.claim_uri post-spawn
        # Treating as (a) here; (b) is the URI-uniqueness gate's job.
        require Logger
        Logger.info("session_new: cwd #{cwd} already exists, treating as reuse")
        :ok

      {:error, {:git_failed, code, output}} ->
        {:error,
         %{
           "type" => "worktree_failed",
           "details" => "git worktree add failed (exit #{code}): #{output}",
           "root" => root,
           "branch" => branch,
           "cwd" => cwd
         }}

      {:error, reason} ->
        {:error, %{"type" => "worktree_failed", "details" => inspect(reason)}}
    end
  end

  defp maybe_create_worktree(_args), do: :ok

  # PR-21g: if the slash command threaded URI components (name +
  # username + workspace + worktree), claim them in
  # Esr.Resource.ChatScope.Registry against the freshly-spawned sid.
  # Collisions roll back the spawn so the pair (Registry, supervisor
  # tree) stays consistent.
  defp maybe_claim_uri(%{"name" => name, "username" => u, "workspace" => ws, "worktree" => wt} = _args, sid)
       when is_binary(name) and name != "" and is_binary(u) and u != "" and
              is_binary(ws) and ws != "" and is_binary(wt) and wt != "" do
    env = Esr.Paths.current_instance()

    case Esr.Session.NameIndex.Registry.claim_uri(sid, %{
           env: env,
           username: u,
           workspace: ws,
           name: name,
           worktree_branch: wt
         }) do
      :ok ->
        :ok

      {:error, {:name_taken, _other_sid}} = err ->
        rollback_spawn(sid)

        {:error,
         %{
           "type" => "name_collision",
           "name" => name,
           "username" => u,
           "workspace" => ws,
           "details" => "another live session already uses this name"
         }}
        |> tap(fn _ -> _ = err end)

      {:error, {:worktree_taken, _other_sid}} = err ->
        rollback_spawn(sid)

        {:error,
         %{
           "type" => "worktree_collision",
           "worktree" => wt,
           "username" => u,
           "workspace" => ws,
           "details" => "another live session already uses this worktree branch"
         }}
        |> tap(fn _ -> _ = err end)

      {:error, _other} = err ->
        rollback_spawn(sid)
        err
    end
  end

  defp maybe_claim_uri(_args, _sid), do: :ok

  defp rollback_spawn(sid) do
    _ = Esr.Session.Router.end_session(sid)
    :ok
  end

  # Spec D6: session names are unique within `(owner_user, name)`.
  # When the submitter passes args.name, check the Session.Registry's
  # `:esr_resource_session_name_index` ETS table BEFORE spawning so the
  # error path doesn't have to roll back a half-built supervisor tree.
  # Skipped when name is absent — Session.New is also reachable from
  # admin-CLI / new_chat_thread auto-spawn paths that don't set a name.
  defp check_name_unique(_owner_user, name) when name in [nil, ""], do: :ok

  defp check_name_unique(owner_user, name) when is_binary(owner_user) and is_binary(name) do
    case :ets.lookup(:esr_resource_session_name_index, {owner_user, name}) do
      [] ->
        :ok

      [{_, _existing_uuid}] ->
        {:error,
         %{
           "type" => "session_name_taken",
           "message" =>
             "a session named '#{name}' already exists for owner '#{owner_user}'"
         }}
    end
  rescue
    # ETS table not running (test env without Session.Registry boot).
    ArgumentError -> :ok
  end

  defp check_name_unique(_owner, _name), do: :ok

  # Persist the session record on disk (`<data_dir>/sessions/<sid>/session.json`)
  # and register it in the in-memory Session.Registry. Pinned to the spawn's
  # sid via the `:session_id` attr (registry then skips its own UUID minting).
  # On write failure, roll back the spawned supervisor so the on-disk view
  # and the live process tree stay consistent.
  defp persist_session_record(args, sid, submitter, agent) do
    name = Map.get(args, "name", "")
    workspace_id = Map.get(args, "workspace_id", "")
    data_dir = Esr.Paths.runtime_home()

    attrs = %{
      session_id: sid,
      name: name,
      owner_user: submitter,
      workspace_id: workspace_id,
      agent: agent
    }

    case safe_create_session(data_dir, attrs) do
      :ok ->
        :ok

      {:ok, _uuid} ->
        :ok

      {:error, reason} ->
        rollback_spawn(sid)

        {:error,
         %{
           "type" => "session_persist_failed",
           "message" => "failed to write session.json for #{sid}",
           "details" => inspect(reason)
         }}
    end
  end

  # Wrap the GenServer call so a missing Session.Registry (test env that
  # never started the singleton) degrades to a silent skip rather than an
  # exit. Production always has the registry under Esr.Application.
  defp safe_create_session(data_dir, attrs) do
    case Process.whereis(SessionRegistry) do
      nil -> :ok
      _pid -> SessionRegistry.create_session(data_dir, attrs)
    end
  rescue
    ArgumentError -> :ok
  end

  # When the submitter threads chat context, ensure the freshly-spawned
  # sid is recorded as the chat's current session. Two cases:
  #
  #   (a) Real chat-bound spawn: `spawn_session` delegated to
  #       `Esr.Session.Router.create_session/1`, which already calls
  #       `Esr.Resource.ChatScope.Registry.register_session/3` with peer
  #       refs (FeishuChatProxy pid + co.). Re-running `attach_session`
  #       here would overwrite that 3-tuple entry with the 2-tuple
  #       attach-shape and silently drop the refs — every inbound
  #       message after that would miss `%{feishu_chat_proxy: pid}`.
  #       So skip when the slot already carries this sid.
  #
  #   (b) Test stub or admin-CLI fallback: `create_session_fn` was
  #       stubbed to return `{:ok, sid}` without touching
  #       ChatScope.Registry. Then no slot exists yet, and the explicit
  #       `attach_session` is what binds the chat — exactly the
  #       semantic the legacy 103-LOC `/session:new` provided.
  defp maybe_attach_chat(chat_id, app_id, sid)
       when is_binary(chat_id) and chat_id != "" and chat_id != "pending" and
              is_binary(app_id) and app_id != "" and app_id != "pending" and
              is_binary(sid) do
    case slot_already_bound?(chat_id, app_id, sid) do
      true ->
        :ok

      false ->
        _ = ChatScopeRegistry.attach_session(chat_id, app_id, sid)
        :ok
    end
  rescue
    # ChatScope.Registry not running in some narrow test paths.
    ArgumentError -> :ok
  end

  defp maybe_attach_chat(_chat_id, _app_id, _sid), do: :ok

  defp slot_already_bound?(chat_id, app_id, sid) do
    # Cleanup-PR commit 3b: ETS table moved from :esr_chat_scope_chat_index
    # (legacy ChatScope.Registry) to :esr_session_chat_routing
    # (Esr.Session.ChatRouting.Registry). Same two-shape coexistence rules.
    case :ets.lookup(:esr_session_chat_routing, {chat_id, app_id}) do
      # Old shape (register_session/3): {key, sid, refs}
      [{_k, ^sid, _refs}] -> true
      # New shape (attach/detach): {key, %{current: sid, ...}}
      [{_k, %{current: ^sid}}] -> true
      _ -> false
    end
  rescue
    ArgumentError -> false
  end

  defp bind_session_to_workspace(%{"workspace" => ws_name}, sid)
       when is_binary(ws_name) and ws_name != "" do
    case Esr.Resource.Workspace.NameIndex.id_for_name(:esr_workspace_name_index, ws_name) do
      {:ok, ws_id} ->
        case Esr.Resource.Workspace.Registry.bind_session(ws_id, sid) do
          :ok ->
            :ok

          {:error, :workspace_gone} ->
            rollback_spawn(sid)

            {:error,
             %{
               "type" => "workspace_gone",
               "message" => "workspace was deleted while session was being created"
             }}
        end

      :not_found ->
        # Distinguish two cases:
        #   (a) Registry not running → test env; silent skip is correct.
        #   (b) Registry running but workspace was deleted between
        #       resolve_workspace_if_needed/1 and here (race window with
        #       a concurrent transient cleanup). Roll back the spawn and
        #       surface the structured error so the operator's intent
        #       isn't silently lost.
        if Process.whereis(Esr.Resource.Workspace.Registry) == nil do
          :ok
        else
          rollback_spawn(sid)

          {:error,
           %{
             "type" => "workspace_gone",
             "name" => ws_name,
             "message" =>
               "workspace was deleted between resolution and session bind (race with transient cleanup)"
           }}
        end
    end
  rescue
    ArgumentError -> :ok
  end

  defp bind_session_to_workspace(_args, _sid), do: :ok

  def execute(_, _opts),
    do:
      {:error,
       %{"type" => "invalid_args", "message" => "submitted_by + args required"}}

  # ---------------------------------------------------------------------------
  # Phase 5.1 / 5.3 + Phase 6 (M-5) — workspace resolution
  #
  # The chain itself lives in `Esr.Commands.Workspace.Resolve` (shared
  # with /workspace:add-folder); this thin wrapper preserves Scope.New's
  # short-circuits (explicit workspace, legacy agent-only mode) and
  # re-shapes the {:no_match} terminal into the structured error map
  # that downstream slash plumbing already knows how to render.
  #
  # Exposed as a public function (@doc false) so tests can exercise the
  # resolution logic directly without setting up the full session machinery.
  # ---------------------------------------------------------------------------

  @doc false
  def resolve_workspace_if_needed(args) do
    cond do
      # (a) workspace explicitly given — nothing to do
      is_binary(args["workspace"]) and args["workspace"] != "" ->
        :no_resolution_needed

      # (b) agent explicitly given — legacy "no workspace, agent-only" mode
      #     (admin-CLI tests, direct agent spawns without a workspace context)
      is_binary(args["agent"]) and args["agent"] != "" ->
        :no_resolution_needed

      # (c) neither: walk the M-5 fallback chain via the shared Resolve helper
      true ->
        case Esr.Commands.Workspace.Resolve.resolve_workspace_for_args(args) do
          {:explicit, name} -> {:ok, name}
          {:chat_default, name} -> {:ok, name}
          {:user_default, name} -> {:ok, name}

          :no_match ->
            {:error,
             %{
               "type" => "no_workspace_resolvable",
               "message" =>
                 "workspace not specified, no chat-default set, and " <>
                   "submitter has no user-default. Run `/user:use workspace=<name>` " <>
                   "to set one, or pass `workspace=<name>` explicitly."
             }}
        end
    end
  end

  defp validate_args(nil, _),
    do: {:error, %{"type" => "invalid_args", "message" => "agent required"}}

  defp validate_args(_, nil),
    do: {:error, %{"type" => "invalid_args", "message" => "dir required"}}

  defp validate_args(_, _), do: :ok

  defp fetch_agent(name) do
    case Esr.Entity.Agent.Registry.agent_def(name) do
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
    case Esr.Resource.Capability.has_all?(submitter, caps) do
      :ok ->
        :ok

      {:missing, missing} ->
        {:error, %{"type" => "missing_capabilities", "caps" => missing}}
    end
  end

  defp verify_caps(_submitter, _other), do: :ok

  # Chat-bound path (the Feishu slash command path): delegate to
  # Scope.Router so the full agents.yaml pipeline spawns. Scope.Router
  # also does its own `register_session/3` internally, so we don't
  # re-register here.
  defp spawn_session(
         agent,
         agent_def,
         dir,
         submitter,
         chat_id,
         thread_id,
         app_id,
         create_session_fn,
         _start_session_fn
       )
       when chat_id != "pending" do
    params = %{
      agent: agent,
      dir: dir,
      principal_id: submitter,
      chat_id: chat_id,
      thread_id: thread_id,
      # PR-21λ-fix: thread app_id so Scope.Router registers under the
      # adapter instance id that inbound messages will look up with.
      app_id: app_id,
      # agent_def is redundant — Scope.Router re-resolves — but keeping
      # the reference here means call-site readers don't need to jump
      # two files to see what agent this maps to.
      agent_def: agent_def
    }

    case create_session_fn.(params) do
      {:ok, sid} when is_binary(sid) ->
        {:ok, sid}

      {:error, reason} ->
        {:error, %{"type" => "session_start_failed", "details" => inspect(reason)}}
    end
  end

  # Direct admin-CLI submit path: no chat context, so Scope.Router's
  # register_session call would clobber the "pending" placeholder slot.
  # Take the legacy Scope.Supervisor route — starts the Scope.Process
  # base subtree only (no pipeline peers), skips registry binding.
  defp spawn_session(
         agent,
         agent_def,
         dir,
         submitter,
         chat_id,
         _thread_id,
         _app_id,
         _create_session_fn,
         start_session_fn
       ) do
    sid = :crypto.strong_rand_bytes(12) |> Base.encode32(padding: false)
    # PR-A T1 / PR-21λ: legacy admin-CLI submit path has no chat context
    # — the placeholders persist and `app_id` mirrors `chat_id` so the
    # routing key is well-formed if/when this path later registers.
    key = %{chat_id: chat_id, app_id: chat_id}

    case start_session_fn.(%{
           session_id: sid,
           agent_name: agent,
           dir: dir,
           chat_thread_key: key,
           metadata: %{principal_id: submitter, agent_def: agent_def}
         }) do
      {:ok, _sup} ->
        {:ok, sid}

      {:error, reason} ->
        {:error, %{"type" => "session_start_failed", "details" => inspect(reason)}}
    end
  end
end
