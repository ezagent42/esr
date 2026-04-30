# Slash Routes Yaml — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal**: Replace ESR's hardcoded slash routing (3 layers across `FeishuAppAdapter`, `SlashHandler`, `Dispatcher`) with `slash-routes.yaml` + a generic adapter-agnostic dispatch path. Adding a slash becomes "yaml entry + command module"; no edits to adapter or dispatcher.

**Spec**: `docs/superpowers/specs/2026-04-30-slash-routes-yaml-design.md` (subagent review pass 1 complete).

**Plan review status**: subagent review pass 1 complete (2026-04-30); 2 blockers + 3 inaccuracies addressed inline (priv-seed pattern, internal_kinds yaml extension, list_agents helper, todo.md section reference, FSEvents save-pattern caveat).

**Working directory**: `/Users/h2oslabs/Workspace/esr` on branch `feature/slash-routes-yaml-spec` (this plan + spec live on this branch). Implementation lands on a separate branch `feature/slash-routes-yaml-impl` after spec sign-off.

**PR target**: against `dev` branch per the PR-21ζ git flow. Promote dev → main via direct push after dev esrd validates.

---

## Scope check

This plan implements the spec as a single PR organized as 9 phases / 9 commits. The PR is **large** (~600 LOC net). Splitting between phases 5 and 6 ("yaml path live; old paths still around" vs "delete old paths") is the natural cut if review demands two PRs.

**In-scope from spec**:
- New `Esr.SlashRoutes` module + `slash-routes.yaml` + `FileLoader` + `Watcher`
- `Esr.Peers.SlashHandler` rewrite (adapter-agnostic `dispatch/2`)
- `Esr.Peers.FeishuAppAdapter` slash routing replacement (one-line `String.starts_with?` check)
- `Esr.Peers.FeishuChatProxy` slash routing removal
- `Esr.Admin.Dispatcher` simplification (delete `@required_permissions`/`@command_modules` constants)
- New command modules: `Help`, `Whoami`, `Doctor`, `Agent.List`
- `Esr.Admin.Commands.Session.New` absorbs cwd-from-worktree derivation (was in slash parser pre-PR-21θ — already there per PR-21θ; verify)
- Reply correlation via `slash_pending_chat: %{ref => chat_id}` per spec

**Out-of-scope**:
- Other yaml-ification candidates (Workshops 2 & 3 — `docs/futures/todo.md`)

## File structure

**New code**:
- `runtime/lib/esr/slash_routes.ex` — ETS-backed registry (~120 LOC)
- `runtime/lib/esr/slash_routes/file_loader.ex` — yaml parse + validate (~100 LOC)
- `runtime/lib/esr/slash_routes/watcher.ex` — FSEvents watcher (~80 LOC)
- `runtime/lib/esr/admin/commands/help.ex` — `/help` rendering (~40 LOC)
- `runtime/lib/esr/admin/commands/whoami.ex` — `/whoami` (~50 LOC; reads `Esr.Users.Registry`)
- `runtime/lib/esr/admin/commands/doctor.ex` — `/doctor` (~80 LOC; reads several registries)
- `runtime/lib/esr/admin/commands/agent/list.ex` — `/list-agents` (~30 LOC)
- `priv/slash-routes.default.yaml` — seed for first-boot operators

**Edited code**:
- `runtime/lib/esr/peers/slash_handler.ex` — full rewrite (~200 → ~100 LOC). New `dispatch/2` API; bespoke parsers deleted.
- `runtime/lib/esr/peers/feishu_app_adapter.ex` — delete bypass quartet + `bootstrap_pending_chat`; add `slash_pending_chat` + `String.starts_with?(text, "/")` check + `handle_info({:reply, text, ref}, _)`
- `runtime/lib/esr/peers/feishu_chat_proxy.ex` — delete `slash?/1`, `dispatch_slash/2` paths
- `runtime/lib/esr/admin/dispatcher.ex` — replace `@required_permissions`/`@command_modules` with `SlashRoutes.permission_for/1` / `SlashRoutes.command_module_for/1`
- `runtime/lib/esr/application.ex` — add `Esr.SlashRoutes` + `Esr.SlashRoutes.Watcher` to children list (after `Esr.Workspaces.Watcher`)

