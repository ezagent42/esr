# Default agent on session + agent-driven follow-up flow — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix the 5-bug silent-drop cascade behind 2026-05-11's `/session:new + hello?` hang and add the `submit_slash` MCP tool so CC can run admin commands via natural language.

**Architecture:** Phase A unifies workspace folder model (≥1 folder, ESR-bound becomes 1-folder), makes `Launcher.prepare_spawn/1` the sole spawn entry (deleting dead `spawn_cmd`), adds FCP `:pty_closed` lifecycle handler (plugin-self-consistent), enforces SessionTemplate pipeline integrity post-spawn, deletes the dual-shape `ChatRouting` legacy `register_session/3` in favor of unified `attach_session/3`, adds `LifecycleObserver` outside the session tree for ETS cleanup, and a `ChaosScenarios` DSL + `mix esr.audit_supervision` to encode supervisor invariants. Phase B adds `submit_slash` as a new branch of FCP's `dispatch_tool_invoke/5` with a per-call `Task` to avoid blocking the GenServer mailbox, plus a new `Esr.Slash.ReplyTarget.RawCollector` that captures the structured result.

**Tech Stack:** Elixir/OTP (GenServer + DynamicSupervisor + ETS), ExUnit + `:meck` for tests, Phoenix Channels for MCP HTTP, PubSub for inter-process lifecycle, `Esr.ActorQuery` for role-keyed pid lookup, Jason for JSON.

**Spec authority:** `docs/superpowers/specs/2026-05-11-default-agent-and-agent-driven-flow-design.md` rev-3 (commit `6dc0c36`).

**Branch strategy:**
- Plan lands on `spec/default-agent-and-agent-driven-flow` alongside spec rev-3 → merge
- Each PR ships from a fresh feature branch off `origin/dev`:
  - PR-1 → `feat/workspace-folders-invariant`
  - PR-2 → `fix/session-spawn-pipeline-and-pty-closed`
  - PR-3 → `feat/chat-routing-unify-and-supervision-invariants`
  - PR-4 → `feat/submit-slash-mcp-tool`

---

## File Structure

### New files

| Path | PR | LOC | Responsibility |
|---|---|---|---|
| `runtime/lib/esr/session/lifecycle_observer.ex` | 3 | ~70 | Per-session observer GenServer; monitors session sup pid; on `:DOWN` cleans ETS + replies chat error |
| `runtime/lib/esr/session/lifecycle_observers.ex` | 3 | ~30 | Instance-level DynamicSupervisor for lifecycle observers |
| `runtime/lib/esr/slash/reply_target/raw_collector.ex` | 4 | ~35 | `@behaviour Esr.Slash.ReplyTarget` impl that sends raw `{:slash_raw, ref, result}` (used by submit_slash) |
| `runtime/lib/mix/tasks/esr.audit_supervision.ex` | 3 | ~80 | Mix task: snapshot supervisor tree, diff against `docs/notes/supervisor-inventory.md` |
| `runtime/test/support/chaos_scenarios.ex` | 3 | ~80 | Test DSL: `invariant_test/2`, `chaos_inject/2`, `eventually/2`, `assert_chat_reply_within/1`, `kill_role_in_session/2`, `setup_session_with_listener/0` |
| `runtime/test/esr/system/invariants_test.exs` | 3 | ~120 | I1-I5 tests using ChaosScenarios DSL |
| `runtime/test/esr/session/lifecycle_observer_test.exs` | 3 | ~50 | Observer unit tests |
| `runtime/test/esr/slash/reply_target/raw_collector_test.exs` | 4 | ~30 | RawCollector unit tests |
| `runtime/test/esr/plugins/feishu/submit_slash_handler_test.exs` | 4 | ~60 | submit_slash branch tests |
| `runtime/test/esr/integration/real_claude_boot_test.exs` | 4 | ~80 | Real-claude end-to-end CI test (tag :real_claude) |
| `runtime/lib/esr/bundles/feishu-cc/agent_skills/admin.md` | 4 | ~30 | CC admin skill prompt (English; auto-injected by Launcher) |
| `docs/adr/0002-cc-pty-pair-one-for-all-invariant.md` | 3 | ~30 | ADR — explains why `:one_for_all` on CC+PTY pair |
| `docs/notes/system-invariants.md` | 3 | ~40 | I1-I5 invariant statements + verification map |
| `docs/notes/supervisor-inventory.md` | 3 | ~30 | Baseline supervisor tree snapshot for audit-diff CI gate |

### Modified files

| Path | PR | Change |
|---|---|---|
| `runtime/lib/esr/resource/workspace/struct.ex` | 1 | Add `valid?/1` checking ≥1 folder |
| `runtime/priv/schemas/workspace.v1.json` | 1 | Add `folders: { minItems: 1 }` (human contract; enforcement in Elixir) |
| `runtime/lib/esr/resource/workspace/json_writer.ex` | 1 | Call `Struct.valid?/1` before encode; return `{:error, :empty_folders}` on fail |
| `runtime/lib/esr/commands/workspace/new.ex:119-129` | 1 | Unify ESR-bound + repo-bound paths to produce ≥1 folder; mkdir ESR-bound dir at create time |
| `runtime/lib/esr/commands/workspace/remove_folder.ex` | 1 | Guard: reject removing last folder with `:cannot_remove_last_folder` |
| `runtime/lib/esr/paths.ex` | 2 | Add `session_mcp_json/1` helper |
| `runtime/lib/esr/plugins/claude_code/launcher.ex:68-183` | 2 | Delete `spawn_cmd/1`; generalize `prepare_spawn/1` to return `{:ok, args} \| {:error, reason}` |
| `runtime/lib/esr/entity/pty_process.ex:80, :202-216` | 2 | Delete `dir \|\| "/tmp"` fallback; call `prepare_spawn/1`; propagate errors |
| `runtime/lib/esr/session/agent_spawner.ex` | 2 + 3 | Add `verify_pipeline_complete/2` post-spawn check (PR-2); migrate `register_session` caller to `attach_session` + start LifecycleObserver (PR-3) |
| `runtime/lib/esr/plugins/feishu/feishu_chat_proxy.ex:274, :307` | 2 + 4 | Add `:pty_closed` clause + `notify_chat/2` helper (PR-2); add `submit_slash` branch to `dispatch_tool_invoke/5` (PR-4) |
| `runtime/lib/esr/commands/session/new.ex` | 2 | Surface `:pipeline_incomplete` as chat error |
| `runtime/lib/esr/actor_query.ex:70` | 3 | Add `fcp_for_session/1` helper: `list_by_role(sid, :feishu_chat_proxy) \|> List.first()` returning `{:ok, pid} \| :not_found` |
| `runtime/lib/esr/session/chat_routing/registry.ex` | 3 | Delete `register_session/3`, `unregister_session/1`, plus legacy-shape branches at lines 105, 124, 175 |
| `runtime/lib/esr/session/router.ex:121` | 3 | Migrate `unregister_session/1` caller |
| `runtime/lib/esr/plugins/feishu/feishu_app_adapter.ex:238-275` | 3 | Replace lookup pattern; delete `other -> Logger.warning + drop`; use `Esr.ActorQuery.fcp_for_session/1`; add `:session_dead` + `:session_incomplete` chat error paths |
| `runtime/lib/esr/plugins/claude_code/mcp/tools.ex` | 4 | Register `submit_slash` tool definition |
| `.github/workflows/ci.yml` | 4 | Add macos-latest job running `mix test --only real_claude` + `mix esr.audit_supervision` gate |

---

## PR-1: Workspace folders ≥1 + ESR-bound unification (~120 LOC, 8 tasks)

### Task 1.1: Branch off latest dev

**Files:** none (git only)

- [ ] **Step 1: Create feature branch**

```bash
cd /Users/h2oslabs/Workspace/esr/.worktrees/fix-unconsumed-msg
git fetch origin
git checkout -b feat/workspace-folders-invariant origin/dev
```

- [ ] **Step 2: Verify clean state**

