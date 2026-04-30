defmodule Esr.Peers.SlashHandler do
  @moduledoc """
  Channel-agnostic slash-command peer. AdminSession-scope (exactly one,
  registered under `:slash_handler` in `Esr.AdminSessionProcess`).

  On `:slash_cmd` from any ChatProxy: parse the command, cast to
  `Esr.Admin.Dispatcher` with a correlation ref, and relay the reply
  back to the originating ChatProxy as `{:reply, text}`.

  Replaces the slash-parsing half of the legacy
  `Esr.Routing.SlashHandler` (deleted in PR-3 P3-14). Post-P2-17, Feishu
  slash commands route through here unconditionally.

  Parser enforces spec D11 (`--agent` required on `/new-session`) and
  D13 (`--dir` required) — both are required per the decision-index
  definition in
  `docs/superpowers/specs/2026-04-22-peer-session-refactor-design.md`.

  Emits admin command kind `session_new` (agent-session create). PR-3
  P3-8 collapsed the legacy `session_new` (branch-worktree) into
  `session_branch_new` and promoted the former `session_agent_new` to
  `session_new`.

  Spec §4.1 SlashHandler card, §5.3, §1.8 D14.
  """

  @behaviour Esr.Role.Pipeline
  use Esr.Peer.Stateful
  use GenServer
  require Logger

  @default_dispatcher Esr.Admin.Dispatcher

  # start_link/1 inherits the dual-shape (map | keyword) default from
  # Esr.Peer.Stateful (PR-6 B1). All current callers pass %{}.

  @impl GenServer
  def init(args) do
    :ok = Esr.AdminSessionProcess.register_admin_peer(:slash_handler, self())

    state = %{
      dispatcher: Map.get(args, :dispatcher, @default_dispatcher),
      session_id: Map.fetch!(args, :session_id),
      # ref -> reply_to_proxy pid
      pending: %{}
    }

    {:ok, state}
  end

  # handle_upstream/2 and handle_downstream/2 inherit the no-op
  # `{:forward, [], state}` defaults from Esr.Peer.Stateful (PR-6 B1).
  # SlashHandler never participates in the chain: it's a sink for
  # `:slash_cmd` handle_info messages from FeishuChatProxy.

  @impl GenServer
  def handle_info({:slash_cmd, envelope, reply_to_proxy}, state) do
    text = get_in(envelope, ["payload", "text"]) || ""
    principal_id = envelope["principal_id"] || "ou_unknown"

    case parse_command(text) do
      {:ok, kind, args} ->
        ref = make_ref()
        # PR-8 T2: thread chat_id + thread_id from the Feishu envelope into
        # the args dict so Session.New can bind the session to the real
        # {chat_id, thread_id} key in SessionRegistry. Only merged when
        # present — direct admin-CLI submits (no chat context) keep working.
        args = merge_chat_context(args, kind, envelope)

        cmd = %{
          "id" => generate_id(),
          "kind" => kind,
          "submitted_by" => principal_id,
          "args" => args
        }

        GenServer.cast(
          state.dispatcher,
          {:execute, cmd, {:reply_to, {:pid, self(), ref}}}
        )

        {:noreply, put_in(state.pending[ref], reply_to_proxy)}

      {:error, reason} ->
        send(reply_to_proxy, {:reply, "unknown command: #{reason}"})
        {:noreply, state}
    end
  end

  def handle_info({:command_result, ref, result}, state) when is_reference(ref) do
    case Map.pop(state.pending, ref) do
      {nil, _} ->
        Logger.warning(
          "slash_handler: unknown command_result ref #{inspect(ref)}"
        )

        {:noreply, state}

      {reply_to_proxy, rest} ->
        send(reply_to_proxy, {:reply, format_result(result)})
        {:noreply, %{state | pending: rest}}
    end
  end

  def handle_info(_other, state), do: {:noreply, state}

  # session_new needs chat_thread_key threading + (PR-21g) username
  # resolution from envelope.user_id via Esr.Users.Registry. session_end
  # also needs username when args carries `name=` (PR-21g resolver).
  defp merge_chat_context(args, kind, envelope) when kind in ["session_new", "session_end"] do
    chat_id = get_in(envelope, ["payload", "chat_id"])
    thread_id = get_in(envelope, ["payload", "thread_id"])
    username = resolve_username(envelope)

    args
    |> maybe_put("chat_id", chat_id)
    |> maybe_put("thread_id", thread_id)
    |> maybe_put("username", username)
  end

  # PR-21j: session_list (when called with workspace=) and workspace_info
  # need both `username` (URI uniqueness scoping) and `workspace`
  # (defaults to the chat's bound workspace when absent from args).
  defp merge_chat_context(args, kind, envelope) when kind in ["session_list", "workspace_info"] do
    chat_id = get_in(envelope, ["payload", "chat_id"])
    app_id = get_in(envelope, ["payload", "args", "app_id"])
    username = resolve_username(envelope)

    args =
      args
      |> maybe_put("chat_id", chat_id)
      |> maybe_put("username", username)

    # If args don't already carry workspace, look it up from the chat
    # binding. Falls back to nil → Session.List runs in legacy mode
    # (routing.yaml summary); Workspace.Info errors with invalid_args.
    if Map.get(args, "workspace") in [nil, ""] do
      maybe_put(args, "workspace", resolve_workspace(chat_id, app_id))
    else
      args
    end
  end

  # PR-21k: workspace_new threads chat_id + app_id (for auto-binding
  # the new workspace to this chat) + username (for owner default).
  defp merge_chat_context(args, "workspace_new", envelope) do
    chat_id = get_in(envelope, ["payload", "chat_id"])
    app_id = get_in(envelope, ["payload", "args", "app_id"])
    username = resolve_username(envelope)

    args
    |> maybe_put("chat_id", chat_id)
    |> maybe_put("app_id", app_id)
    |> maybe_put("username", username)
  end

  defp merge_chat_context(args, _kind, _envelope), do: args

  # Resolve the workspace name a chat is bound to. Returns nil when no
  # binding (caller decides whether that's an error).
  defp resolve_workspace(chat_id, app_id)
       when is_binary(chat_id) and chat_id != "" and is_binary(app_id) and app_id != "" do
    case Esr.Workspaces.Registry.workspace_for_chat(chat_id, app_id) do
      {:ok, ws} -> ws
      :not_found -> nil
    end
  end

  defp resolve_workspace(_chat_id, _app_id), do: nil

  defp resolve_username(envelope) do
    open_id = envelope["user_id"] || get_in(envelope, ["payload", "user_id"])

    cond do
      not is_binary(open_id) or open_id == "" ->
        nil

      Process.whereis(Esr.Users.Registry) == nil ->
        nil

      true ->
        case Esr.Users.Registry.lookup_by_feishu_id(open_id) do
          {:ok, username} -> username
          :not_found -> nil
        end
    end
  end

  defp maybe_put(map, _k, nil), do: map
  defp maybe_put(map, k, v), do: Map.put(map, k, v)

  # --------------------------------------------------------------------
  # Parser — PR-21d unified grammar (D14):
  #   /new-session <workspace> name=<…> cwd=<…> worktree=<…>
  #   /end-session <name>
  #   /list-sessions | /sessions
  #   /list-agents
  #
  # `--agent <…>` / `--dir <…>` (the pre-PR-21d Elixir-only form) are
  # rejected with a hint pointing at the new grammar. `tag=<…>` was
  # accepted as an alias for `name=<…>` during the PR-21d rollout window
  # — removed in PR-21 tag-alias-removal (no callers remained).
  #
  # Cap check is the Dispatcher's job, not SlashHandler's.
  # --------------------------------------------------------------------

  defp parse_command(text) do
    case String.split(text, " ", parts: 2) do
      ["/new-session", rest] -> parse_new_session(rest)
      ["/new-session"] ->
        {:error, "/new-session requires <workspace> and name= root= cwd= worktree=, e.g. " <>
                   "/new-session esr-dev name=foo root=/path/to/repo cwd=/path/to/wt worktree=foo"}
      ["/end-session", rest] -> parse_end_session(rest)
      ["/end-session"] -> {:error, "/end-session requires <name>"}
      # PR-21k + PR-22: create a workspace from inside Feishu chat.
      # Auto-binds this chat to the new workspace's chats: list. owner
      # defaults to the resolved esr user (envelope.user_id →
      # users.yaml). PR-22 (2026-04-29): `root=` arg removed —
      # workspace no longer carries a repo identity.
      ["/new-workspace", rest] -> parse_new_workspace(rest)
      ["/new-workspace"] ->
        {:error,
         "/new-workspace requires <name>, e.g. /new-workspace my-ws"}
      # PR-21j: `/sessions` and `/list-sessions` lift the empty-args
      # default — SlashHandler's merge_chat_context resolves the chat's
      # workspace and Session.List uses it to filter by the URI tuple.
      ["/list-sessions"] -> {:ok, "session_list", %{}}
      ["/sessions"] -> {:ok, "session_list", %{}}
      ["/list-agents"] -> {:ok, "agent_list", %{}}
      # PR-21j workspace group ops:
      #   /workspace info             — show current workspace config
      #   /workspace sessions         — explicit form of /sessions
      #   /workspace info <name>      — show named workspace
      ["/workspace", rest] -> parse_workspace(rest)
      ["/workspace"] -> {:error, "/workspace requires a sub-command (info | sessions)"}
      _ -> {:error, inspect(String.slice(text, 0, 32))}
    end
  end

  defp parse_new_workspace(rest) do
    toks = tokenize(rest)

    case toks do
      [name | kvs] ->
        kv = parse_kv_pairs(kvs)

        cond do
          name == "" ->
            {:error, "/new-workspace requires <name> as first arg"}

          true ->
            # PR-22 (2026-04-29): `root=` no longer accepted — workspace
            # has no repo identity. Per-session `root=` (in /new-session)
            # is the new home.
            args =
              %{"name" => name}
              |> maybe_put("role", kv["role"])
              |> maybe_put("start_cmd", kv["start_cmd"])
              |> maybe_put("owner", kv["owner"])

            {:ok, "workspace_new", args}
        end

      [] ->
        {:error, "/new-workspace requires <name>"}
    end
  end

  defp parse_workspace(rest) do
    case tokenize(rest) do
      ["info"] -> {:ok, "workspace_info", %{}}
      ["info", name | _] -> {:ok, "workspace_info", %{"workspace" => name}}
      ["sessions"] -> {:ok, "session_list", %{}}
      ["sessions", name | _] -> {:ok, "session_list", %{"workspace" => name}}
      [other | _] -> {:error, "/workspace #{inspect(other)}: unknown sub-command (try info | sessions)"}
      [] -> {:error, "/workspace requires a sub-command (info | sessions)"}
    end
  end

  defp parse_end_session(rest) do
    case tokenize(rest) do
      [name | kvs] when is_binary(name) ->
        # PR-22: optional root= + cwd= args let Session.End prune the
        # worktree post-teardown without re-querying state. The most
        # common form remains bare `/end-session foo` — Session.End
        # then skips the worktree-prune step (operator can clean up
        # via git CLI later).
        kv = parse_kv_pairs(kvs)

        args =
          %{"session_id" => name, "name" => name}
          |> maybe_put("root", kv["root"])
          |> maybe_put("cwd", kv["cwd"])

        {:ok, "session_end", args}

      [] ->
        {:error, "/end-session requires <name>"}
    end
  end

  defp parse_new_session(rest) do
    toks = tokenize(rest)

    if has_legacy_flags?(toks) do
      {:error,
       "/new-session: --agent / --dir are removed (PR-21d). Use " <>
         "/new-session <workspace> name=<…> cwd=<…> worktree=<…>"}
    else
      [workspace | kvs] = toks ++ [""]
      kv = parse_kv_pairs(kvs)

      cond do
        workspace == "" ->
          {:error, "/new-session requires <workspace> as first arg"}

        is_nil(kv["name"]) ->
          {:error, "/new-session requires name=<…>"}

        true ->
          name = kv["name"]

          # PR-22: thread per-session `root=` (the git repo to fork
          # worktree from) into args. Optional in the parser — Session.New
          # rejects with a clear error if absent AND worktree= was given
          # (i.e., spawn would need git access). Sessions without
          # worktree= can still spawn without root=, just no worktree fork.
          args =
            %{"workspace" => workspace, "name" => name}
            |> maybe_put("root", kv["root"])
            |> maybe_put("cwd", kv["cwd"])
            |> maybe_put("worktree", kv["worktree"])

          {:ok, "session_new", args}
      end
    end
  end

  defp has_legacy_flags?(toks),
    do: Enum.any?(toks, &(&1 in ["--agent", "--dir"]))

  defp parse_kv_pairs(toks) do
    toks
    |> Enum.reduce(%{}, fn tok, acc ->
      case String.split(tok, "=", parts: 2) do
        [k, v] when k != "" -> Map.put(acc, k, v)
        _ -> acc
      end
    end)
  end

  defp tokenize(rest),
    do: rest |> String.trim() |> String.split(~r/\s+/, trim: true)

  # --------------------------------------------------------------------
  # Result formatting — human-readable text for the ChatProxy reply.
  # --------------------------------------------------------------------

  # PR-21j: session_list workspace-scoped result.
  defp format_result({:ok, %{"workspace" => ws, "sessions" => sessions}})
       when is_list(sessions) do
    if sessions == [] do
      "workspace #{ws}: no live sessions"
    else
      lines =
        sessions
        |> Enum.map(fn %{"name" => n, "session_id" => sid} -> "  • #{n} (sid=#{sid})" end)
        |> Enum.join("\n")

      "workspace #{ws} sessions (#{length(sessions)}):\n#{lines}"
    end
  end

  # PR-21k: workspace_new result.
  defp format_result({:ok, %{"name" => name, "owner" => owner, "root" => root, "chats" => chats}})
       when is_list(chats) do
    chat_summary =
      case chats do
        [] -> "(no chat bindings)"
        list -> "#{length(list)} chat(s) bound"
      end

    "workspace #{name} created (owner=#{owner}, root=#{root}, #{chat_summary}). " <>
      "Now: /new-session #{name} name=<…> cwd=<…> worktree=<…>"
  end

  # PR-21j: workspace_info result.
  defp format_result({:ok, %{"name" => name, "owner" => owner, "root" => root} = ws}) do
    chats =
      (Map.get(ws, "chats") || [])
      |> Enum.map(fn c ->
        "  • #{Map.get(c, "chat_id", "?")} @ #{Map.get(c, "app_id", "?")}"
      end)
      |> case do
        [] -> "  (no chat bindings)"
        list -> Enum.join(list, "\n")
      end

    role = Map.get(ws, "role", "-")
    metadata_keys = (Map.get(ws, "metadata") || %{}) |> Map.keys() |> Enum.join(", ")

    """
    workspace #{name}:
      owner: #{owner || "-"}
      root:  #{root || "-"}
      role:  #{role}
      chats:
    #{chats}
      metadata keys: #{metadata_keys}
    """
    |> String.trim()
  end

  defp format_result({:ok, %{"branches" => b}}) when is_list(b),
    do: "sessions: " <> Enum.join(b, ", ")

  defp format_result({:ok, %{"session_id" => sid}}),
    do: "session started: #{sid}"

  defp format_result({:ok, %{} = m}), do: "ok: " <> inspect(m)

  # P3-8: Session.New emits string "missing_capabilities" (not atom); match
  # accordingly. Pre-P3-8 the clause matched :missing_capabilities and never
  # fired (see integration/new_session_smoke_test.exs module doc).
  defp format_result({:error, %{"type" => "missing_capabilities", "caps" => caps}}),
    do: "error: missing caps — " <> Enum.join(caps, ", ")

  defp format_result({:error, %{"type" => t}}) when is_binary(t),
    do: "error: " <> t

  defp format_result(other), do: "result: " <> inspect(other)

  defp generate_id,
    do: :crypto.strong_rand_bytes(12) |> Base.encode32(padding: false)
end