**New tests**:
- `runtime/test/esr/slash_routes_test.exs` — yaml parse + validation + lookup
- `runtime/test/esr/admin/commands/help_test.exs`
- `runtime/test/esr/admin/commands/whoami_test.exs`
- `runtime/test/esr/admin/commands/doctor_test.exs`
- `runtime/test/esr/admin/commands/agent/list_test.exs`

**Edited tests**:
- `runtime/test/esr/peers/slash_handler_test.exs` — partial rewrite (27 tests; maybe 20 stay with new API, 5 deleted, 5 added for binding gates + reply correlation)
- `runtime/test/esr/peers/feishu_app_adapter_test.exs` — assert "any slash → SlashHandler.dispatch/2"
- `runtime/test/esr/integration/feishu_slash_new_session_test.exs` — simpler (no FCP slash routing)
- `runtime/test/esr/admin/dispatcher_test.exs` — references SlashRoutes via lookup, not constants

**Edited docs**:
- `docs/cli-reference.md` — regen via `bash scripts/gen-docs.sh` (no expected change unless cli surface touched)
- `docs/runtime-channel-reference.md` — same
- `CLAUDE.md` — index entry pointing at `docs/dev-flow.md` already exists; add a `docs/notes/slash-yaml-routing.md` field note + index it
- `docs/futures/todo.md` — close the `#221` entry

---

## Phases

### Phase 1 — `Esr.SlashRoutes` skeleton (no callers yet)

- [ ] **1.1** Create `runtime/lib/esr/slash_routes.ex`:
  - `use GenServer`
  - `start_link/1` (registered as `Esr.SlashRoutes`)
  - ETS `:esr_slash_routes` (named, public, set, read_concurrency)
  - Public: `lookup(text) → {:ok, route} | :not_found`, `permission_for(kind)`, `command_module_for(kind)`, `route_for_kind(kind)`, `list/0`
  - Internal: `handle_call({:load, snapshot})` does atomic ETS replace
- [ ] **1.2** Create `runtime/lib/esr/slash_routes/file_loader.ex`:
  - `load(path) → :ok | {:error, reason}` reads + validates yaml + calls `Esr.SlashRoutes.load_snapshot/1`
  - Validation rules:
    - schema_version == 1
    - Each slash key is a `/`-prefixed string
    - Each entry has required fields: `kind`, `command_module`, `requires_workspace_binding`, `requires_user_binding`
    - `command_module`: validated via `Code.ensure_loaded?(Module.concat([str]))` — NOT `Module.safe_concat/1`
    - `permission`: nil or string matching valid cap shape
    - `args`: list of `%{name: string, required: bool, default: any}`
    - `aliases`: list of `/`-prefixed strings; each gets the parent route metadata
- [ ] **1.3** Create `runtime/lib/esr/slash_routes/watcher.ex`:
  - Mirror `Esr.Workspaces.Watcher` shape: `init/1` calls `FileSystem.start_link/1` + initial `FileLoader.load/1`; `handle_info({:file_event, _, {path, _}})` matches by basename and reloads
- [ ] **1.4** Add to supervisor tree in `runtime/lib/esr/application.ex`:
  ```elixir
  Esr.SlashRoutes,
  {Esr.SlashRoutes.Watcher, path: Esr.Paths.slash_routes_yaml()},
  ```
  After `Esr.Workspaces.Watcher`, before `Esr.Capabilities.Supervisor` (cap registry uses permissions; slash_routes references caps but only by string).