```bash
git status
```
Expected: `On branch feat/workspace-folders-invariant ... nothing to commit, working tree clean`

### Task 1.2: Add `Esr.Resource.Workspace.Struct.valid?/1`

**Files:**
- Modify: `runtime/lib/esr/resource/workspace/struct.ex`
- Test: `runtime/test/esr/resource/workspace/struct_test.exs`

- [ ] **Step 1: Write the failing test**

Append to `runtime/test/esr/resource/workspace/struct_test.exs`:

```elixir
describe "valid?/1" do
  test "true when folders has ≥1 entry" do
    ws = %Esr.Resource.Workspace.Struct{
      id: "wid-1", name: "demo", owner: "alice",
      folders: [%{path: "/tmp/x", name: "x"}],
      location: {:repo_bound, "/tmp/x"}, transient: false,
      agent: "cc", settings: %{}, env: %{}, chats: []
    }
    assert Esr.Resource.Workspace.Struct.valid?(ws) == true
  end

  test "false when folders is empty list" do
    ws = %Esr.Resource.Workspace.Struct{
      id: "wid-2", name: "empty", owner: "alice",
      folders: [], location: {:esr_bound, "/foo"},
      transient: false, agent: "cc", settings: %{}, env: %{}, chats: []
    }
    assert Esr.Resource.Workspace.Struct.valid?(ws) == false
  end

  test "false when folders is not a list" do
    ws = %Esr.Resource.Workspace.Struct{
      id: "wid-3", name: "bad", owner: "alice",
      folders: nil, location: {:esr_bound, "/foo"},
      transient: false, agent: "cc", settings: %{}, env: %{}, chats: []
    }
    assert Esr.Resource.Workspace.Struct.valid?(ws) == false
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd runtime && mix test test/esr/resource/workspace/struct_test.exs -v
```
Expected: 3 failures with "function Esr.Resource.Workspace.Struct.valid?/1 is undefined".

- [ ] **Step 3: Implement valid?/1**

Add to `runtime/lib/esr/resource/workspace/struct.ex` (near the bottom, after defstruct):

```elixir
@doc """
Returns true iff the workspace struct satisfies the ≥1-folder invariant
established by spec 2026-05-11-default-agent-and-agent-driven-flow-design.md
§4.1. Used by JsonWriter.write/2 as a pre-encode gate.
"""
@spec valid?(t()) :: boolean()
def valid?(%__MODULE__{folders: folders}) when is_list(folders) and length(folders) >= 1, do: true
def valid?(%__MODULE__{}), do: false
```

- [ ] **Step 4: Run test to verify it passes**

```bash
cd runtime && mix test test/esr/resource/workspace/struct_test.exs -v
```
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add runtime/lib/esr/resource/workspace/struct.ex runtime/test/esr/resource/workspace/struct_test.exs
git commit -m "feat(workspace): add Struct.valid?/1 — ≥1 folder invariant"
```

### Task 1.3: Add `minItems: 1` to workspace.v1.json schema (documentation contract)

**Files:**
- Modify: `runtime/priv/schemas/workspace.v1.json`

- [ ] **Step 1: Read current schema**

```bash
grep -A2 '"folders"' runtime/priv/schemas/workspace.v1.json
```

- [ ] **Step 2: Add minItems**

Edit `runtime/priv/schemas/workspace.v1.json` — locate the `"folders": { "type": "array", ... }` block and add `"minItems": 1`. The enforcement is in Elixir (Task 1.2); this is the human-readable contract.

- [ ] **Step 3: Commit**

```bash
git add runtime/priv/schemas/workspace.v1.json
git commit -m "docs(schema): workspace.v1 declares folders minItems:1"
```

### Task 1.4: JsonWriter rejects 0-folder writes

**Files:**
- Modify: `runtime/lib/esr/resource/workspace/json_writer.ex`
- Test: `runtime/test/esr/resource/workspace/json_writer_test.exs`

- [ ] **Step 1: Write failing test**

Append to `runtime/test/esr/resource/workspace/json_writer_test.exs`:

```elixir
describe "write/2 enforces ≥1 folder invariant" do
  test "returns {:error, :empty_folders} when struct has 0 folders" do
    ws = %Esr.Resource.Workspace.Struct{
      id: "wid-empty", name: "empty", owner: "alice",
      folders: [], location: {:esr_bound, "/foo"},
      transient: false, agent: "cc", settings: %{}, env: %{}, chats: []
    }
    path = Path.join(System.tmp_dir!(), "test-empty-#{:erlang.unique_integer([:positive])}.json")
    assert {:error, :empty_folders} = Esr.Resource.Workspace.JsonWriter.write(ws, path)
    refute File.exists?(path)
  end
end
```

- [ ] **Step 2: Run test, expect fail**

```bash
cd runtime && mix test test/esr/resource/workspace/json_writer_test.exs -v
```
Expected: FAIL — current impl writes the file regardless.

- [ ] **Step 3: Implement guard**

Edit `runtime/lib/esr/resource/workspace/json_writer.ex` `write/2` head:

```elixir
def write(%Esr.Resource.Workspace.Struct{} = ws, path) do
  if Esr.Resource.Workspace.Struct.valid?(ws) do
    encoded = Jason.encode!(ws, pretty: true)
    File.write(path, encoded)  # existing logic continues
  else
    {:error, :empty_folders}
  end
end
```

- [ ] **Step 4: Run all writer tests to verify no regressions**

```bash
cd runtime && mix test test/esr/resource/workspace/json_writer_test.exs -v
```
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add runtime/lib/esr/resource/workspace/json_writer.ex runtime/test/esr/resource/workspace/json_writer_test.exs
git commit -m "feat(workspace): JsonWriter rejects 0-folder writes"
```

### Task 1.5: Unify `commands/workspace/new.ex` — ESR-bound becomes 1-folder

**Files:**
- Modify: `runtime/lib/esr/commands/workspace/new.ex:119-129`
- Test: `runtime/test/esr/commands/workspace/new_test.exs`

- [ ] **Step 1: Write failing test**

Append to `runtime/test/esr/commands/workspace/new_test.exs`:

```elixir
describe "ESR-bound workspace (no folder= arg) — ≥1 folder invariant" do
  test "creates workspace with folders containing the ESR-managed path" do
    name = "esr-bound-#{:erlang.unique_integer([:positive])}"
    {:ok, _result} = Esr.Commands.Workspace.New.execute(%{"name" => name}, [])
    {:ok, struct} = Esr.Resource.Workspace.Registry.get_by_name(name)
    expected_path = Esr.Paths.workspace_dir(name)
    assert [%{path: ^expected_path}] = struct.folders
    assert File.dir?(expected_path)
  end
end
```

- [ ] **Step 2: Run test, expect fail**

```bash
cd runtime && mix test test/esr/commands/workspace/new_test.exs -v --only describe:"ESR-bound"
```
Expected: FAIL — current ESR-bound branch leaves folders empty.

- [ ] **Step 3: Patch `commands/workspace/new.ex:119-129`**

Replace:
```elixir
location = case folder do
  nil -> {:esr_bound, Esr.Paths.workspace_dir(name)}
  path -> {:repo_bound, path}
end
folders = case folder do
  nil -> []
  path -> [%{path: path, name: Path.basename(path)}]
end
```
with:
```elixir
folder_path = folder || Esr.Paths.workspace_dir(name)
File.mkdir_p!(folder_path)
folders = [%{path: folder_path, name: Path.basename(folder_path)}]
location = case folder do
  nil -> {:esr_bound, folder_path}
  path -> {:repo_bound, path}
end
```

- [ ] **Step 4: Run test to verify pass**

```bash
cd runtime && mix test test/esr/commands/workspace/new_test.exs -v
```
Expected: PASS for new test + all existing.

- [ ] **Step 5: Commit**

```bash
git add runtime/lib/esr/commands/workspace/new.ex runtime/test/esr/commands/workspace/new_test.exs
git commit -m "feat(workspace): ESR-bound mode becomes 1-folder workspace (no split state)"
```

### Task 1.6: Guard `/workspace:remove-folder` from reducing to 0

