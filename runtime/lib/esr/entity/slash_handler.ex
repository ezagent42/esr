defmodule Esr.Entity.SlashHandler do
  @moduledoc """
  Channel-agnostic slash-command peer. Scope.Admin-scope (exactly one,
  registered under `:slash_handler` in `Esr.Scope.Admin.Process`).

  ## API (PR-21κ Phase 6)

  Public entry point: `dispatch/2,3`. Adapters (FAA, future Telegram,
  etc.) call `dispatch(envelope, reply_to)` and receive the reply as
  `{:reply, text, ref}` to `reply_to`. Routing is yaml-driven via
  `Esr.Resource.SlashRoute.Registry` — adapters know nothing about specific slash text
  or kind names.

  ## What this module owns

  * Text → route lookup (delegated to `Esr.Resource.SlashRoute.Registry`)
  * Generic positional + kv arg parser
  * Workspace-binding / user-binding precondition gates
  * Envelope-derived arg injection (chat_id, app_id, principal_id, etc.)
  * 5s per-call dispatch timeout
  * Result formatting (kind-specific text rendering)

  ## What this module no longer owns (PR-21κ Phase 6 deletions)

  * The legacy `:slash_cmd` handle_info clause (FCP / direct sends)
  * Per-command parsers (`parse_new_session`, `parse_new_workspace`, …)
  * The bypass-list quartet (FAA's `inline_bootstrap_slash?` etc.)

  Spec §4.1, §5.3, §1.8 D14. yaml schema:
  `runtime/priv/slash-routes.default.yaml`.
  """

  @behaviour Esr.Role.Pipeline
  use Esr.Entity.Stateful
  use GenServer
  require Logger

  @default_dispatcher Esr.Admin.Dispatcher

  # PR-21κ Phase 3 (2026-04-30): adapter-agnostic dispatch path is
  # gated by a per-call timeout. The dispatcher cast is one-shot
  # (Task.start in the dispatcher), but a stuck command module would
  # leave the original adapter waiting forever. 5s is generous for
  # everything except worktree creation; see futures/todo.md for the
  # async-worktree improvement.
  @dispatch_timeout_ms 5_000

  # start_link/1 inherits the dual-shape (map | keyword) default from
  # Esr.Entity.Stateful (PR-6 B1). All current callers pass %{}.

  @impl GenServer
  def init(args) do
    :ok = Esr.Scope.Admin.Process.register_admin_peer(:slash_handler, self())

    state = %{
      dispatcher: Map.get(args, :dispatcher, @default_dispatcher),
      session_id: Map.fetch!(args, :session_id),
      # Tests override this for fast timeout-path coverage; production
      # uses the @dispatch_timeout_ms default.
      dispatch_timeout_ms: Map.get(args, :dispatch_timeout_ms, @dispatch_timeout_ms),
      # ref -> {:dispatch, reply_to_pid, timer_ref}
      pending: %{}
    }

    {:ok, state}
  end

  # ====================================================================
  # PR-21κ Phase 3 — adapter-agnostic dispatch/2 (yaml-driven)
  # ====================================================================

  @doc """
  Adapter-agnostic slash dispatch (PR-21κ).

  Looks `text` up in `Esr.Resource.SlashRoute.Registry`, applies binding/permission
  preconditions, and casts the command to `Esr.Admin.Dispatcher`. The
  reply (or error) is delivered to `reply_to` as
  `{:reply, text, ref}` — the caller correlates by `ref`.

  Returns the `ref` so the caller can stash it (e.g. FAA's
  `slash_pending_chat`) for delivery routing on the inbound side.

  Runs in parallel to the legacy `:slash_cmd` handle_info path during
  the PR-21κ rollout. Phase 6 deletes the legacy path; for now both
  work — adapters opt-in by switching from `send(slash_handler,
  {:slash_cmd, ...})` to `SlashHandler.dispatch(...)`.
  """
  @typedoc """
  Reply destination accepted by `dispatch/2,3`. Either a bare pid
  (legacy chat-inbound path; auto-wrapped as `{ChatPid, pid}`) or an
  explicit `{module, target}` tuple where `module` implements
  `Esr.Slash.ReplyTarget`.
  """
  @type reply_to :: pid() | {module(), term()}

  @spec dispatch(map(), reply_to()) :: reference()
  def dispatch(envelope, reply_to) do
    dispatch(envelope, reply_to, make_ref())
  end

  @spec dispatch(map(), reply_to(), reference()) :: reference()
  def dispatch(envelope, reply_to, ref) when is_reference(ref) do
    # PR-2.2: validate the shape early so callers get a clear ArgumentError
    # at dispatch time, not at handle_cast time. handle_cast normalizes
    # again (defensive) so the cast payload preserves the legacy shape
    # (bare pid OR {module, target}) and existing FAA tests still match.
    _ = Esr.Slash.ReplyTarget.normalize(reply_to)

    # PR-21κ Phase 6 fix: SlashHandler is supervised by Scope.Admin's
    # children DynamicSupervisor and registered as `:slash_handler` in
    # `Esr.Scope.Admin.Process` (not under its module name). Resolve
    # the actual pid via `slash_handler_ref/0` rather than assuming a
    # `name: __MODULE__` registration that doesn't exist in production.
    case Esr.Scope.Admin.Process.slash_handler_ref() do
      {:ok, pid} ->
        GenServer.cast(pid, {:dispatch, envelope, reply_to, ref})

      :error ->
        Logger.warning(
          "slash_handler.dispatch: no slash_handler registered (envelope dropped)"
        )

        Esr.Slash.ReplyTarget.dispatch(
          Esr.Slash.ReplyTarget.normalize(reply_to),
          {:text, "slash routing unavailable (boot incomplete)"},
          ref
        )
    end

    ref
  end

  @impl GenServer
  def handle_cast({:dispatch, envelope, reply_to, ref}, state) do
    # Normalize defensively: callers that GenServer.cast directly
    # (notably tests) may still pass bare pids per the legacy shape;
    # both `pid` and `{module, target}` resolve to the same internal
    # `{module, target}` representation here.
    target = Esr.Slash.ReplyTarget.normalize(reply_to)
    text = extract_text(envelope)
    principal_id = envelope["principal_id"] || "ou_unknown"

    case Esr.Resource.SlashRoute.Registry.lookup(text) do
      :not_found ->
        Esr.Slash.ReplyTarget.dispatch(target, {:text, "unknown command: #{slash_head(text)}"}, ref)
        {:noreply, state}

      {:ok, route} ->
        with {:ok, parsed_args} <- parse_route_args(text, route),
             :ok <- check_workspace_binding(route, envelope),
             :ok <- check_user_binding(route, envelope) do
          merged =
            parsed_args
            |> inject_envelope_args(envelope)
            |> merge_chat_context(route.kind, envelope)
            |> maybe_derive_session_new_cwd(route.kind)

          cmd = %{
            "id" => generate_id(),
            "kind" => route.kind,
            "submitted_by" => principal_id,
            "args" => merged
          }

          timer = Process.send_after(self(), {:slash_dispatch_timeout, ref}, state.dispatch_timeout_ms)

          GenServer.cast(
            state.dispatcher,
            {:execute, cmd, {:reply_to, {:pid, self(), ref}}}
          )

          {:noreply, put_in(state.pending[ref], {:dispatch, target, timer})}
        else
          {:error, msg} when is_binary(msg) ->
            Esr.Slash.ReplyTarget.dispatch(target, {:text, msg}, ref)
            {:noreply, state}
        end
    end
  end

  # handle_upstream/2 and handle_downstream/2 inherit the no-op
  # `{:forward, [], state}` defaults from Esr.Entity.Stateful (PR-6 B1).
  # SlashHandler never participates in the chain: it's a sink for
  # `:slash_cmd` handle_info messages from FeishuChatProxy.

  @impl GenServer
  def handle_info({:command_result, ref, result}, state) when is_reference(ref) do
    case Map.pop(state.pending, ref) do
      {nil, _} ->
        Logger.warning(
          "slash_handler: unknown command_result ref #{inspect(ref)}"
        )

        {:noreply, state}

      {{:dispatch, target, timer}, rest} ->
        _ = Process.cancel_timer(timer)
        Esr.Slash.ReplyTarget.dispatch(target, result, ref)
        {:noreply, %{state | pending: rest}}
    end
  end

  # PR-21κ Phase 3: per-dispatch timeout. Fires only if Dispatcher
  # never responds — usually means a command module hung. We notify
  # the original adapter so the operator gets a clear "timed out"
  # message rather than silent death.
  def handle_info({:slash_dispatch_timeout, ref}, state) when is_reference(ref) do
    case Map.pop(state.pending, ref) do
      {{:dispatch, target, _timer}, rest} ->
        Logger.warning("slash_handler: dispatch timeout for ref #{inspect(ref)}")
        Esr.Slash.ReplyTarget.dispatch(target, {:text, "command timed out (>5s)"}, ref)
        {:noreply, %{state | pending: rest}}

      _ ->
        # Already completed before timer fired, or unknown ref.
        {:noreply, state}
    end
  end

  def handle_info(_other, state), do: {:noreply, state}

  # ====================================================================
  # PR-21κ Phase 3 helpers — text → args, binding checks, envelope inject
  # ====================================================================

  defp extract_text(envelope) do
    (get_in(envelope, ["payload", "text"]) ||
       get_in(envelope, ["payload", "args", "content"]) ||
       "")
    |> to_string()
  end

  defp slash_head(text) do
    text
    |> String.trim()
    |> String.split(~r/\s+/, parts: 2, trim: true)
    |> List.first("")
  end

  # Strip the matched slash prefix (`route.slash` is the literal
  # whitespace-joined key, e.g. "/workspace info") from the front of
  # the user's text. Returns the trimmed remainder ready for tokenize.
  defp strip_slash_prefix(text, slash) do
    trimmed = String.trim(text)

    case String.split(trimmed, slash, parts: 2) do
      ["", rest] -> String.trim(rest)
      [^trimmed] -> trimmed
      _ -> trimmed
    end
  end

  # Generic parser. Convention:
  #   * args list with at least one entry → first remainder token
  #     (without `=`) binds to the first arg as a positional value.
  #   * All other tokens must be `key=value` form.
  #   * Required args missing → `{:error, message}`.
  #   * Optional args carry their `default` if absent from input.
  defp parse_route_args(text, route) do
    remainder = strip_slash_prefix(text, route.slash)
    toks = tokenize(remainder)
    arg_specs = route.args || []

    case arg_specs do
      [] ->
        {:ok, %{}}

      [first_spec | _rest_specs] ->
        {positional, kvs} = peel_positional(toks)
        kv_map = parse_kv_pairs(kvs)

        args =
          if positional do
            Map.put_new(kv_map, first_spec.name, positional)
          else
            kv_map
          end
          |> apply_defaults(arg_specs)

        case validate_required(args, arg_specs, route.slash) do
          :ok -> {:ok, args}
          {:error, _} = err -> err
        end
    end
  end

  # If the first token has no `=`, treat it as a positional value.
  # Otherwise leave all tokens in the kv stream.
  defp peel_positional([first | rest]) when is_binary(first) do
    if String.contains?(first, "=") do
      {nil, [first | rest]}
    else
      {first, rest}
    end
  end

  defp peel_positional([]), do: {nil, []}

  defp apply_defaults(args, arg_specs) do
    Enum.reduce(arg_specs, args, fn
      %{name: name, default: default}, acc when not is_nil(default) ->
        Map.put_new(acc, name, default)

      _, acc ->
        acc
    end)
  end

  defp validate_required(args, arg_specs, slash) do
    missing =
      arg_specs
      |> Enum.filter(fn
        %{required: true, name: name} -> Map.get(args, name) in [nil, ""]
        _ -> false
      end)
      |> Enum.map(& &1.name)

    case missing do
      [] -> :ok
      [name] -> {:error, "#{slash}: missing required arg `#{name}=<…>`"}
      names -> {:error, "#{slash}: missing required args: #{Enum.join(names, ", ")}"}
    end
  end

  defp check_workspace_binding(%{requires_workspace_binding: true}, envelope) do
    chat_id = envelope_chat_id(envelope)
    app_id = get_in(envelope, ["payload", "args", "app_id"])

    case resolve_workspace(chat_id, app_id) do
      ws when is_binary(ws) and ws != "" ->
        :ok

      _ ->
        {:error,
         "this command requires the chat to be bound to a workspace; run `/new-workspace <name>` first"}
    end
  end

  defp check_workspace_binding(_route, _envelope), do: :ok

  defp check_user_binding(%{requires_user_binding: true}, envelope) do
    case resolve_username(envelope) do
      u when is_binary(u) and u != "" ->
        :ok

      _ ->
        principal = envelope["principal_id"] || envelope["user_id"] || "(unknown open_id)"

        {:error,
         "this command requires your Feishu identity to be bound to an esr user; " <>
           "run `./esr.sh user bind-feishu <esr_user> #{principal}` first (or /doctor for guidance)"}
    end
  end

  defp check_user_binding(_route, _envelope), do: :ok

  # Inject envelope-derived args (chat/app/principal) for command
  # modules that consume them — Whoami, Doctor, and any future
  # command needing the calling context. Idempotent: doesn't overwrite
  # values the user explicitly typed (unlikely for these names).
  defp inject_envelope_args(args, envelope) do
    chat_id = envelope_chat_id(envelope)
    thread_id = envelope_thread_id(envelope)
    app_id = get_in(envelope, ["payload", "args", "app_id"])
    principal_id = envelope["principal_id"] || envelope["user_id"]

    args
    |> maybe_put("chat_id", chat_id)
    |> maybe_put("thread_id", thread_id)
    |> maybe_put("app_id", app_id)
    |> maybe_put("principal_id", principal_id)
  end

  # PR-21θ derivation lifted from parse_new_session/1. The legacy
  # parser already did this; the dispatch path needs the same
  # behavior so Session.New receives `cwd` when root + worktree are
  # set. Per yaml-authoring-lessons.md, derivations belong in the
  # command module, but Session.New currently expects cwd pre-derived
  # — moving the derivation into Session.New is a cleanup left for
  # PR-21κ Phase 6 / a follow-up.
  defp maybe_derive_session_new_cwd(args, "session_new") do
    case {args["root"], args["worktree"], args["cwd"]} do
      {root, branch, nil} when is_binary(root) and root != "" and is_binary(branch) and branch != "" ->
        Map.put(args, "cwd", Path.join([root, ".worktrees", branch]))

      _ ->
        args
    end
  end

  defp maybe_derive_session_new_cwd(args, _kind), do: args

  # session_new needs chat_thread_key threading + (PR-21g) username
  # resolution from envelope.user_id via Esr.Entity.User.Registry. session_end
  # also needs username when args carries `name=` (PR-21g resolver).
  defp merge_chat_context(args, "session_new", envelope) do
    chat_id = envelope_chat_id(envelope)
    thread_id = envelope_thread_id(envelope)
    username = resolve_username(envelope)

    args
    |> maybe_put("chat_id", chat_id)
    |> maybe_put("thread_id", thread_id)
    |> maybe_put("username", username)
  end

  # session_end by `name` (PR-21g resolver) needs `(env, username,
  # workspace, name)` to find the session_id. The slash form
  # `/end-session <name>` doesn't carry workspace; resolve it from
  # the chat's binding (same convention as session_list /
  # workspace_info). PR-21π 2026-05-01.
  defp merge_chat_context(args, "session_end", envelope) do
    chat_id = envelope_chat_id(envelope)
    thread_id = envelope_thread_id(envelope)
    app_id = get_in(envelope, ["payload", "args", "app_id"])
    username = resolve_username(envelope)

    args =
      args
      |> maybe_put("chat_id", chat_id)
      |> maybe_put("thread_id", thread_id)
      |> maybe_put("username", username)

    if Map.get(args, "workspace") in [nil, ""] do
      maybe_put(args, "workspace", resolve_workspace(chat_id, app_id))
    else
      args
    end
  end

  # PR-21j: session_list (when called with workspace=) and workspace_info
  # need both `username` (URI uniqueness scoping) and `workspace`
  # (defaults to the chat's bound workspace when absent from args).
  defp merge_chat_context(args, kind, envelope) when kind in ["session_list", "workspace_info"] do
    chat_id = envelope_chat_id(envelope)
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
    chat_id = envelope_chat_id(envelope)
    app_id = get_in(envelope, ["payload", "args", "app_id"])
    username = resolve_username(envelope)

    args
    |> maybe_put("chat_id", chat_id)
    |> maybe_put("app_id", app_id)
    |> maybe_put("username", username)
  end

  # PR-24 step 2 follow-up: `/key` takes the entire remainder text after
  # the slash as a single positional arg. The standard `parse_route_args`
  # only peels ONE positional token, dropping the rest, so multi-key
  # input like `/key down down enter` would lose all but the first
  # token. Capture the raw remainder ourselves.
  defp merge_chat_context(args, "key", envelope) do
    text = (get_in(envelope, ["payload", "text"]) || "") |> to_string()
    remainder = strip_slash_prefix(text, "/key") |> String.trim()
    maybe_put(args, "keys", remainder)
  end

  defp merge_chat_context(args, _kind, _envelope), do: args

  # PR-21ε 2026-04-30: real adapter inbound carries chat_id /
  # thread_id under `payload.args` (the Python adapter's wire shape).
  # The legacy slash_handler tests + earlier internal callers used
  # `payload.chat_id` directly. Read both for compat — production wins
  # via the fallback. Same fix shape as PR-21δ for resolve_username.
  defp envelope_chat_id(envelope) do
    get_in(envelope, ["payload", "chat_id"]) ||
      get_in(envelope, ["payload", "args", "chat_id"])
  end

  defp envelope_thread_id(envelope) do
    get_in(envelope, ["payload", "thread_id"]) ||
      get_in(envelope, ["payload", "args", "thread_id"])
  end

  # Resolve the workspace name a chat is bound to. Returns nil when no
  # binding (caller decides whether that's an error).
  defp resolve_workspace(chat_id, app_id)
       when is_binary(chat_id) and chat_id != "" and is_binary(app_id) and app_id != "" do
    case Esr.Resource.Workspace.Registry.workspace_for_chat(chat_id, app_id) do
      {:ok, ws} -> ws
      :not_found -> nil
    end
  end

  defp resolve_workspace(_chat_id, _app_id), do: nil

  defp resolve_username(envelope) do
    # PR-21δ 2026-04-30: extend the lookup chain to match the real
    # inbound envelope shape from the Python adapter. The Feishu adapter
    # populates `principal_id` (top-level) + `payload.args.sender_id`.
    # The pre-PR-21δ shape (`user_id` / `payload.user_id`) was based on
    # an earlier draft that never made it to the adapter wire format —
    # `resolve_username/1` always returned nil for real inbounds, which
    # broke `/new-workspace` (Workspace.New rejected with invalid_args
    # when owner couldn't be inferred from username).
    open_id =
      envelope["user_id"] ||
        envelope["principal_id"] ||
        get_in(envelope, ["payload", "user_id"]) ||
        get_in(envelope, ["payload", "args", "sender_id"])

    cond do
      not is_binary(open_id) or open_id == "" ->
        nil

      Process.whereis(Esr.Entity.User.Registry) == nil ->
        nil

      true ->
        case Esr.Entity.User.Registry.lookup_by_feishu_id(open_id) do
          {:ok, username} -> username
          :not_found -> nil
        end
    end
  end

  defp maybe_put(map, _k, nil), do: map
  defp maybe_put(map, k, v), do: Map.put(map, k, v)

  # PR-21κ Phase 6: per-command parsers (parse_new_session,
  # parse_new_workspace, parse_workspace, parse_end_session,
  # parse_command) + has_legacy_flags? + derive_worktree_cwd
  # deleted — yaml-driven `dispatch/2`'s generic
  # `parse_route_args/2` (above) replaces all of them. Worktree cwd
  # derivation moved to `maybe_derive_session_new_cwd/2`.

  # tokenize / parse_kv_pairs are kept — they're called by
  # `parse_route_args/2` (the generic kv parser).
  defp tokenize(rest),
    do: rest |> String.trim() |> String.split(~r/\s+/, trim: true)

  defp parse_kv_pairs(toks) do
    toks
    |> Enum.reduce(%{}, fn tok, acc ->
      case String.split(tok, "=", parts: 2) do
        [k, v] when k != "" -> Map.put(acc, k, v)
        _ -> acc
      end
    end)
  end

  # Result formatting moved to Esr.Slash.ReplyTarget.ChatPid
  # (PR-2.2 dependency-inversion). Each ReplyTarget impl now owns
  # rendering for its medium.

  defp generate_id,
    do: :crypto.strong_rand_bytes(12) |> Base.encode32(padding: false)
end