- [ ] **1.5** Add helper `Esr.Paths.slash_routes_yaml/0` — `Path.join([esrd_home(), env(), "slash-routes.yaml"])`.
- [ ] **1.6** Create `priv/slash-routes.default.yaml` with **all 14 Dispatcher kinds**: 9 slash-callable entries (per spec) PLUS 5 internal-only kinds (`notify`, `reload`, `register_adapter`, `grant`, `revoke`; plus `session_branch_new`, `session_switch`, `session_branch_end`, `cross_app_test` if still active). Internal kinds use `slash: null` shape:
  ```yaml
  internal_kinds:
    notify:
      permission: "notify.send"
      command_module: "Esr.Admin.Commands.Notify"
    reload:
      permission: "runtime.reload"
      command_module: "Esr.Admin.Commands.Reload"
    register_adapter:
      permission: "adapter.register"
      command_module: "Esr.Admin.Commands.RegisterAdapter"
    grant:
      permission: "cap.manage"
      command_module: "Esr.Admin.Commands.Cap.Grant"
    revoke:
      permission: "cap.manage"
      command_module: "Esr.Admin.Commands.Cap.Revoke"
    # ... etc
  ```
  Reasoning: these kinds are submitted from CLI tools (`py/src/esr/cli/{reload,notify,cap,adapter/feishu}.py`) via `Esr.Admin.CommandQueue.Watcher`, bypassing slash entirely. Without yaml entries for them, Phase 6.3 (Dispatcher refactor) would break every CLI-driven `esr reload` / `esr notify` / `esr cap grant`.
  **Schema rule**: `slashes:` map entries are slash-callable (have a slash key); `internal_kinds:` map entries are kind-only (have only the kind name as key). Both feed into the same kind→{permission, command_module} lookup in `Esr.SlashRoutes.permission_for/1` and `command_module_for/1`. `lookup/1` (text → route) only searches the `slashes:` table.
- [ ] **1.7** First-boot bootstrap: in `Esr.SlashRoutes.start_link/1`, if `<esrd_home>/<env>/slash-routes.yaml` is absent, copy from `Application.app_dir(:esr, "priv/slash-routes.default.yaml")` via `File.mkdir_p!/1` + `File.cp/2`. **No existing pattern matches**; this is a new shape for the codebase. (`Esr.Capabilities.Supervisor.maybe_bootstrap_file/1` writes a synthesized string conditional on `ESR_BOOTSTRAP_PRINCIPAL_ID` env var — different semantics.) Mix releases package `priv/` correctly via `Application.app_dir/1`. Cite this approach in `docs/notes/slash-yaml-routing.md` as the canonical priv-seed pattern for future yaml-ifications.
- [ ] **1.8** Write `runtime/test/esr/slash_routes_test.exs`:
  - load valid yaml; lookup succeeds for known slash + unknown slash
  - reject malformed yaml (missing kind, bad scope_prefix, unknown_module)
  - alias resolution: `lookup("/list-sessions")` returns same route as `lookup("/sessions")`
  - longest-prefix match: `lookup("/workspace info abc")` returns the `/workspace info` route, not the `/workspace` one
- [ ] **1.9** `cd runtime && mix test test/esr/slash_routes_test.exs`. All pass.
- [ ] **1.10** Commit: `feat(slash_routes): SlashRoutes registry + FileLoader + Watcher (no callers yet)`.

### Phase 2 — New command modules

- [ ] **2.1** `runtime/lib/esr/admin/commands/help.ex`:
  - `execute/1` reads `Esr.SlashRoutes.list/0`, groups by `category` (yaml field — see spec open Q1; default "其他"), renders the existing 中文 layout
  - Returns `{:ok, %{"text" => help_string}}`
- [ ] **2.2** `runtime/lib/esr/admin/commands/whoami.ex`:
  - Move logic from `feishu_app_adapter.ex:whoami_text/3`
  - Reads `args["principal_id"]`, `args["chat_id"]`, `args["app_id"]`
  - Returns `{:ok, %{"text" => whoami_string}}`
- [ ] **2.3** `runtime/lib/esr/admin/commands/doctor.ex`:
  - Move logic from `feishu_app_adapter.ex:doctor_text/3`
  - Same arg shape as whoami; emits the bootstrap-aware health diagnostic
  - Returns `{:ok, %{"text" => doctor_string}}`
- [ ] **2.4a** `Esr.SessionRegistry.list_agents/0` does **not** exist today (verified 2026-04-30 review). Add it to `runtime/lib/esr/session_registry.ex`:
  ```elixir
  @spec list_agents() :: [String.t()]
  def list_agents, do: GenServer.call(__MODULE__, :list_agents)

  def handle_call(:list_agents, _from, state) do
    {:reply, state.agents |> Map.keys() |> Enum.sort(), state}
  end
  ```
  Add a unit test in `runtime/test/esr/session_registry_test.exs`.