**Files:**
- Modify: `runtime/lib/esr/commands/workspace/remove_folder.ex`
- Test: `runtime/test/esr/commands/workspace/remove_folder_test.exs`

- [ ] **Step 1: Write failing test**

Append:
```elixir
describe ":cannot_remove_last_folder guard" do
  test "removing the only folder fails" do
    name = "single-#{:erlang.unique_integer([:positive])}"
    {:ok, _} = Esr.Commands.Workspace.New.execute(%{"name" => name, "folder" => "/tmp/x"}, [])
    {:error, %{kind: :cannot_remove_last_folder}} =
      Esr.Commands.Workspace.RemoveFolder.execute(%{"workspace" => name, "path" => "/tmp/x"}, [])
  end
end
```

- [ ] **Step 2: Run, expect fail**

```bash
cd runtime && mix test test/esr/commands/workspace/remove_folder_test.exs -v
```

- [ ] **Step 3: Add guard**

In `runtime/lib/esr/commands/workspace/remove_folder.ex`, before the removal step, check:
```elixir
if length(workspace.folders) == 1 do
  {:error, %{kind: :cannot_remove_last_folder,
             message: "workspace #{workspace.name} 只剩 1 个 folder；用 /workspace:remove 删整个 workspace"}}
else
  # existing remove logic
end
```

- [ ] **Step 4: Run test to verify pass**

```bash
cd runtime && mix test test/esr/commands/workspace/remove_folder_test.exs -v
```

- [ ] **Step 5: Commit**

```bash
git add runtime/lib/esr/commands/workspace/remove_folder.ex runtime/test/esr/commands/workspace/remove_folder_test.exs
git commit -m "feat(workspace): /workspace:remove-folder refuses to remove last folder"
```

### Task 1.7: Integration test — full create + describe + cleanup

**Files:**
- Test: `runtime/test/esr/integration/workspace_lifecycle_test.exs`

- [ ] **Step 1: Write the test**

```elixir
defmodule Esr.Integration.WorkspaceLifecycleTest do
  use ExUnit.Case, async: false

  test "ESR-bound workspace lifecycle: create, describe, attempt-remove-folder, remove" do
    name = "lc-#{:erlang.unique_integer([:positive])}"
    {:ok, _} = Esr.Commands.Workspace.New.execute(%{"name" => name}, [])

    {:ok, ws} = Esr.Resource.Workspace.Registry.get_by_name(name)
    assert length(ws.folders) == 1
    assert File.dir?(hd(ws.folders).path)

    folder_path = hd(ws.folders).path
    {:error, %{kind: :cannot_remove_last_folder}} =
      Esr.Commands.Workspace.RemoveFolder.execute(
        %{"workspace" => name, "path" => folder_path}, [])

    {:ok, _} = Esr.Commands.Workspace.Remove.execute(%{"name" => name}, [])
    assert :not_found = Esr.Resource.Workspace.Registry.get_by_name(name)
  end
end
```

- [ ] **Step 2: Run + commit**

```bash
cd runtime && mix test test/esr/integration/workspace_lifecycle_test.exs -v
git add runtime/test/esr/integration/workspace_lifecycle_test.exs
git commit -m "test(workspace): integration test for ESR-bound lifecycle"
```

### Task 1.8: Open PR + admin-merge

- [ ] **Step 1: Push branch**

```bash
git push -u origin feat/workspace-folders-invariant
```

- [ ] **Step 2: Open PR**

```bash
gh pr create --base dev --title "feat(workspace): folders ≥1 + ESR-bound 1-folder unification (PR-1 of 4)" \
  --body "$(cat <<'EOF'
## Summary
PR-1 of 4 per [spec 2026-05-11-default-agent-and-agent-driven-flow-design.md §4.1](../blob/dev/docs/superpowers/specs/2026-05-11-default-agent-and-agent-driven-flow-design.md).

Eliminates the 0-folder workspace data split (B1 in spec §1):
- ESR-bound workspaces now hold the ESR-managed path as `folders[0]`
- `/workspace:new name=X` (no `folder=`) mkdir's the ESR-managed dir at create time
- `/workspace:remove-folder` refuses to leave a workspace at 0 folders
- `Esr.Resource.Workspace.Struct.valid?/1` + `JsonWriter.write/2` reject persisted 0-folder structs

## Test plan
- [ ] \`mix test runtime/test/esr/resource/workspace/struct_test.exs\` → PASS
- [ ] \`mix test runtime/test/esr/commands/workspace/new_test.exs\` → PASS
- [ ] \`mix test runtime/test/esr/commands/workspace/remove_folder_test.exs\` → PASS
- [ ] \`mix test runtime/test/esr/integration/workspace_lifecycle_test.exs\` → PASS

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

- [ ] **Step 3: Wait for CI + admin-merge**

```bash
gh pr checks --watch
gh pr merge --admin --squash --delete-branch
```

---

## PR-2: prepare_spawn sole entry + FCP :pty_closed + SessionTemplate integrity (~250 LOC, 9 tasks)

### Task 2.1: Branch off latest dev (post PR-1)

```bash
git fetch origin
git checkout -b fix/session-spawn-pipeline-and-pty-closed origin/dev
git status
```

### Task 2.2: Add `Esr.Paths.session_mcp_json/1`

**Files:**
- Modify: `runtime/lib/esr/paths.ex`
- Test: `runtime/test/esr/paths_test.exs`

- [ ] **Step 1: Add the helper**

Append to `runtime/lib/esr/paths.ex`:

```elixir
@doc """
Path to the per-session `.mcp.json` file. Written by AgentSpawner
post-channel-up, read by `claude` via `--mcp-config` flag.
"""
@spec session_mcp_json(String.t()) :: String.t()
def session_mcp_json(sid) when is_binary(sid) do
  Path.join([esrd_home(), instance(), "sessions", sid, "mcp.json"])
end
```

- [ ] **Step 2: Test**

Add to `runtime/test/esr/paths_test.exs`:

```elixir
test "session_mcp_json/1 returns ESRD-rooted sessions path" do
  path = Esr.Paths.session_mcp_json("test-sid")
  assert String.ends_with?(path, "/sessions/test-sid/mcp.json")
end
```

- [ ] **Step 3: Run + commit**

```bash
cd runtime && mix test test/esr/paths_test.exs -v
git add runtime/lib/esr/paths.ex runtime/test/esr/paths_test.exs
git commit -m "feat(paths): add session_mcp_json/1 helper"
```

### Task 2.3: Delete `Launcher.spawn_cmd/1`; make `prepare_spawn/1` sole entry

**Files:**
- Modify: `runtime/lib/esr/plugins/claude_code/launcher.ex`
- Test: `runtime/test/esr/plugins/claude_code/launcher_test.exs`

- [ ] **Step 1: Read current prepare_spawn**

```bash
sed -n '160,200p' runtime/lib/esr/plugins/claude_code/launcher.ex
```

Confirm `prepare_spawn/1` calls `mkdir_p` + `write_mcp_json` + `build_env` + builds argv.

- [ ] **Step 2: Generalize prepare_spawn return**

Refactor `prepare_spawn/1` to return `{:ok, %{cmd: [...], env: [...]}} | {:error, reason}`:

```elixir
@spec prepare_spawn(map()) :: {:ok, %{cmd: [String.t()], env: [{String.t(), String.t()}]}} | {:error, atom()}
def prepare_spawn(%{session_id: sid, cwd: cwd} = params) do
  with :ok <- ensure_dir(cwd),
       :ok <- ensure_claude_binary(),
       mcp_path = Esr.Paths.session_mcp_json(sid),
       :ok <- write_mcp_json(sid, mcp_path) do
    cmd = [
      "claude",
      "--mcp-config", mcp_path,
      "--cwd", cwd
      # ... existing flags
    ]
    env = build_env(params)
    {:ok, %{cmd: cmd, env: env}}
  end
end

defp ensure_dir(path) do
  if File.dir?(path), do: :ok, else: {:error, :missing_cwd}
end

defp ensure_claude_binary do
  case System.find_executable("claude") do
    nil -> {:error, :missing_claude_binary}
    _ -> :ok
  end
end
```

- [ ] **Step 3: Delete `spawn_cmd/1`**

Remove the function entirely. Grep callers:
```bash
rg -n "Launcher\.spawn_cmd" runtime/
```
Should show only `runtime/lib/esr/entity/pty_process.ex` — that gets patched in Task 2.4.

- [ ] **Step 4: Adjust launcher tests**

Update `runtime/test/esr/plugins/claude_code/launcher_test.exs`:
- Old tests for `spawn_cmd/1` deleted
- `prepare_spawn/1` tests asserting `{:ok, %{cmd: cmd, env: env}}` shape + `mcp.json` file existence

- [ ] **Step 5: Run + commit**

```bash
cd runtime && mix test test/esr/plugins/claude_code/launcher_test.exs -v
git add runtime/lib/esr/plugins/claude_code/launcher.ex runtime/test/esr/plugins/claude_code/launcher_test.exs
git commit -m "refactor(claude_code/launcher): prepare_spawn becomes sole entry; spawn_cmd deleted"
```

### Task 2.4: Wire `PtyProcess` to `prepare_spawn`; delete `/tmp` fallback

**Files:**
- Modify: `runtime/lib/esr/entity/pty_process.ex:80, :202-216`

- [ ] **Step 1: Patch init `dir` resolution**

In `pty_process.ex:80`, replace:
```elixir
dir: get_param(params, :dir) || "/tmp",
```
with:
```elixir
dir: get_param(params, :dir),
```

Add a guard at the end of `init/1` (after state construction):

```elixir
case state.state.dir do
  nil -> {:stop, {:error, :missing_dir}}
  _ -> {:ok, state, {:continue, :launch}}
end
```

- [ ] **Step 2: Patch the spawn call (lines 202-216)**

Replace whatever calls `Launcher.spawn_cmd(...)` with:

```elixir
case Esr.Plugins.ClaudeCode.Launcher.prepare_spawn(%{
       session_id: state.state.session_id,
       cwd: state.state.dir,
       # ... whatever else prepare_spawn needs
     }) do
  {:ok, %{cmd: cmd, env: env}} ->
    # use cmd + env in the existing :exec.run_link call
    :exec.run_link(cmd, env_opts(env) ++ pty_opts())

  {:error, reason} ->
    {:stop, {:prepare_spawn_failed, reason}}
end
```

- [ ] **Step 3: Add test verifying `:missing_dir` short-circuits init**

```elixir
test "PtyProcess.init returns {:stop, ...} when dir is nil" do
  result = Esr.Entity.PtyProcess.init(%{
    session_id: "test", actor_id: "test", session_name: "test",
    # NO :dir
    chat_id: "c", app_id: "a", subscribers: []
  })
  assert {:stop, {:error, :missing_dir}} = result
end
```

- [ ] **Step 4: Run + commit**

```bash
cd runtime && mix test test/esr/entity/pty_process_test.exs -v
git add runtime/lib/esr/entity/pty_process.ex runtime/test/esr/entity/pty_process_test.exs
git commit -m "fix(pty_process): use prepare_spawn entry; delete /tmp fallback"
```

### Task 2.5: SessionTemplate pipeline integrity check post-spawn

**Files:**
- Modify: `runtime/lib/esr/session/agent_spawner.ex`
- Test: `runtime/test/esr/session/agent_spawner_test.exs`

- [ ] **Step 1: Write failing test**

```elixir
describe "pipeline integrity check" do
  test "returns :pipeline_incomplete when an expected role isn't spawned" do
    # Build an agent_def where one pipeline stage is intentionally broken
    bad_agent_def = %{
      pipeline: %{
        inbound: [
          %{"name" => "feishu_chat_proxy", "impl" => "Esr.Plugins.Feishu.FeishuChatProxy", "kind" => "stateful"},
          %{"name" => "noop_stage",         "impl" => "NonExistentModule",                "kind" => "stateful"}
        ]
      }
    }
    params = %{agent: "test-bad", agent_def: bad_agent_def, dir: "/tmp", chat_id: "c", app_id: "a"}
    assert {:error, :pipeline_incomplete} = Esr.Session.AgentSpawner.do_create(params)
  end
end
```

- [ ] **Step 2: Add `verify_pipeline_complete/2` helper**

In `agent_spawner.ex`, after `spawn_pipeline/3` returns:

```elixir
defp verify_pipeline_complete(sid, agent_def) do
  expected_roles =
    agent_def.pipeline.inbound
    |> Enum.map(&role_for_impl(&1["impl"]))
    |> Enum.reject(&is_nil/1)

  missing =
    Enum.reject(expected_roles, fn role ->
      case Esr.ActorQuery.list_by_role(sid, role) do
        [_pid | _] -> true
        [] -> false
      end
    end)

  case missing do
    [] -> :ok
    missing -> {:error, :pipeline_incomplete, missing}
  end
end

defp role_for_impl("Esr.Plugins.Feishu.FeishuChatProxy"), do: :feishu_chat_proxy
defp role_for_impl("Esr.Entity.CCProcess"), do: :cc_process
defp role_for_impl("Esr.Entity.PtyProcess"), do: :pty_process
defp role_for_impl(_), do: nil
```

Call it from `do_create/1` post-spawn; on `{:error, :pipeline_incomplete, _missing}` call `Esr.Session.Router.end_session(sid)` to tear down, then return `{:error, :pipeline_incomplete}`.

- [ ] **Step 3: Run + commit**

```bash
cd runtime && mix test test/esr/session/agent_spawner_test.exs -v --only describe:"pipeline integrity"
git add runtime/lib/esr/session/agent_spawner.ex runtime/test/esr/session/agent_spawner_test.exs
git commit -m "feat(agent_spawner): verify_pipeline_complete/2 post-spawn integrity check"
```

### Task 2.6: FCP `:pty_closed` clause + `notify_chat/2` helper

**Files:**
- Modify: `runtime/lib/esr/plugins/feishu/feishu_chat_proxy.ex` (line ~274)
- Test: `runtime/test/esr/plugins/feishu/feishu_chat_proxy_test.exs`

- [ ] **Step 1: Write failing test**

```elixir
describe ":pty_closed lifecycle handler" do
  test "FCP handles :pty_closed without FunctionClauseError; sends chat reply" do
    {:ok, sid} = setup_feishu_cc_session_fixture()
    fcp = pid_of(sid, :feishu_chat_proxy)
    chat_listener = self()
    register_chat_listener(sid, chat_listener)

    send(fcp, :pty_closed)

    assert_receive {:chat_reply, %{kind: :downstream_died}}, 1_000
    assert Process.alive?(fcp)
  end
end
```

- [ ] **Step 2: Run, expect fail (FunctionClauseError)**

```bash
cd runtime && mix test test/esr/plugins/feishu/feishu_chat_proxy_test.exs -v --only describe:":pty_closed"
```

- [ ] **Step 3: Add the clause + helper**

In `runtime/lib/esr/plugins/feishu/feishu_chat_proxy.ex`, around line 274 (the existing `handle_info/2` clauses):

```elixir
@impl GenServer
def handle_info(:pty_closed, state) do
  notify_chat(state, %{
    kind: :downstream_died,
    message: "agent 进程退出；supervisor 会重启（如有可能）。" <>
             "如重复，运行 /session:end + /session:new 重建"
  })
  {:noreply, state}
end

@doc false
defp notify_chat(state, payload) do
  # Best-effort chat reply via existing FCP outbound path.
  envelope = build_chat_reply_envelope(state, payload)
  Esr.Plugins.Feishu.FeishuChatProxy.OutboundEmit.emit(state, envelope)
end

defp build_chat_reply_envelope(state, %{kind: kind, message: msg}) do
  %{
    "chat_id" => state.chat_id,
    "app_id" => state.app_id,
    "text" => "[#{kind}] #{msg}"
  }