- [ ] **2.4b** `runtime/lib/esr/admin/commands/agent/list.ex`:
  - Reads `Esr.SessionRegistry.list_agents/0`
  - Returns `{:ok, %{"text" => "available agents:\n  - cc\n  - ..."}}`
  - **Latent bug fixed**: today `/list-agents` returns `unknown_kind` because Dispatcher has no `agent_list` mapping (slash_handler.ex parses it but Dispatcher rejects).
- [ ] **2.5** Write tests for each new command module (pure-fn tests; no GenServer setup needed).
- [ ] **2.6** Add `category` field to `priv/slash-routes.default.yaml` per slash (诊断 / Workspace / Sessions / Agents).
- [ ] **2.7** Update `Esr.SlashRoutes.FileLoader` validation to accept `category` as optional string.
- [ ] **2.8** `mix test test/esr/admin/commands/{help,whoami,doctor,agent/list}_test.exs`. All pass.
- [ ] **2.9** Commit: `feat(commands): Help/Whoami/Doctor/Agent.List modules for yaml-driven slash routing`.

### Phase 3 — Refactor `Esr.Peers.SlashHandler` to adapter-agnostic `dispatch/2`

- [ ] **3.1** Add new public function:
  ```elixir
  @spec dispatch(envelope :: map(), reply_to :: pid()) :: :ok
  def dispatch(envelope, reply_to) when is_pid(reply_to) do
    GenServer.cast(__MODULE__, {:dispatch, envelope, reply_to, make_ref()})
  end
  ```
- [ ] **3.2** New `handle_cast({:dispatch, envelope, reply_to, ref}, state)`:
  - Extract `text = envelope["payload"]["text"] || ""` (fallback to `payload.args.content`)
  - `Esr.SlashRoutes.lookup(text) → {:ok, route} | :not_found`
  - On `:not_found`: send `{:reply, "unknown command: #{text}", ref}` to `reply_to`
  - On `{:ok, route}`:
    - Generic KV parse using `route.args` spec → args map (with defaults applied)
    - Check `requires_workspace_binding`: if true and `Esr.Workspaces.Registry.workspace_for_chat/2` returns `:not_found`, send `{:reply, "this command requires the chat to be bound to a workspace; run /new-workspace first", ref}` and return
    - Check `requires_user_binding`: if true and `Esr.Users.Registry.lookup_by_feishu_id/1` returns `:not_found`, send `{:reply, "this command requires your Feishu identity to be bound; run `esr user bind-feishu` first", ref}` and return
    - Cap check delegated to Dispatcher (via the existing dispatcher cast)
    - Build `cmd = %{"id" => ..., "kind" => route.kind, "submitted_by" => principal, "args" => args}`
    - `GenServer.cast(state.dispatcher, {:execute, cmd, {:reply_to, {:pid, self(), ref}}})`
    - Track `state.pending[ref] = {reply_to, schedule_timeout(ref)}`
- [ ] **3.3** New `handle_info({:command_result, ref, result}, state)`:
  - Pop ref from `state.pending` + cancel timeout
  - Format result text (existing `format_result/1` logic, adjusted for `action: "added_chat"` etc.)
  - Send `{:reply, formatted_text, ref}` to the original `reply_to`
- [ ] **3.4** New `handle_info({:slash_dispatch_timeout, ref}, state)`:
  - Pop ref; if still pending, send `{:reply, "command timed out (>5s)", ref}` to reply_to
- [ ] **3.5** Keep the old `handle_info({:slash_cmd, envelope, reply_to_proxy}, state)` clause AS-IS for now (Phase 6 deletes it). Both APIs work in parallel during the migration.
- [ ] **3.6** Delete the bespoke per-command parsers (`parse_new_session/1`, `parse_new_workspace/1`, `parse_end_session/1`, `parse_workspace/1`, `parse_kv_pairs/1`, `tokenize/1`) — these die in Phase 6 entirely; for now, mark them as `# DEPRECATED — Phase 6 deletion target`.

  Actually: leave them in place for the legacy `:slash_cmd` path. Phase 6 deletes them.