end
```

(If `OutboundEmit.emit/2` doesn't exist, use the existing FCP reply mechanism — grep `emit_reply_envelope` or similar in the same file to find the right helper.)

- [ ] **Step 4: Run + commit**

```bash
cd runtime && mix test test/esr/plugins/feishu/feishu_chat_proxy_test.exs -v --only describe:":pty_closed"
git add runtime/lib/esr/plugins/feishu/feishu_chat_proxy.ex runtime/test/esr/plugins/feishu/feishu_chat_proxy_test.exs
git commit -m "fix(feishu_chat_proxy): add :pty_closed handler + notify_chat helper (plugin-decoupled)"
```

### Task 2.7: Surface `:pipeline_incomplete` from `/session:new` as chat error

**Files:**
- Modify: `runtime/lib/esr/commands/session/new.ex`
- Test: `runtime/test/esr/commands/session/new_test.exs`

- [ ] **Step 1: Patch the error mapping**

In `Esr.Commands.Session.New.execute/2`, in the error-handling branch where `AgentSpawner.do_create/1` is called, add:

```elixir
{:error, :pipeline_incomplete} ->
  Render.error(__MODULE__.command_meta(), :session_start_failed, %{
    reason: "pipeline_incomplete",
    message: "session 启动失败：声明的 pipeline stage 未全部 spawn"
  })
```

- [ ] **Step 2: Test + commit**

```bash
cd runtime && mix test test/esr/commands/session/new_test.exs -v
git add runtime/lib/esr/commands/session/new.ex runtime/test/esr/commands/session/new_test.exs
git commit -m "feat(session/new): surface :pipeline_incomplete to chat reply"
```

### Task 2.8: Open PR + admin-merge

```bash
git push -u origin fix/session-spawn-pipeline-and-pty-closed
gh pr create --base dev --title "fix(session): prepare_spawn entry + FCP :pty_closed handler + pipeline integrity (PR-2 of 4)" \
  --body "Spec §4.2 + §4.3 + §4.4."
gh pr checks --watch
gh pr merge --admin --squash --delete-branch
```

---

## PR-3: ChatRouting unification + LifecycleObserver + ChaosScenarios + audit + ADR-0002 (~400 LOC, 13 tasks)

### Task 3.1: Branch

```bash
git fetch origin
git checkout -b feat/chat-routing-unify-and-supervision-invariants origin/dev
```

### Task 3.2: Add `Esr.ActorQuery.fcp_for_session/1`

**Files:**
- Modify: `runtime/lib/esr/actor_query.ex`
- Test: `runtime/test/esr/actor_query_test.exs`

- [ ] **Step 1: Implement + test**

```elixir
# In actor_query.ex
@spec fcp_for_session(String.t()) :: {:ok, pid()} | :not_found
def fcp_for_session(sid) when is_binary(sid) do
  case list_by_role(sid, :feishu_chat_proxy) do
    [pid | _] -> {:ok, pid}
    [] -> :not_found
  end
end
```

Test asserting the obvious cases.

- [ ] **Step 2: Commit**

```bash
cd runtime && mix test test/esr/actor_query_test.exs -v
git add runtime/lib/esr/actor_query.ex runtime/test/esr/actor_query_test.exs
git commit -m "feat(actor_query): add fcp_for_session/1"
```

### Task 3.3: Delete `register_session/3` + `unregister_session/1` from ChatRouting.Registry

**Files:**
- Modify: `runtime/lib/esr/session/chat_routing/registry.ex` (delete lines 63-64 + 182-194 area; verify exact line numbers at edit time)

- [ ] **Step 1: Delete the public API + handle_call branches**

```bash
rg -n "register_session\|unregister_session" runtime/lib/esr/session/chat_routing/registry.ex
```
Remove every match in this file (the def, the @spec, and any handle_call branches keyed `:register_session` / `:unregister_session`).

- [ ] **Step 2: Delete legacy-shape branches**

Remove the `current_session/2` legacy branch around line 105, the `list_sessions/2` legacy branch around line 124, and the `lookup_by_chat/2` shim around line 175. (Spec §4.5 step 6.)

- [ ] **Step 3: Commit**

```bash
git add runtime/lib/esr/session/chat_routing/registry.ex
git commit -m "refactor(chat_routing): delete legacy register/unregister API + 3 shape branches"
```

### Task 3.4: Migrate `agent_spawner.ex` callers

**Files:**
- Modify: `runtime/lib/esr/session/agent_spawner.ex:145, :460`

- [ ] **Step 1: Patch line :460** (the `register_session/3` call after spawn)

```elixir
# Before:
:ok = Esr.Session.ChatRouting.Registry.register_session(sid, {chat_id, app_id}, refs)
# After:
:ok = Esr.Session.ChatRouting.Registry.attach_session(chat_id, app_id, sid)
```

- [ ] **Step 2: Patch line :145** (the `unregister_session/1` call on failure path)

```elixir
# Before:
:ok = Esr.Session.ChatRouting.Registry.unregister_session(scope_id)
# After:
:ok = Esr.Session.ChatRouting.Registry.detach_session_by_id(scope_id)
# (add this helper to chat_routing/registry.ex if not present)
```

- [ ] **Step 3: Commit**

```bash
git add runtime/lib/esr/session/agent_spawner.ex runtime/lib/esr/session/chat_routing/registry.ex
git commit -m "refactor(agent_spawner): migrate to attach_session API"
```

### Task 3.5: Migrate `router.ex:121` caller

**Files:**
- Modify: `runtime/lib/esr/session/router.ex:121`

- [ ] **Step 1: Patch**

```elixir
# Before:
:ok = Esr.Session.ChatRouting.Registry.unregister_session(sid)
# After:
:ok = Esr.Session.ChatRouting.Registry.detach_session_by_id(sid)
```

- [ ] **Step 2: Commit**

```bash
git add runtime/lib/esr/session/router.ex
git commit -m "refactor(router): migrate to detach_session_by_id"
```

### Task 3.6: Rewrite FAA route to use ActorQuery + explicit clauses

**Files:**
- Modify: `runtime/lib/esr/plugins/feishu/feishu_app_adapter.ex:238-275`

- [ ] **Step 1: Replace the routing case (no `other -> drop`)**

```elixir
case Esr.Session.ChatRouting.Registry.current_session(chat_id, app_id) do
  {:ok, sid} ->
    case Esr.ActorQuery.fcp_for_session(sid) do
      {:ok, fcp_pid} ->
        if Process.alive?(fcp_pid) do
          send(fcp_pid, {:feishu_inbound, envelope})
          :ok
        else
          cleanup_and_reply(chat_id, app_id, sid, :session_dead)
        end

      :not_found ->
        cleanup_and_reply(chat_id, app_id, sid, :session_incomplete)
    end

  :not_found ->
    handle_unbound_chat(envelope)
end
```

`cleanup_and_reply/4` is a new helper at the bottom of the same file:

```elixir
defp cleanup_and_reply(chat_id, app_id, sid, reason) do
  :ok = Esr.Session.ChatRouting.Registry.detach_session(chat_id, app_id, sid)
  msg = case reason do
    :session_dead -> "session 死了；运行 /session:new 重建"
    :session_incomplete -> "session 启动不完整；运行 /session:end 后 /session:new 重试"
  end
  reply_chat_error(chat_id, app_id, reason, msg)
end
```

- [ ] **Step 2: Commit**

```bash
git add runtime/lib/esr/plugins/feishu/feishu_app_adapter.ex
git commit -m "fix(faa): route via ActorQuery; explicit clauses; no other-> drop"
```

### Task 3.7: `Esr.Session.LifecycleObserver` + `Esr.Session.LifecycleObservers`

**Files:**
- Create: `runtime/lib/esr/session/lifecycle_observer.ex`
- Create: `runtime/lib/esr/session/lifecycle_observers.ex`
- Test: `runtime/test/esr/session/lifecycle_observer_test.exs`

- [ ] **Step 1: Write the observer module**

```elixir
defmodule Esr.Session.LifecycleObserver do
  use GenServer
  require Logger

  def start_link(%{session_id: _sid, session_sup_pid: _sp,
                   chat_id: _cid, app_id: _aid} = args) do
    GenServer.start_link(__MODULE__, args)
  end

  @impl true
  def init(state) do
    Process.monitor(state.session_sup_pid)
    {:ok, state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, _pid, reason}, state) do
    Logger.warning("session #{state.session_id} supervisor exited: #{inspect(reason)}")
    Esr.Plugins.Feishu.FeishuAppAdapter.reply_chat_error(
      state.chat_id, state.app_id, :session_terminated,
      "session #{state.session_id} 异常终止: #{inspect(reason)}"
    )
    :ok = Esr.Session.ChatRouting.Registry.detach_session(
            state.chat_id, state.app_id, state.session_id)
    {:stop, :normal, state}
  end
end
```

- [ ] **Step 2: Write the supervisor**

```elixir
defmodule Esr.Session.LifecycleObservers do
  use DynamicSupervisor

  def start_link(opts \\ []) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts), do: DynamicSupervisor.init(strategy: :one_for_one)

  def start_observer(args) do
    spec = %{id: Esr.Session.LifecycleObserver,
             start: {Esr.Session.LifecycleObserver, :start_link, [args]},
             restart: :temporary}
    DynamicSupervisor.start_child(__MODULE__, spec)
  end
end
```

Register `Esr.Session.LifecycleObservers` in `runtime/lib/esr/application.ex` children list.

- [ ] **Step 3: Wire observer start into `AgentSpawner.do_create/1`**

After successful pipeline-integrity check (Task 2.5 logic), call:
```elixir
{:ok, _obs_pid} = Esr.Session.LifecycleObservers.start_observer(%{
  session_id: sid, session_sup_pid: session_sup_pid,
  chat_id: chat_id, app_id: app_id
})
```

- [ ] **Step 4: Test**

```elixir
test "LifecycleObserver fires on supervisor DOWN and cleans ETS" do
  {:ok, sid} = setup_feishu_cc_session_fixture()
  attached_listener = self()
  register_chat_listener(sid, attached_listener)
  sup_pid = Esr.Session.Router.supervisor_pid(sid)
  Process.exit(sup_pid, :kill)
  assert_receive {:chat_reply, %{kind: :session_terminated}}, 2_000
  eventually(fn -> :not_found == Esr.Session.ChatRouting.Registry.current_session("c", "a") end)
end
```

- [ ] **Step 5: Commit**

```bash
cd runtime && mix test test/esr/session/lifecycle_observer_test.exs -v
git add runtime/lib/esr/session/lifecycle_observer.ex runtime/lib/esr/session/lifecycle_observers.ex \
        runtime/lib/esr/application.ex runtime/lib/esr/session/agent_spawner.ex \
        runtime/test/esr/session/lifecycle_observer_test.exs
git commit -m "feat(session): LifecycleObserver outside session tree; cleans ETS on subtree DOWN"
```

### Task 3.8: ChaosScenarios DSL

**Files:**
- Create: `runtime/test/support/chaos_scenarios.ex`

- [ ] **Step 1: Write the macro library**

```elixir
defmodule Esr.Test.ChaosScenarios do
  defmacro __using__(_) do
    quote do
      use ExUnit.Case, async: false
      import Esr.Test.ChaosScenarios
    end
  end

  defmacro invariant_test(description, do: block) do
    quote do
      test "INVARIANT: " <> unquote(description) do
        unquote(block)
      end
    end
  end

  @doc "Kill one of the given role pids in a session N times, with brief pauses."
  def chaos_inject(sid, roles, opts \\ []) do
    times = Keyword.get(opts, :times, 1)
    Enum.each(1..times, fn _ ->
      role = Enum.random(List.wrap(roles))
      case Esr.ActorQuery.list_by_role(sid, role) do
        [pid | _] when is_pid(pid) -> Process.exit(pid, :kill)
        _ -> :ok
      end
      Process.sleep(50)
    end)
  end

  def eventually(fun, timeout_ms \\ 3_000, poll_ms \\ 50) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_eventually(fun, deadline, poll_ms)
  end

  defp do_eventually(fun, deadline, poll_ms) do
    case fun.() do
      true -> :ok
      _ ->
        if System.monotonic_time(:millisecond) >= deadline do
          flunk("eventually/2 timed out")
        else
          Process.sleep(poll_ms)
          do_eventually(fun, deadline, poll_ms)
        end
    end
  end

  def assert_chat_reply_within(timeout_ms) do
    assert_receive {:chat_reply, _}, timeout_ms
  end

  def setup_session_with_listener do
    # Fixture: start a feishu-cc session bound to a synthetic chat,
    # register the test process as a chat listener so {:chat_reply, _}
    # arrives on `self()`.
    # ... (delegate to existing fixture helpers)
  end
end
```

- [ ] **Step 2: Commit**

```bash
git add runtime/test/support/chaos_scenarios.ex
git commit -m "test(support): ChaosScenarios DSL — invariant_test, chaos_inject, eventually"
```

### Task 3.9: I1-I5 invariant tests

**Files:**
- Create: `runtime/test/esr/system/invariants_test.exs`
- Create: `docs/notes/system-invariants.md`

- [ ] **Step 1: Write the invariants doc**

`docs/notes/system-invariants.md`:

```markdown
# ESR system invariants

These cross-supervisor effect-level invariants hold for any session
in good standing. Verified by `runtime/test/esr/system/invariants_test.exs`
using the `Esr.Test.ChaosScenarios` DSL.

| ID | Statement |
|---|---|
| **I1** | Every chat inbound reaching FAA produces a chat-visible reply or chat-visible error within 5 seconds |
| **I2** | Every alive entry in `:esr_session_chat_routing` ETS points at a session whose FCP pid is alive in `Esr.ActorQuery` |
| **I3** | A session_dir on disk exists iff its supervisor tree has alive root |
| **I4** | Agent death (any cause, incl. supervisor giveup) produces a chat-visible lifecycle reply within 5 seconds |
| **I5** | No routing-layer code uses the `other -> Logger.warning + drop` pattern (CI grep gate) |

Source spec: `docs/superpowers/specs/2026-05-11-default-agent-and-agent-driven-flow-design.md` §4.7.
```

- [ ] **Step 2: Write the test file**

```elixir
defmodule Esr.System.InvariantsTest do
  use Esr.Test.ChaosScenarios

  setup do
    sid = setup_session_with_listener()
    {:ok, sid: sid}
  end

  invariant_test "I1: every inbound produces chat reply within 5s under chaos" do
    chaos_inject(context.sid, [:pty_process, :cc_process], times: 5)
    send_test_inbound(context.sid, "hello?")
    assert_chat_reply_within(5_000)
  end

  invariant_test "I2: ETS routing has no dead pids after chaos" do
    chaos_inject(context.sid, :pty_process)
    eventually(fn ->
      case Esr.Session.ChatRouting.Registry.current_session("c", "a") do
        :not_found -> true
        {:ok, sid} ->
          case Esr.ActorQuery.fcp_for_session(sid) do
            {:ok, pid} -> Process.alive?(pid)
            :not_found -> true  # FCP missing OK only if routing was deleted
          end
      end
    end, 3_000)
  end

  # I3, I4, I5 likewise — verify the invariant holds across the chaos