- [ ] **3.7** Run existing `mix test test/esr/peers/slash_handler_test.exs`. All pass (legacy path still wired).
- [ ] **3.8** Add new tests in `slash_handler_test.exs`:
  - `dispatch/2` with `/help` (no permission, no bindings) → `{:reply, help_text, ref}`
  - `dispatch/2` with `/new-session` from workspace-unbound chat → `{:reply, "requires workspace binding", ref}`
  - `dispatch/2` with unknown slash → `{:reply, "unknown command", ref}`
  - `dispatch/2` with valid args → command executed, reply received with kind result
  - Timeout: dispatcher silent for 6s → `{:reply, "timed out", ref}` received within 5500ms
- [ ] **3.9** Commit: `feat(slash_handler): adapter-agnostic dispatch/2 + ref-keyed reply correlation`.

### Phase 4 — Refactor `FeishuAppAdapter` to call `dispatch/2`

- [ ] **4.1** In `runtime/lib/esr/peers/feishu_app_adapter.ex`:
  - Remove `inline_bootstrap_slash?/1`, `routed_bootstrap_slash?/1`, `handle_inline_bootstrap_slash/5`, `route_to_slash_handler/3`
  - Remove `bootstrap_pending_chat` from state init
  - Add `slash_pending_chat: %{}` to state init
  - In `handle_upstream({:inbound_event, _})` after the PendingActionsGuard intercept:
    ```elixir
    text = (get_in(envelope, ["payload", "args", "content"]) || "") |> to_string()

    if String.starts_with?(text, "/") do
      ref = make_ref()
      envelope_with_text = put_in(envelope, ["payload", "text"], text)
      Esr.Peers.SlashHandler.dispatch(envelope_with_text, self())
      new_state = put_in(state, [:slash_pending_chat, ref], chat_id)
      {:drop, :slash_dispatched, new_state}
    else
      do_handle_upstream_inbound(envelope, args, chat_id, thread_id, state)
    end
    ```
    Actually — the ref must be threaded through SlashHandler.dispatch; refactor: `Esr.Peers.SlashHandler.dispatch(envelope_with_text, self())` returns the ref it generated, OR FAA generates the ref and passes it in. Cleaner: FAA generates, passes via dispatch.
  - Replace existing `{:reply, text}` clause with `handle_info({:reply, text, ref}, state)`:
    ```elixir
    case Map.pop(state.slash_pending_chat, ref) do
      {chat_id, rest} when is_binary(chat_id) ->
        send(self(), {:outbound, %{"kind" => "reply", "args" => %{"chat_id" => chat_id, "text" => text}}})
        {:noreply, %{state | slash_pending_chat: rest}}
      {nil, _} ->
        Logger.warning("FAA: slash reply for unknown ref")
        {:noreply, state}
    end
    ```
- [ ] **4.2** Update `Esr.Peers.SlashHandler.dispatch/2` signature to accept the ref from caller:
  ```elixir
  def dispatch(envelope, reply_to, ref \\ make_ref()) do
    GenServer.cast(__MODULE__, {:dispatch, envelope, reply_to, ref})
    ref
  end
  ```
  Returns the ref so caller can track it.
- [ ] **4.3** Run `mix test test/esr/peers/feishu_app_adapter_test.exs`. Most tests pass; some assert old `bootstrap_pending_chat` shape — update.
- [ ] **4.4** Add test: any inbound text starting with `/` triggers `SlashHandler.dispatch/2`.
- [ ] **4.5** `mix test`. Full suite green except known flake.
- [ ] **4.6** Commit: `refactor(faa): route all slashes via SlashHandler.dispatch/2; replace bootstrap_pending_chat with ref-keyed slash_pending_chat`.

### Phase 5 — Local verification (no commit)

- [ ] **5.1** `cd /Users/h2oslabs/Workspace/esr && bash scripts/esrd.sh stop --instance=default` (if running).
- [ ] **5.2** `bash scripts/esrd.sh start --instance=default`.
- [ ] **5.3** Send `/help` to ESR助手 — should return new yaml-driven help text.
- [ ] **5.4** Send `/new-session default name=esr-dev-test root=/Users/h2oslabs/Workspace/esr worktree=smoke-test` — should reach Session.New (today silently fails per the discovered bug).
- [ ] **5.5** Send `/list-agents` — should return agent list (today returns `unknown_kind`).
- [ ] **5.6** `tail ~/.esrd/default/logs/launchd-stdout.log | grep -i slash` — should see `Esr.SlashRoutes` activity, no `bootstrap_pending_chat`.
- [ ] **5.7** Edit `~/.esrd/default/slash-routes.yaml` to add a new test entry (e.g. `/ping → ping kind`); save; immediately try `/ping`; should hot-reload (or fail gracefully if module missing).