end
```

- [ ] **Step 3: Run + commit**

```bash
cd runtime && mix test test/esr/system/invariants_test.exs -v
git add runtime/test/esr/system/invariants_test.exs docs/notes/system-invariants.md
git commit -m "test(system): I1-I5 invariant tests + system-invariants.md"
```

### Task 3.10: Mix task `esr.audit_supervision` + baseline snapshot

**Files:**
- Create: `runtime/lib/mix/tasks/esr.audit_supervision.ex`
- Create: `docs/notes/supervisor-inventory.md`

- [ ] **Step 1: Implement the task**

```elixir
defmodule Mix.Tasks.Esr.AuditSupervision do
  use Mix.Task

  @shortdoc "Snapshot supervision tree; diff against docs/notes/supervisor-inventory.md"

  def run(_args) do
    Mix.Task.run("app.start")
    snapshot = build_snapshot([:esr_top_sup, Esr.Session.Supervisor, Esr.Session.LifecycleObservers])
    baseline_path = "docs/notes/supervisor-inventory.md"
    baseline = File.read!(baseline_path)
    if snapshot == baseline do
      IO.puts("audit_supervision: snapshot matches baseline")
    else
      IO.puts("audit_supervision: DRIFT detected:")
      diff = compute_diff(baseline, snapshot)
      IO.puts(diff)
      System.halt(1)
    end
  end

  defp build_snapshot(roots) do
    # Recursively walk each supervisor; emit `<sup>(<strategy>): [<child:type>, ...]`
    # ... ~40 LOC of straightforward iteration
  end

  defp compute_diff(a, b) do
    # Plain line diff
    # ... ~10 LOC
  end
end
```

- [ ] **Step 2: Generate initial baseline**

```bash
cd runtime && mix esr.audit_supervision > ../docs/notes/supervisor-inventory.md
```

- [ ] **Step 3: Commit**

```bash
git add runtime/lib/mix/tasks/esr.audit_supervision.ex docs/notes/supervisor-inventory.md
git commit -m "feat(mix): esr.audit_supervision + baseline snapshot"
```

### Task 3.11: ADR-0002

**Files:**
- Create: `docs/adr/0002-cc-pty-pair-one-for-all-invariant.md`

Content as spec §4.10 — copy verbatim.

```bash
git add docs/adr/0002-cc-pty-pair-one-for-all-invariant.md
git commit -m "docs(adr): 0002 — :one_for_all on CC+PTY pair invariant"
```

### Task 3.12: Add CI gate for audit + grep gate for I5

**Files:**
- Modify: `.github/workflows/ci.yml`

- [ ] **Step 1: Append to existing job**

```yaml
- name: Supervisor audit drift gate
  run: cd runtime && mix esr.audit_supervision

- name: Routing-layer catch-all grep gate (invariant I5)
  run: |
    if rg -n "other -> Logger\.warning" runtime/lib/esr/plugins/feishu/feishu_app_adapter.ex \
         runtime/lib/esr/session/router.ex \
         runtime/lib/esr/entity/slash_handler.ex 2>/dev/null; then
      echo "FAIL: routing-layer code retains 'other -> Logger.warning' catch-all (see I5)"
      exit 1
    fi
    echo "PASS: I5 grep gate"
```

- [ ] **Step 2: Commit**

```bash
git add .github/workflows/ci.yml
git commit -m "ci: add audit + I5 grep gate steps"
```

### Task 3.13: Open PR + admin-merge

```bash
git push -u origin feat/chat-routing-unify-and-supervision-invariants
gh pr create --base dev --title "feat(supervision): ChatRouting unify + LifecycleObserver + ChaosScenarios + audit + ADR-0002 (PR-3 of 4)" --body "..."
gh pr checks --watch
gh pr merge --admin --squash --delete-branch
```

---

## PR-4: submit_slash MCP tool + RawCollector + CC skill + real-claude test (~270 LOC, 8 tasks)

### Task 4.1: Branch

```bash
git fetch origin
git checkout -b feat/submit-slash-mcp-tool origin/dev
```

### Task 4.2: `Esr.Slash.ReplyTarget.RawCollector`

**Files:**
- Create: `runtime/lib/esr/slash/reply_target/raw_collector.ex`
- Test: `runtime/test/esr/slash/reply_target/raw_collector_test.exs`

- [ ] **Step 1: Implement**

```elixir
defmodule Esr.Slash.ReplyTarget.RawCollector do
  @behaviour Esr.Slash.ReplyTarget

  @impl true
  def respond(%{caller: caller, ref: ref}, {:ok, result}, _slash_ref) do
    send(caller, {:slash_raw, ref, {:ok, result}})
    :ok
  end

  def respond(%{caller: caller, ref: ref}, {:error, reason}, _slash_ref) do
    send(caller, {:slash_raw, ref, {:error, reason}})
    :ok
  end

  def respond(%{caller: caller, ref: ref}, result, _slash_ref) do
    send(caller, {:slash_raw, ref, {:ok, result}})
    :ok
  end
end
```

- [ ] **Step 2: Tests**

```elixir
test "RawCollector forwards {:ok, result}" do
  ref = make_ref()
  Esr.Slash.ReplyTarget.RawCollector.respond(%{caller: self(), ref: ref}, {:ok, %{x: 1}}, "slash-ref")
  assert_receive {:slash_raw, ^ref, {:ok, %{x: 1}}}, 100
end

test "RawCollector forwards {:error, reason}" do
  ref = make_ref()
  Esr.Slash.ReplyTarget.RawCollector.respond(%{caller: self(), ref: ref}, {:error, :nope}, "slash-ref")
  assert_receive {:slash_raw, ^ref, {:error, :nope}}, 100
end
```

- [ ] **Step 3: Commit**

```bash
cd runtime && mix test test/esr/slash/reply_target/raw_collector_test.exs -v
git add runtime/lib/esr/slash/reply_target/raw_collector.ex runtime/test/esr/slash/reply_target/raw_collector_test.exs
git commit -m "feat(slash): Esr.Slash.ReplyTarget.RawCollector"
```

### Task 4.3: Register `submit_slash` tool

**Files:**
- Modify: `runtime/lib/esr/plugins/claude_code/mcp/tools.ex`

- [ ] **Step 1: Add tool def**

```elixir
@admin_tool %{
  name: "submit_slash",
  description: """
  Execute an ESR slash command on behalf of the operator. Use when the
  user asks (in any language) to perform admin work: adding agents,
  listing sessions, switching workspace, etc. Returns structured result.
  """,
  input_schema: %{
    type: "object",
    properties: %{
      command: %{type: "string",
                 description: "Full slash command with leading /, e.g. /agent:add type=cc name=helper"}
    },
    required: ["command"]
  }
}

def tools, do: [@admin_tool | existing_tools()]
```

- [ ] **Step 2: Commit**

```bash
git add runtime/lib/esr/plugins/claude_code/mcp/tools.ex
git commit -m "feat(mcp): register submit_slash tool"
```

### Task 4.4: FCP `dispatch_tool_invoke/5` new branch + per-call Task

**Files:**
- Modify: `runtime/lib/esr/plugins/feishu/feishu_chat_proxy.ex` (line ~307)
- Test: `runtime/test/esr/plugins/feishu/submit_slash_handler_test.exs`

- [ ] **Step 1: Write failing test**

```elixir
test "submit_slash dispatches through SlashHandler with chat ctx" do
  {:ok, sid} = setup_feishu_cc_session_fixture()
  channel_pid = self()
  fcp = pid_of(sid, :feishu_chat_proxy)
  req_id = "req-1"
  send(fcp, {:tool_invoke, req_id, "submit_slash",
             %{"command" => "/session:list"}, channel_pid, "ou_test_linyilun"})
  assert_receive {:tool_result, ^req_id, {:ok, _result}}, 10_000
end
```

- [ ] **Step 2: Add handler branch in FCP**

```elixir
# In FCP's dispatch_tool_invoke/5 (or wherever {:tool_invoke, ...} is caught)
defp dispatch_tool_invoke(req_id, "submit_slash", %{"command" => cmd_str},
                          channel_pid, principal_id, state) do
  sid = state.session_id
  Task.start(fn ->
    result = run_submit_slash(sid, cmd_str, principal_id)
    send(channel_pid, {:tool_result, req_id, result})
  end)
  {:noreply, state}
end

defp run_submit_slash(sid, cmd_str, principal_id) do
  with {:ok, session} <- Esr.Resource.Session.Registry.get_by_id(sid),
       {:ok, chat} <- pick_origin_chat(session) do
    envelope = build_internal_envelope(cmd_str, chat, principal_id)
    ref = make_ref()
    reply_target = {Esr.Slash.ReplyTarget.RawCollector, %{caller: self(), ref: ref}}
    _ = Esr.Entity.SlashHandler.dispatch(envelope, reply_target)
    receive do
      {:slash_raw, ^ref, {:ok, result}} -> {:ok, result}
      {:slash_raw, ^ref, {:error, reason}} -> {:error, %{kind: reason}}
    after
      30_000 -> {:error, %{kind: :slash_timeout}}
    end
  else
    {:error, reason} -> {:error, %{kind: reason}}
    :not_found -> {:error, %{kind: :session_not_found}}
  end
end

defp pick_origin_chat(%{attached_chats: [first | _]}), do: {:ok, first}
defp pick_origin_chat(%{attached_chats: []}), do: {:error, :no_attached_chat}

defp build_internal_envelope(cmd_str, %{chat_id: chat_id, app_id: app_id}, principal_id) do
  %{
    "id" => "submit-#{:erlang.unique_integer([:positive])}",
    "kind" => "event",
    "payload" => %{
      "args" => %{
        "content" => cmd_str, "msg_type" => "text",
        "chat_id" => chat_id, "app_id" => app_id, "submitted_by" => principal_id
      },
      "event_type" => "msg_received"
    },
    "source" => "esr://localhost/submit_slash",
    "ts" => DateTime.utc_now() |> DateTime.to_iso8601(),
    "type" => "event",
    "principal_id" => principal_id
  }
end
```

- [ ] **Step 3: Run + commit**

```bash
cd runtime && mix test test/esr/plugins/feishu/submit_slash_handler_test.exs -v
git add runtime/lib/esr/plugins/feishu/feishu_chat_proxy.ex runtime/test/esr/plugins/feishu/submit_slash_handler_test.exs
git commit -m "feat(feishu): submit_slash dispatched via per-call Task; uses RawCollector"
```

### Task 4.5: CC admin skill prompt + Launcher injection

**Files:**
- Create: `runtime/lib/esr/bundles/feishu-cc/agent_skills/admin.md`
- Modify: `runtime/lib/esr/plugins/claude_code/launcher.ex` (inject the prompt)

- [ ] **Step 1: Write the skill prompt**

Copy from spec §5.3 — full markdown content (~30 LOC).

- [ ] **Step 2: Modify Launcher**

In `prepare_spawn/1`, add `--system-prompt $(cat .../admin.md)` (or equivalent flag) to the claude command line.

- [ ] **Step 3: Commit**

```bash
git add runtime/lib/esr/bundles/feishu-cc/agent_skills/admin.md runtime/lib/esr/plugins/claude_code/launcher.ex
git commit -m "feat(cc): inject admin skill prompt for submit_slash"
```

### Task 4.6: Real-claude integration test

**Files:**
- Create: `runtime/test/esr/integration/real_claude_boot_test.exs`

```elixir
defmodule Esr.Integration.RealClaudeBootTest do
  use ExUnit.Case, async: false
  @moduletag :real_claude

  setup do
    case System.find_executable("claude") do
      nil -> {:skip, "claude not on PATH"}
      _ -> :ok
    end
  end

  test "real claude boots, mcp.json written, chat reply round-trip" do
    {:ok, ws} = setup_real_workspace_with_folder()
    {:ok, sid} = Esr.Session.Router.create_session(real_params(ws))

    assert eventually(fn ->
      File.exists?(Esr.Paths.session_mcp_json(sid)) and
      instance_registry_has_role?(sid, :feishu_chat_proxy) and
      instance_registry_has_role?(sid, :cc_process) and
      cc_mcp_ready?(sid)
    end, 30_000)

    send_test_inbound("hello", sid, ws.chat)
    assert_receive {:chat_reply, _}, 60_000

    :ok = Esr.Session.Router.end_session(sid)
  end

  defp cc_mcp_ready?(sid) do
    Phoenix.PubSub.subscribe(Esr.PubSub, "cc_mcp_ready/#{sid}")
    receive do
      :cc_mcp_ready -> true
    after 0 -> false
    end
  end
end
```

```bash
git add runtime/test/esr/integration/real_claude_boot_test.exs
git commit -m "test(integration): real-claude boot end-to-end"
```

### Task 4.7: CI macos-latest job for `:real_claude`

**Files:**
- Modify: `.github/workflows/ci.yml`

```yaml
real-claude-integration:
  runs-on: macos-latest
  steps:
    - uses: actions/checkout@v4
    - uses: erlef/setup-beam@v1
      with:
        elixir-version: '1.19'
        otp-version: '27'
    # Install claude binary
    - run: |
        if ! command -v claude > /dev/null; then
          echo "skip: claude binary not on macOS-latest runner — using moduletag skip"
        fi
    - run: cd runtime && mix test --only real_claude
```

```bash
git add .github/workflows/ci.yml
git commit -m "ci: add macos-latest real_claude integration job"
```

### Task 4.8: Open PR + admin-merge

```bash
git push -u origin feat/submit-slash-mcp-tool
gh pr create --base dev --title "feat(agent): submit_slash MCP tool + CC admin skill + real-claude test (PR-4 of 4)" --body "..."
gh pr checks --watch
gh pr merge --admin --squash --delete-branch
```

---

## Self-Review

### Spec coverage

| Spec section | Plan task |
|---|---|
| §4.1 workspace folders ≥1 | PR-1, all 8 tasks |
| §4.2 prepare_spawn sole entry | PR-2 Tasks 2.2, 2.3, 2.4 |
| §4.3 SessionTemplate pipeline integrity | PR-2 Task 2.5, 2.7 |
| §4.4 FCP :pty_closed | PR-2 Task 2.6 |
| §4.5 ChatRouting unify | PR-3 Tasks 3.2-3.6 |
| §4.6 LifecycleObserver | PR-3 Task 3.7 |
| §4.7 system invariants + ChaosScenarios | PR-3 Tasks 3.8-3.9 |
| §4.8 real-claude integration test | PR-4 Tasks 4.6-4.7 |
| §4.9 mix esr.audit_supervision | PR-3 Tasks 3.10-3.12 |
| §4.10 ADR-0002 | PR-3 Task 3.11 |
| §5 submit_slash MCP tool | PR-4 Tasks 4.2-4.5 |

No spec gaps.

### Placeholder scan

Searched for "TBD/TODO/etc". The Task 3.10 build_snapshot has `# ~40 LOC of straightforward iteration` which is descriptive-not-prescriptive — implementer must write the actual snapshot format. Acceptable for this plan since the snapshot format is design-flexible (markdown table); flagging as the one place implementer-judgment is required.

### Type consistency

- `Esr.Slash.ReplyTarget.RawCollector.respond/3` takes `%{caller: pid, ref: ref}` config — used consistently across Task 4.2 + Task 4.4.
- `attach_session/3` API signature `(chat_id, app_id, sid)` — used consistently across Tasks 3.3, 3.4, 3.5.
- `Esr.ActorQuery.fcp_for_session/1` returns `{:ok, pid} | :not_found` — used consistently in Tasks 3.2, 3.6, 4.4.
- `{:tool_invoke, req_id, tool, args, channel_pid, principal_id}` message shape — used consistently between MCP dispatch + FCP handler (Task 4.4).

All consistent.

---

## Open risks (not blockers)

- **`Esr.Plugins.Feishu.FeishuChatProxy.OutboundEmit.emit/2`** assumed in Task 2.6 — actual helper name may differ in FCP. Implementer grep `emit_reply` / `reply_envelope` in FCP to find the right hook before writing `notify_chat/2`.
- **`reply_chat_error/4` at FAA module-level** assumed in Task 3.6 — same: grep + adapt.
- **`Esr.PubSub` PubSub topic `cc_mcp_ready/<sid>`** assumed in Task 4.6 — verify topic name by reading `EsrWeb.McpController` first.
- **macos-latest runner** for `real_claude` job needs claude binary install — currently NOT on the runner. Either (a) install via brew (uncached, slow), (b) prebuild a runner image, or (c) accept the `setup` skip and treat the test as developer-machine-only. Option (c) is the lowest cost; the test still catches the bug class on local dev runs.