### Phase 6 — Death-list deletions

- [ ] **6.1** In `runtime/lib/esr/peers/slash_handler.ex`:
  - Delete `handle_info({:slash_cmd, envelope, reply_to_proxy}, state)`
  - Delete `parse_command/1` + per-command parsers + `tokenize/1` + `parse_kv_pairs/1` + `maybe_put/3` (if used elsewhere, check)
  - Keep generic helpers used by new dispatch path
- [ ] **6.2** In `runtime/lib/esr/peers/feishu_chat_proxy.ex`:
  - Delete `slash?/1` predicate
  - Delete `dispatch_slash/2`
  - Delete the slash branch in the inbound handler
  - FCP becomes purely "forward non-slash to CC session"
- [ ] **6.3** In `runtime/lib/esr/admin/dispatcher.ex`:
  - Delete `@required_permissions` constant (40 LOC)
  - Delete `@command_modules` constant (20 LOC)
  - Replace lookup at line 185: `required = Esr.SlashRoutes.permission_for(kind)`
  - Replace lookup at line 341: `Esr.SlashRoutes.command_module_for(kind)`
- [ ] **6.4** Update `feishu_app_adapter.ex`:
  - Delete `help_text/0`, `whoami_text/3`, `doctor_text/3` private functions (now in command modules)
  - Update doctor/help references in test files
- [ ] **6.5** Delete tests that test the deleted code paths:
  - In `slash_handler_test.exs`: tests asserting `{:slash_cmd, ...}` direct send (replaced by `dispatch/2` tests in Phase 3)
  - In `feishu_app_adapter_test.exs`: tests asserting `bootstrap_pending_chat` shape
- [ ] **6.6** `mix test`. Full green except known flake.
- [ ] **6.7** Commit: `chore(slash): delete legacy slash routing — bypass quartet, FCP slash branch, dispatcher constants`.

### Phase 7 — Doc regen + field note + todo close

- [ ] **7.1** `bash scripts/gen-docs.sh`. Review diff (CLI surface unchanged; runtime channel ref might lose entries if any old `cli:` topics tied to the old paths — verify).
- [ ] **7.2** Create `docs/notes/slash-yaml-routing.md`:
  - Brief retro: why we yaml-ified slash routing (today's `/new-session` silent fail incident)
  - Before/after architecture diagrams (text)
  - Rules for adding a new slash: yaml + command module, no other code
  - Adapter-agnostic property: future Telegram adapter just calls `SlashHandler.dispatch/2`
- [ ] **7.3** Add to `docs/notes/README.md` index.
- [ ] **7.4** Update `docs/futures/todo.md`:
  - Move `task #221` entry from "**Pending — concrete next PRs**" (line ~28, NOT "Pending — design discussions") to "Done — recent" with PR # (TBD at PR creation).
  - `Workshop 2 / 3` candidates stay in their existing "Pending — design discussions" section.
- [ ] **7.5** Commit: `docs: regen + slash-yaml-routing field note + todo close`.

### Phase 8 — PR creation + dev → main flow

- [ ] **8.1** `git push -u origin feature/slash-routes-yaml-impl`.
- [ ] **8.2** `gh pr create --base dev --head feature/slash-routes-yaml-impl --title "PR-21κ: yaml-driven slash routing + adapter-agnostic SlashHandler" --body "..."`. PR body: spec link, "fixes today's silent-fail incident", commit-by-commit changelog.
- [ ] **8.3** CI green (no CI today; manual smoke from Phase 5 stands in).
- [ ] **8.4** `gh pr merge <#> --admin --squash --delete-branch` → merges to dev.
- [ ] **8.5** Sync dev worktree: `( cd ~/Workspace/esr/.claude/worktrees/dev && git pull --ff-only origin dev )`.
- [ ] **8.6** `launchctl kickstart -k gui/$(id -u)/com.ezagent.esrd-dev`. Verify dev esrd runs new code; `/help` returns yaml-driven content.
- [ ] **8.7** Run promote: `( cd ~/Workspace/esr/.claude/worktrees/dev && bash scripts/promote-dev-to-main.sh )` → opens promotion PR.
- [ ] **8.8** FF push to main: `( cd ~/Workspace/esr && git fetch origin && git push origin origin/dev:main )`.
- [ ] **8.9** Sync primary worktree: `git pull --ff-only origin main`.
- [ ] **8.10** `launchctl kickstart -k gui/$(id -u)/com.ezagent.esrd`. Verify prod esrd new code.
- [ ] **8.11** Send `/new-session default name=...` from prod chat to confirm the silent-fail bug is fixed.

### Phase 9 — Final verification + Feishu summary

- [ ] **9.1** Verify dev = main = same SHA (`git ls-remote origin dev main`).
- [ ] **9.2** Send Feishu summary: PR #, before/after architecture summary, "the silent-fail bug found this morning is now fixed", `slash-routes.yaml` location for operator edits.
- [ ] **9.3** Update `docs/futures/todo.md` PR # in the closing entry.

---

## Rollback plan

If commit 4 (Phase 4) verification fails:
- Revert commits 4.x via `git revert`.
- Old slash routing path still works (commits 1-3 are additive).
- The legacy `{:slash_cmd, _}` path in SlashHandler still exists (Phase 6 hasn't deleted it yet).

If commit 6 (death-list) breaks something:
- Revert commit 6.
- Spec stays in place; investigate, refine plan, re-attempt.

If a flake-on-merge surfaces post-merge:
- `gh pr revert <#>` (auto-PR for revert) or manual `git revert`.

## Risks (in addition to spec's)

| Risk | Probability | Impact | Mitigation |
|---|---|---|---|
| Hot-reload misses save events from editors that rename+delete instead of atomic-rename | low | edited yaml not picked up; operator confusion | documented in `docs/notes/slash-yaml-routing.md`; operator workaround `touch <esrd_home>/<env>/slash-routes.yaml` to force refire. See `docs/notes/actor-topology-routing.md` §"Watcher not reacting". |
| `internal_kinds:` block missed during initial yaml population | medium pre-Phase 6, low after | CLI-driven `esr reload` / `esr notify` / `esr cap grant` fail with `unknown_kind` | Phase 1.6 explicitly enumerates all 14 Dispatcher kinds; Phase 6.7 boot test asserts every legacy `Esr.Admin.Commands.*` module has a yaml entry (slashes or internal_kinds) |
| `Esr.SessionRegistry.list_agents/0` not implemented before `/list-agents` slash test | low | Phase 2 fails locally | Phase 2.4a explicitly adds the helper before 2.4b uses it |

## Open issues (carry from spec)

- **Help text categories**: spec open Q1 — need final category list before Phase 2.6. Suggest: `诊断` (help/whoami/doctor), `Workspace` (new-workspace, workspace info, workspace sessions), `Sessions` (new-session, end-session, sessions, list-sessions), `Agents` (list-agents). Yaml `category:` field optional; default "其他".

## Acceptance criteria

This plan is complete when all of the following hold:

1. ✅ `Esr.SlashRoutes` module + `slash-routes.yaml` exist and parse via `FileLoader.load/1`.
2. ✅ `Esr.Peers.SlashHandler.dispatch/2` is the only entry point any adapter calls.
3. ✅ `Esr.Peers.FeishuAppAdapter` has zero hardcoded slash strings.
4. ✅ `Esr.Peers.FeishuChatProxy` doesn't process slashes (only non-slash messages).
5. ✅ `Esr.Admin.Dispatcher` reads from `Esr.SlashRoutes.{permission_for, command_module_for}` (no constants).
6. ✅ `/list-agents` returns agent list (latent bug fixed).
7. ✅ `/new-session default name=foo root=<repo> worktree=branch` from a chat with no live session succeeds (today's bug fixed).
8. ✅ `mix test` green except the known `AdapterChannelNewChainTest` flake.
9. ✅ Hot-reload: edit `slash-routes.yaml`, see immediate effect without esrd restart.
10. ✅ PR admin-merged to dev; FF-promoted to main; dev = main SHA-equal; both esrds restarted on new code.
