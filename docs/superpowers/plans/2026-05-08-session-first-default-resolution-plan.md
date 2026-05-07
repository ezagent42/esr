# Session-first default resolution — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the system "default" workspace fallback with a per-user default; auto-create `<username>-default` on `/user:add`; introduce `/user:use` slash; relax `/workspace:add-folder name=` to fall back through the same chain. Net result: an operator on a fresh install can run `/user:add alice` → `/session:new` → `/session:add-agent` without ever typing a workspace name.

**Architecture:** Three small primitives, two new slashes, one rewritten resolver. (1) `Esr.Entity.User.Registry` gains `:default_workspace_id` field + ETS-backed `set/get_default_workspace`. (2) `/user:use workspace=<n>` mirrors `/workspace:use` at user scope. (3) `Esr.Commands.Workspace.Resolve` becomes the single chain (explicit → chat-default → user-default → error) used by both `Scope.New` and `Workspace.AddFolder`. (4) `Esr.Resource.Workspace.Bootstrap` no longer writes the literal name `default`; it computes `<bootstrap_user>-default`. (5) `Esr.Commands.User.Add` auto-creates `<username>-default` and links it via `set_default_workspace`.

**Tech Stack:** Elixir 1.19 + OTP 27, Phoenix 1.8, ExUnit, ETS, YamlElixir, Jason. E2E shell scripts under `tests/e2e/scenarios/`.

**Spec:** [`docs/superpowers/specs/2026-05-08-session-first-default-resolution.md`](../specs/2026-05-08-session-first-default-resolution.md) rev-1, user-approved 2026-05-07. zh_cn mirror at `.zh_cn.md`.

**User-stated invariant:** *e2e scenario 19 must be part of the same PR (not deferred)*. Phase 8 enforces this — the PR-open task in Phase 10 explicitly checks scenario 19 ran green.

---

## File structure

| File | Purpose | Action |
|---|---|---|
| `runtime/lib/esr/entity/user/registry.ex` | User struct + ETS API | Modify — add `:default_workspace_id` field, `set/get_default_workspace/2` |
| `runtime/lib/esr/entity/user/file_loader.ex` | yaml + user.json → snapshot | Modify — read `default_workspace_id` from `user.json` |
| `runtime/lib/esr/commands/user/use.ex` | `/user:use` command | **Create** |
| `runtime/lib/esr/commands/user/add.ex` | `/user:add` command | Modify — auto-create user-default workspace |
| `runtime/lib/esr/commands/workspace/resolve.ex` | Shared resolution chain | **Create** |
| `runtime/lib/esr/commands/scope/new.ex` | `/session:new` command | Modify — swap fallback to user-default |
| `runtime/lib/esr/commands/workspace/add_folder.ex` | `/workspace:add-folder` | Modify — `name` optional, use Resolve chain |
| `runtime/lib/esr/resource/workspace/bootstrap.ex` | First-boot ws seed | Rewrite — `<bootstrap_user>-default`, not literal `"default"` |
| `runtime/priv/slash-routes.default.yaml` | Slash registry | Modify — add `/user:use`; relax `/workspace:add-folder` |
| `runtime/priv/schemas/user.v1.json` | user.json schema | Modify — add `default_workspace_id` |
| `runtime/test/esr/entity/user/registry_test.exs` | Registry tests | Modify — add set/get default_workspace tests |
| `runtime/test/esr/commands/user/add_test.exs` | User.Add tests | Modify — assert auto-created workspace + link |
| `runtime/test/esr/commands/user/use_test.exs` | `/user:use` tests | **Create** |
| `runtime/test/esr/commands/workspace/resolve_test.exs` | Chain tests | **Create** |
| `runtime/test/esr/commands/scope/new_resolve_workspace_test.exs` | New chain tests | Modify — replace system-default branch with user-default |
| `runtime/test/esr/commands/workspace/add_folder_test.exs` | AddFolder tests | Modify — chain fallback when `name` omitted |
| `runtime/test/esr/resource/workspace/bootstrap_test.exs` | Bootstrap tests | **Create** (or replace if exists) |
| `runtime/test/esr/application_first_boot_test.exs` | First-boot integration | Modify — drop assertions on literal `"default"` |
| `runtime/test/support/workspace_fixture.ex` | Test fixture | Modify — accept `default_for_user:` kwarg |
| `tests/e2e/scenarios/19_session_first_default.sh` | Scenario 19 | **Create** |
| `Makefile` | e2e targets | Modify — add `e2e-19` target |
| `docs/manual-checks/2026-05-08-post-multi-instance-audit.md` + `.zh_cn.md` | Audit doc | Modify — close gap §3 + step 9 |
| `docs/futures/todo.md` | Durable TODO | Modify — mark "Migrate to session-first model" closed (Phase 1 portion) |
| `runtime/lib/esr/paths.ex` | Path helpers | No change — `users_dir/0`, `user_dir/1`, `user_json/1` already exist |
| `runtime/lib/esr/resource/chat_scope/registry.ex` | ChatScope | No change — `set/get_default_workspace/3` reused as-is |

---

## Branch + PR strategy

- Single branch off `dev`: `feat/session-first-default-resolution`
- Target `dev` for the PR (the multi-instance work is already in dev; no integration branch needed)
- One squash-merge to dev when scenario 19 is green

---

## Phase 0 — Setup

### Task 0.1: Create branch + verify clean baseline

**Files:** none (env work).

- [ ] **Step 1: Pull latest dev and branch**

```bash
cd /Users/h2oslabs/Workspace/esr/.worktrees/dev
git fetch origin dev
git checkout -b feat/session-first-default-resolution origin/dev
git log -1 --oneline
```

Expected output: `d421212 docs(manual-checks): post multi-instance routing audit (2026-05-08) (#262)` (or newer).

- [ ] **Step 2: Run the existing test suite to establish baseline**

```bash
cd runtime && mix test 2>&1 | tail -3
```

Expected: ~10 pre-existing flaky failures (PubSubAudit / NotifyTest / etc., unrelated to this work). Record the exact count for comparison after each phase.

- [ ] **Step 3: Confirm wipe was effective**

```bash
ls ~/.esrd ~/.esrd-dev
```

Expected: both directories empty (per spec D6 / 2026-05-07 wipe).

- [ ] **Step 4: No commit; environment-only**

---

## Phase 1 — User.Registry default_workspace_id

### Task 1.1: Add `:default_workspace_id` field to the User struct

**Files:**
- Modify: `runtime/lib/esr/entity/user/registry.ex:35-42`
- Test: `runtime/test/esr/entity/user/registry_test.exs`

- [ ] **Step 1: Write the failing test**

Append to `runtime/test/esr/entity/user/registry_test.exs`:

```elixir
describe "User struct (M-5/D2)" do
  test "defaults default_workspace_id to nil" do
    user = %Esr.Entity.User.Registry.User{username: "alice"}
    assert user.default_workspace_id == nil
  end

  test "carries default_workspace_id when constructed" do
    uuid = "01ARZSTAB12345678901234567"
    user = %Esr.Entity.User.Registry.User{username: "alice", default_workspace_id: uuid}
    assert user.default_workspace_id == uuid
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd runtime && mix test test/esr/entity/user/registry_test.exs --only describe:"User struct (M-5/D2)"
```

Expected: FAIL with `KeyError: key :default_workspace_id not found in: %Esr.Entity.User.Registry.User{...}`.

- [ ] **Step 3: Add the field**

In `runtime/lib/esr/entity/user/registry.ex` line 41, replace:

```elixir
defstruct [:username, feishu_ids: []]
```

with:

```elixir
defstruct [:username, feishu_ids: [], default_workspace_id: nil]
```

- [ ] **Step 4: Run test to verify it passes**

```bash
cd runtime && mix test test/esr/entity/user/registry_test.exs --only describe:"User struct (M-5/D2)"
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add runtime/lib/esr/entity/user/registry.ex runtime/test/esr/entity/user/registry_test.exs
git commit -m "feat(user): add :default_workspace_id field to %User{} struct"
```

### Task 1.2: Add `set/get_default_workspace/2` API + ETS

**Files:**
- Modify: `runtime/lib/esr/entity/user/registry.ex` (public API + GenServer handlers)
- Test: `runtime/test/esr/entity/user/registry_test.exs`

- [ ] **Step 1: Write the failing test**

Append to `runtime/test/esr/entity/user/registry_test.exs`:

```elixir
describe "set_default_workspace/2 + get_default_workspace/1" do
  setup do
    # Reset Registry between tests
    Esr.Entity.User.Registry.load_snapshot_with_uuids(
      %{
        "alice" => %Esr.Entity.User.Registry.User{username: "alice", feishu_ids: ["ou_a"]}
      },
      %{"alice" => "alice-uuid-1"}
    )

    :ok
  end

  test "set then get returns the bound workspace_id" do
    assert :ok = Esr.Entity.User.Registry.set_default_workspace("alice", "ws-uuid-1")
    assert {:ok, "ws-uuid-1"} = Esr.Entity.User.Registry.get_default_workspace("alice")
  end

  test "get returns :not_found when nothing set" do
    assert :not_found = Esr.Entity.User.Registry.get_default_workspace("alice")
  end

  test "set on unknown user returns {:error, :not_found}" do
    assert {:error, :not_found} =
             Esr.Entity.User.Registry.set_default_workspace("ghost", "ws-uuid-1")
  end

  test "overwrite replaces the previous binding" do
    :ok = Esr.Entity.User.Registry.set_default_workspace("alice", "ws-uuid-1")
    :ok = Esr.Entity.User.Registry.set_default_workspace("alice", "ws-uuid-2")
    assert {:ok, "ws-uuid-2"} = Esr.Entity.User.Registry.get_default_workspace("alice")
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd runtime && mix test test/esr/entity/user/registry_test.exs --only describe:"set_default_workspace/2 + get_default_workspace/1"
```

Expected: FAIL — `set_default_workspace/2` and `get_default_workspace/1` undefined.

- [ ] **Step 3: Add public API + handle_call clauses**

In `runtime/lib/esr/entity/user/registry.ex` after the existing `list/0` (line ~119), add:

```elixir
  @doc """
  Bind `username` to a default workspace UUID. The workspace itself is
  not validated here — caller must ensure ws_id exists in
  `Esr.Resource.Workspace.Registry`.

  Returns `{:error, :not_found}` if username has no row in `@by_name`.
  """
  @spec set_default_workspace(String.t(), String.t()) ::
          :ok | {:error, :not_found}
  def set_default_workspace(username, ws_id)
      when is_binary(username) and is_binary(ws_id) do
    GenServer.call(__MODULE__, {:set_default_workspace, username, ws_id})
  end

  @doc """
  Look up the default workspace UUID for `username`.
  Returns `:not_found` when no binding exists.
  """
  @spec get_default_workspace(String.t()) :: {:ok, String.t()} | :not_found
  def get_default_workspace(username) when is_binary(username) do
    case :ets.lookup(@by_name, username) do
      [{^username, %User{default_workspace_id: id}}] when is_binary(id) -> {:ok, id}
      _ -> :not_found
    end
  rescue
    ArgumentError -> :not_found
  end
```

In the same file, after the existing `handle_call({:load_with_uuids, ...}, ...)` (line ~169), add:

```elixir
  @impl true
  def handle_call({:set_default_workspace, username, ws_id}, _from, state) do
    case :ets.lookup(@by_name, username) do
      [{^username, %User{} = user}] ->
        updated = %User{user | default_workspace_id: ws_id}
        :ets.insert(@by_name, {username, updated})

        # Mirror to UUID table if a row is present (load_snapshot_with_uuids).
        case :ets.match_object(@by_uuid, {:_, %User{username: ^username}}) do
          [{uuid, _}] -> :ets.insert(@by_uuid, {uuid, updated})
          _ -> :ok
        end

        {:reply, :ok, state}

      _ ->
        {:reply, {:error, :not_found}, state}
    end
  end
```

- [ ] **Step 4: Run test to verify it passes**

```bash
cd runtime && mix test test/esr/entity/user/registry_test.exs --only describe:"set_default_workspace/2 + get_default_workspace/1"
```

Expected: PASS — 4 tests, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add runtime/lib/esr/entity/user/registry.ex runtime/test/esr/entity/user/registry_test.exs
git commit -m "feat(user): set/get_default_workspace public API + ETS handlers"
```

---

## Phase 2 — user.json schema bump + FileLoader read

### Task 2.1: Bump `user.v1.json` schema (additive — `default_workspace_id` optional)

**Files:**
- Modify: `runtime/priv/schemas/user.v1.json`
- Test: none (schema is read by JsonWriter / Jason; no separate test)

- [ ] **Step 1: Read current schema**

```bash
cat runtime/priv/schemas/user.v1.json
```

- [ ] **Step 2: Add the optional field to the schema**

Edit `runtime/priv/schemas/user.v1.json` — inside `properties:`, add after `feishu_ids`:

```json
    "default_workspace_id": {
      "type": ["string", "null"],
      "description": "Workspace UUID this user falls back to when no chat-default is set. Optional; absent ≡ null."
    }
```

Do NOT add to the `required` array — this is additive backward-compat.

- [ ] **Step 3: Verify schema parses**

```bash
cd runtime && mix run -e 'Jason.decode!(File.read!("priv/schemas/user.v1.json")) |> IO.inspect()' | head -20
```

Expected: structured map output, no exception.

- [ ] **Step 4: Commit**

```bash
git add runtime/priv/schemas/user.v1.json
git commit -m "feat(user): add default_workspace_id (optional) to user.v1.json schema"
```

### Task 2.2: FileLoader reads `default_workspace_id` from user.json

**Files:**
- Modify: `runtime/lib/esr/entity/user/file_loader.ex` — `load_from_users_dir/1` builds `%User{default_workspace_id: ...}`
- Test: `runtime/test/esr/entity/user/file_loader_test.exs`

- [ ] **Step 1: Write the failing test**

Append to `runtime/test/esr/entity/user/file_loader_test.exs`:

```elixir
describe "default_workspace_id round-trip via user.json (M-5/D2)" do
  setup do
    tmp = Path.join(System.tmp_dir!(), "esr-userloader-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(tmp, "users/uuid-alice"))

    File.write!(
      Path.join([tmp, "users/uuid-alice/user.json"]),
      Jason.encode!(%{
        "schema_version" => 1,
        "id" => "uuid-alice",
        "username" => "alice",
        "feishu_ids" => ["ou_a"],
        "default_workspace_id" => "ws-uuid-7"
      })
    )

    on_exit(fn -> File.rm_rf!(tmp) end)
    %{tmp: tmp}
  end

  test "FileLoader populates User.default_workspace_id when set in user.json", %{tmp: tmp} do
    yaml_path = Path.join(tmp, "users.yaml")
    # No yaml file — loader falls through to load_from_users_dir
    assert :ok = Esr.Entity.User.FileLoader.load(yaml_path)

    assert {:ok, %{default_workspace_id: "ws-uuid-7"}} =
             Esr.Entity.User.Registry.get("alice")
  end

  test "default_workspace_id stays nil when absent from user.json", %{tmp: tmp} do
    File.write!(
      Path.join([tmp, "users/uuid-alice/user.json"]),
      Jason.encode!(%{
        "schema_version" => 1,
        "id" => "uuid-alice",
        "username" => "alice",
        "feishu_ids" => ["ou_a"]
        # default_workspace_id intentionally absent
      })
    )

    yaml_path = Path.join(tmp, "users.yaml")
    assert :ok = Esr.Entity.User.FileLoader.load(yaml_path)

    assert {:ok, %{default_workspace_id: nil}} =
             Esr.Entity.User.Registry.get("alice")
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd runtime && mix test test/esr/entity/user/file_loader_test.exs --only describe:"default_workspace_id round-trip via user.json"
```

Expected: FAIL — first test fails because loader currently builds `%User{username: ..., feishu_ids: ...}` and does not set `default_workspace_id`.

- [ ] **Step 3: Update `load_from_users_dir/1`**

In `runtime/lib/esr/entity/user/file_loader.ex` line ~150, replace the body of the matching clause:

```elixir
        case read_user_json(json_path) do
          {:ok, %{"username" => username, "id" => uuid} = doc}
          when is_binary(username) and is_binary(uuid) ->
            feishu_ids = Map.get(doc, "feishu_ids", [])
            default_ws = Map.get(doc, "default_workspace_id")

            user = %User{
              username: username,
              feishu_ids: feishu_ids,
              default_workspace_id: default_ws
            }

            {Map.put(snap, username, user), Map.put(uuids, username, uuid)}
```

Also update `build_snapshot/1` for the yaml-present path (line ~101). Locate:

```elixir
            Map.put(acc, username, %User{username: username, feishu_ids: ids})
```

Replace with:

```elixir
            # default_workspace_id is sourced exclusively from user.json
            # (yaml is the legacy dual-format pair; field stays nil here).
            # Loader merges back from user.json via the @users_dir scan.
            Map.put(acc, username, %User{username: username, feishu_ids: ids})
```

(no functional change — leaves `default_workspace_id: nil` in the yaml path; the user.json scan in `read_uuids_from_dir/1` is augmented next.)

Augment `read_uuids_from_dir/1` to also collect `default_workspace_id` per username. Replace the function (lines ~115-139):

```elixir
  @spec read_uuids_from_dir(Path.t()) :: %{String.t() => String.t()}
  def read_uuids_from_dir(users_dir) do
    if File.dir?(users_dir) do
      users_dir
      |> File.ls!()
      |> Enum.reduce(%{}, fn entry, acc ->
        json_path = Path.join([users_dir, entry, "user.json"])

        case read_user_json(json_path) do
          {:ok, %{"username" => username, "id" => uuid}}
          when is_binary(username) and is_binary(uuid) ->
            Map.put(acc, username, uuid)

          _ ->
            acc
        end
      end)
    else
      %{}
    end
  rescue
    e ->
      Logger.warning("users: failed to scan users dir #{users_dir}: #{inspect(e)}")
      %{}
  end

  # Companion to read_uuids_from_dir/1: scan the same files for
  # default_workspace_id. Returns %{username => ws_uuid}.
  @spec read_default_workspaces_from_dir(Path.t()) :: %{String.t() => String.t()}
  def read_default_workspaces_from_dir(users_dir) do
    if File.dir?(users_dir) do
      users_dir
      |> File.ls!()
      |> Enum.reduce(%{}, fn entry, acc ->
        json_path = Path.join([users_dir, entry, "user.json"])

        case read_user_json(json_path) do
          {:ok, %{"username" => username, "default_workspace_id" => ws_id}}
          when is_binary(username) and is_binary(ws_id) ->
            Map.put(acc, username, ws_id)

          _ ->
            acc
        end
      end)
    else
      %{}
    end
  rescue
    _ -> %{}
  end
```

Update the yaml-present branch in `load/1` (lines ~57-67) to call the new helper and forward defaults via the Registry's API after `load_snapshot_with_uuids`:

```elixir
      true ->
        with {:ok, yaml} <- parse(path),
             {:ok, snapshot} <- build_snapshot(yaml) do
          uuids = read_uuids_from_dir(users_dir)
          defaults = read_default_workspaces_from_dir(users_dir)
          Registry.load_snapshot_with_uuids(snapshot, uuids)
          apply_defaults(defaults)
          Logger.info("users: loaded #{map_size(snapshot)} users from #{path}")
          :ok
        else
          {:error, reason} = err ->
            Logger.error(
              "users: load failed (#{inspect(reason)}); keeping previous snapshot"
            )

            err
        end
```

And the no-yaml branch:

```elixir
      not File.exists?(path) ->
        {snapshot, uuids} = load_from_users_dir(users_dir)
        Registry.load_snapshot_with_uuids(snapshot, uuids)
        # default_workspace_id was already threaded into snapshot User structs
        # by load_from_users_dir/1, so no additional apply_defaults needed.
        :ok
```

Add the helper `apply_defaults/1` at the bottom of the module:

```elixir
  defp apply_defaults(defaults) when is_map(defaults) do
    Enum.each(defaults, fn {username, ws_id} ->
      _ = Registry.set_default_workspace(username, ws_id)
    end)
  end
```

- [ ] **Step 4: Run test to verify it passes**

```bash
cd runtime && mix test test/esr/entity/user/file_loader_test.exs --only describe:"default_workspace_id round-trip via user.json"
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add runtime/lib/esr/entity/user/file_loader.ex runtime/test/esr/entity/user/file_loader_test.exs
git commit -m "feat(user): FileLoader reads default_workspace_id from user.json"
```

### Task 2.3: User.Add writes `default_workspace_id` (placeholder — wired in Phase 4)

**Files:**
- Modify: `runtime/lib/esr/commands/user/add.ex` — `write_user_json/2` accepts an optional `default_workspace_id`
- Test: `runtime/test/esr/commands/user/add_test.exs`

- [ ] **Step 1: Write the failing test**

Append to `runtime/test/esr/commands/user/add_test.exs`:

```elixir
describe "user.json default_workspace_id (M-5/D2 placeholder)" do
  test "user.json contains default_workspace_id key (null if not yet set)" do
    name = "alice-#{System.unique_integer([:positive])}"

    cmd = %{"submitted_by" => "ou_admin", "args" => %{"name" => name}}
    assert {:ok, %{"id" => uuid}} = Esr.Commands.User.Add.execute(cmd)

    json_path = Path.join([Esr.Paths.users_dir(), uuid, "user.json"])
    {:ok, doc} = Jason.decode(File.read!(json_path))

    assert Map.has_key?(doc, "default_workspace_id")
    # Phase 2 placeholder: nil. Phase 4 will populate with real ws id.
    assert doc["default_workspace_id"] == nil
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd runtime && mix test test/esr/commands/user/add_test.exs --only describe:"user.json default_workspace_id"
```

Expected: FAIL — `default_workspace_id` key not present in the written JSON.

- [ ] **Step 3: Add the field (placeholder)**

In `runtime/lib/esr/commands/user/add.ex`, locate `write_user_json/2` (line ~85) and update the `doc` map:

```elixir
      doc = %{
        "schema_version" => 1,
        "id" => uuid,
        "username" => username,
        "display_name" => "",
        "feishu_ids" => [],
        "default_workspace_id" => nil,
        "created_at" => DateTime.utc_now() |> DateTime.to_iso8601()
      }
```

- [ ] **Step 4: Run test to verify it passes**

```bash
cd runtime && mix test test/esr/commands/user/add_test.exs --only describe:"user.json default_workspace_id"
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add runtime/lib/esr/commands/user/add.ex runtime/test/esr/commands/user/add_test.exs
git commit -m "feat(user): User.Add writes default_workspace_id key (Phase 2 placeholder=nil)"
```

---

## Phase 3 — `/user:use` slash command

### Task 3.1: Create `Esr.Commands.User.Use`

**Files:**
- Create: `runtime/lib/esr/commands/user/use.ex`
- Create: `runtime/test/esr/commands/user/use_test.exs`

- [ ] **Step 1: Write the failing test**

Create `runtime/test/esr/commands/user/use_test.exs`:

```elixir
defmodule Esr.Commands.User.UseTest do
  use ExUnit.Case, async: false

  alias Esr.Commands.User.Use, as: UserUse
  alias Esr.Entity.User.Registry, as: UserRegistry
  alias Esr.Resource.Workspace.Registry, as: WsRegistry
  alias Esr.Test.WorkspaceFixture

  setup do
    UserRegistry.load_snapshot_with_uuids(
      %{
        "alice" => %UserRegistry.User{username: "alice", feishu_ids: ["ou_a"]}
      },
      %{"alice" => "alice-uuid-1"}
    )

    on_exit(fn -> WorkspaceFixture.reset!() end)
    :ok
  end

  test "binds workspace by name to the submitting user's default" do
    ws = WorkspaceFixture.build(name: "alice-ws", owner: "alice")
    :ok = WsRegistry.put(ws)

    cmd = %{
      "submitted_by" => "ou_a",
      "args" => %{"workspace" => "alice-ws"},
      "submitter_username" => "alice"
    }

    assert {:ok, %{"action" => "user_default_set", "workspace" => "alice-ws"}} =
             UserUse.execute(cmd)

    assert {:ok, ^ws_id} = UserRegistry.get_default_workspace("alice")
    ws_id = ws.id
    _ = ws_id
  end

  test "unknown workspace → unknown_workspace error" do
    cmd = %{
      "submitted_by" => "ou_a",
      "args" => %{"workspace" => "ghost-ws"},
      "submitter_username" => "alice"
    }

    assert {:error, %{"type" => "unknown_workspace"}} = UserUse.execute(cmd)
  end

  test "missing workspace arg → invalid_args" do
    cmd = %{"submitted_by" => "ou_a", "args" => %{}, "submitter_username" => "alice"}
    assert {:error, %{"type" => "invalid_args"}} = UserUse.execute(cmd)
  end

  test "unresolvable submitter → unknown_user" do
    ws = WorkspaceFixture.build(name: "alice-ws", owner: "alice")
    :ok = WsRegistry.put(ws)

    cmd = %{
      "submitted_by" => "ou_unknown",
      "args" => %{"workspace" => "alice-ws"}
      # no submitter_username — caller couldn't resolve it
    }

    assert {:error, %{"type" => "unknown_user"}} = UserUse.execute(cmd)
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd runtime && mix test test/esr/commands/user/use_test.exs
```

Expected: FAIL — module `Esr.Commands.User.Use` not loaded.

- [ ] **Step 3: Create the module**

Create `runtime/lib/esr/commands/user/use.ex`:

```elixir
defmodule Esr.Commands.User.Use do
  @moduledoc """
  `/user:use workspace=<name>` — set the submitting user's default
  workspace.

  Symmetric to `/workspace:use` (which sets the chat-default). The
  user-default is the third layer of the `/session:new` workspace
  fallback chain (see `Esr.Commands.Workspace.Resolve`).

  ## Args
      args: %{"workspace" => "esr-dev"}

  ## Result shape
      {:ok,  %{"action" => "user_default_set",
               "username" => "alice", "workspace" => "esr-dev",
               "workspace_id" => "<uuid>"}}
      {:error, %{"type" => "invalid_args" | "unknown_workspace" |
                              "unknown_user", ...}}
  """

  @behaviour Esr.Role.Control

  alias Esr.Entity.User.Registry, as: UserRegistry
  alias Esr.Resource.Workspace.NameIndex, as: WsNameIndex
  alias Esr.Resource.Workspace.Registry, as: WsRegistry

  @type result :: {:ok, map()} | {:error, map()}

  @spec execute(map()) :: result()
  def execute(%{"args" => %{"workspace" => ws_name}} = cmd)
      when is_binary(ws_name) and ws_name != "" do
    with {:ok, username} <- resolve_submitter(cmd),
         {:ok, ws_id} <- resolve_workspace_id(ws_name),
         :ok <- UserRegistry.set_default_workspace(username, ws_id) do
      {:ok,
       %{
         "action" => "user_default_set",
         "username" => username,
         "workspace" => ws_name,
         "workspace_id" => ws_id
       }}
    end
  end

  def execute(_cmd) do
    {:error,
     %{
       "type" => "invalid_args",
       "message" => "/user:use requires args.workspace (non-empty string)"
     }}
  end

  defp resolve_submitter(%{"submitter_username" => username})
       when is_binary(username) and username != "",
       do: {:ok, username}

  defp resolve_submitter(%{"submitted_by" => ou_id}) when is_binary(ou_id) and ou_id != "" do
    case UserRegistry.lookup_by_feishu_id(ou_id) do
      {:ok, username} -> {:ok, username}
      :not_found -> {:error, %{"type" => "unknown_user", "message" => "submitter #{ou_id} has no esr-user binding"}}
    end
  end

  defp resolve_submitter(_),
    do: {:error, %{"type" => "unknown_user", "message" => "no submitter context"}}

  defp resolve_workspace_id(ws_name) do
    case WsNameIndex.id_for_name(:esr_workspace_name_index, ws_name) do
      {:ok, ws_id} ->
        case WsRegistry.get_by_id(ws_id) do
          {:ok, _} -> {:ok, ws_id}
          :not_found -> {:error, %{"type" => "unknown_workspace", "workspace" => ws_name}}
        end

      :not_found ->
        {:error, %{"type" => "unknown_workspace", "workspace" => ws_name}}
    end
  rescue
    ArgumentError -> {:error, %{"type" => "unknown_workspace", "workspace" => ws_name}}
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

```bash
cd runtime && mix test test/esr/commands/user/use_test.exs
```

Expected: PASS — 4 tests, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add runtime/lib/esr/commands/user/use.ex runtime/test/esr/commands/user/use_test.exs
git commit -m "feat(user): /user:use command — set per-user default workspace"
```

### Task 3.2: Wire `/user:use` into slash-routes.default.yaml

**Files:**
- Modify: `runtime/priv/slash-routes.default.yaml`

- [ ] **Step 1: Locate the Users category**

```bash
grep -n '"/user:whoami"' runtime/priv/slash-routes.default.yaml
```

- [ ] **Step 2: Add the new route after `/user:whoami`**

In `runtime/priv/slash-routes.default.yaml`, after the `/user:whoami` block (line ~58-65), insert:

```yaml
  "/user:use":
    kind: user_use
    permission: "workspace.create"
    command_module: "Esr.Commands.User.Use"
    requires_workspace_binding: false
    requires_user_binding: true
    category: "Users"
    description: "设当前 user 的 default workspace（per-user 偏好；/session:new fallback 链中 user-default 这一层）"
    args:
      - { name: workspace, required: true }
```

Also append to the `kind` overlay block (after `user_unbind_feishu` ~ line 586) so admin-submit reaches the command:

```yaml
  user_use:
    permission: "workspace.create"
    command_module: "Esr.Commands.User.Use"
```

- [ ] **Step 3: Verify yaml parses**

```bash
cd runtime && mix run -e 'YamlElixir.read_from_file!("priv/slash-routes.default.yaml")["slashes"]["/user:use"] |> IO.inspect()'
```

Expected: a map containing `kind: "user_use"`, `command_module: "Esr.Commands.User.Use"`.

- [ ] **Step 4: Boot smoke test — slash schema picks up the route**

```bash
cd runtime && mix test test/esr/web/controllers/slash_schema_controller_test.exs 2>&1 | tail -3
```

Expected: existing tests pass; if the schema endpoint enumerates routes, `/user:use` appears.

- [ ] **Step 5: Commit**

```bash
git add runtime/priv/slash-routes.default.yaml
git commit -m "feat(user): wire /user:use into slash-routes.default.yaml"
```

---

## Phase 4 — User.Add auto-creates user-default workspace

### Task 4.1: User.Add creates `<username>-default` workspace + sets as user-default

**Files:**
- Modify: `runtime/lib/esr/commands/user/add.ex`
- Test: `runtime/test/esr/commands/user/add_test.exs`

- [ ] **Step 1: Write the failing test**

Append to `runtime/test/esr/commands/user/add_test.exs`:

```elixir
describe "auto-create user-default workspace (M-5/D3)" do
  setup do
    on_exit(fn -> Esr.Test.WorkspaceFixture.reset!() end)
    :ok
  end

  test "user_add creates <username>-default workspace + sets as user-default" do
    name = "auto-#{System.unique_integer([:positive])}"
    cmd = %{"submitted_by" => "ou_admin", "args" => %{"name" => name}}

    assert {:ok, result} = Esr.Commands.User.Add.execute(cmd)

    assert result["default_workspace"] == "#{name}-default"
    assert is_binary(result["default_workspace_id"])

    # Workspace exists in registry
    {:ok, ws_id} =
      Esr.Resource.Workspace.NameIndex.id_for_name(
        :esr_workspace_name_index,
        "#{name}-default"
      )

    assert {:ok, ws} = Esr.Resource.Workspace.Registry.get_by_id(ws_id)
    assert ws.owner == name

    # User-default link populated
    assert {:ok, ^ws_id} = Esr.Entity.User.Registry.get_default_workspace(name)
  end

  test "user_add result map carries actor identity (Phase 4 contract)" do
    name = "shape-#{System.unique_integer([:positive])}"
    cmd = %{"submitted_by" => "ou_admin", "args" => %{"name" => name}}

    assert {:ok, result} = Esr.Commands.User.Add.execute(cmd)

    assert result["text"] =~ "added"
    assert is_binary(result["id"])
    assert is_binary(result["default_workspace_id"])
    assert result["default_workspace"] == "#{name}-default"
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd runtime && mix test test/esr/commands/user/add_test.exs --only describe:"auto-create user-default workspace"
```

Expected: FAIL — `result["default_workspace"]` does not exist; no workspace named `<name>-default` registered.

- [ ] **Step 3: Update User.Add**

Replace the `execute/1` clause in `runtime/lib/esr/commands/user/add.ex` (lines 26-65) with the new flow that auto-creates the workspace. Replace from `path = Esr.Paths.users_yaml()` through the `else` branch:

```elixir
        path = Esr.Paths.users_yaml()
        doc = read_or_empty(path)

        users = Map.get(doc, "users") || %{}

        if Map.has_key?(users, name) do
          {:error, %{"type" => "already_exists", "message" => "user '#{name}' already exists"}}
        else
          uuid = UUID.uuid4()
          ws_uuid = UUID.uuid4()
          ws_name = "#{name}-default"

          updated_users = Map.put(users, name, %{"feishu_ids" => []})
          updated_doc = Map.put(doc, "users", updated_users)

          with :ok <- Esr.Yaml.Writer.write(path, updated_doc),
               :ok <- write_user_json(uuid, name, ws_uuid),
               :ok <- create_user_default_workspace(ws_uuid, ws_name, name),
               :ok <- Esr.Entity.User.Registry.set_default_workspace(name, ws_uuid) do
            populate_name_index(name, uuid)

            {:ok,
             %{
               "text" => "added esr user #{name}",
               "id" => uuid,
               "default_workspace" => ws_name,
               "default_workspace_id" => ws_uuid
             }}
          else
            {:error, reason} ->
              {:error, %{"type" => "write_failed", "detail" => inspect(reason)}}
          end
        end
```

Update `write_user_json/2` to accept the workspace uuid:

```elixir
  defp write_user_json(uuid, username, default_workspace_id) do
    dir = Path.join(Esr.Paths.users_dir(), uuid)

    with :ok <- File.mkdir_p(dir) do
      path = Path.join(dir, "user.json")
      tmp = path <> ".tmp"

      doc = %{
        "schema_version" => 1,
        "id" => uuid,
        "username" => username,
        "display_name" => "",
        "feishu_ids" => [],
        "default_workspace_id" => default_workspace_id,
        "created_at" => DateTime.utc_now() |> DateTime.to_iso8601()
      }

      with :ok <- File.write(tmp, Jason.encode!(doc, pretty: true)),
           :ok <- File.rename(tmp, path) do
        :ok
      end
    end
  rescue
    e -> {:error, e}
  end
```

Add the workspace creation helper at the bottom of the module:

```elixir
  defp create_user_default_workspace(ws_uuid, ws_name, owner) do
    dir = Esr.Paths.workspace_dir(ws_name)

    with :ok <- File.mkdir_p(dir) do
      ws = %Esr.Resource.Workspace.Struct{
        id: ws_uuid,
        name: ws_name,
        owner: owner,
        folders: [],
        agent: "cc",
        settings: %{},
        env: %{},
        chats: [],
        transient: false,
        location: {:esr_bound, dir}
      }

      Esr.Resource.Workspace.Registry.put(ws)
    end
  rescue
    e -> {:error, e}
  end
```

- [ ] **Step 4: Run test to verify it passes**

```bash
cd runtime && mix test test/esr/commands/user/add_test.exs --only describe:"auto-create user-default workspace"
```

Expected: PASS — 2 tests, 0 failures.

- [ ] **Step 5: Run the existing user_add suite to confirm no regression**

```bash
cd runtime && mix test test/esr/commands/user/add_test.exs --seed 0 2>&1 | tail -3
```

Expected: PASS — every existing test still green; the placeholder Phase-2 test now sees a real workspace_id (test asserts `is_binary` so it survives).

- [ ] **Step 6: Commit**

```bash
git add runtime/lib/esr/commands/user/add.ex runtime/test/esr/commands/user/add_test.exs
git commit -m "feat(user): User.Add auto-creates <username>-default workspace + sets user-default link"
```

### Task 4.2: Update Phase-2 placeholder test now that default_workspace_id is real

**Files:**
- Modify: `runtime/test/esr/commands/user/add_test.exs` — the Phase-2 placeholder test now expects a real UUID

- [ ] **Step 1: Update the assertion**

In `runtime/test/esr/commands/user/add_test.exs`, find the test added in Task 2.3 ("user.json contains default_workspace_id key"). Replace `assert doc["default_workspace_id"] == nil` with:

```elixir
    assert is_binary(doc["default_workspace_id"])
```

- [ ] **Step 2: Run test**

```bash
cd runtime && mix test test/esr/commands/user/add_test.exs --only describe:"user.json default_workspace_id"
```

Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add runtime/test/esr/commands/user/add_test.exs
git commit -m "test(user): update Phase-2 placeholder test — default_workspace_id is now a real uuid"
```

---

## Phase 5 — Bootstrap rewrite (no literal "default")

### Task 5.1: `Esr.Resource.Workspace.Bootstrap` creates `<bootstrap_user>-default`

**Files:**
- Rewrite: `runtime/lib/esr/resource/workspace/bootstrap.ex`
- Test: `runtime/test/esr/resource/workspace/bootstrap_test.exs` (create or replace)

- [ ] **Step 1: Write the failing test**

Create `runtime/test/esr/resource/workspace/bootstrap_test.exs`:

```elixir
defmodule Esr.Resource.Workspace.BootstrapTest do
  use ExUnit.Case, async: false

  alias Esr.Entity.User.Registry, as: UserRegistry
  alias Esr.Resource.Workspace.Bootstrap
  alias Esr.Resource.Workspace.NameIndex
  alias Esr.Resource.Workspace.Registry, as: WsRegistry

  setup do
    on_exit(fn -> Esr.Test.WorkspaceFixture.reset!() end)
    :ok
  end

  test "no-op when ESR_BOOTSTRAP_PRINCIPAL_ID is unset" do
    System.delete_env("ESR_BOOTSTRAP_PRINCIPAL_ID")
    assert :ok = Bootstrap.run()

    # Critical: no workspace named literally "default" was created
    assert :not_found = NameIndex.id_for_name(:esr_workspace_name_index, "default")
  end

  test "creates <bootstrap_user>-default + sets it as user-default when env is set" do
    UserRegistry.load_snapshot_with_uuids(
      %{
        "linyilun" => %UserRegistry.User{username: "linyilun", feishu_ids: ["ou_lin"]}
      },
      %{"linyilun" => "linyilun-uuid"}
    )

    System.put_env("ESR_BOOTSTRAP_PRINCIPAL_ID", "ou_lin")
    on_exit(fn -> System.delete_env("ESR_BOOTSTRAP_PRINCIPAL_ID") end)

    assert :ok = Bootstrap.run()

    {:ok, ws_id} = NameIndex.id_for_name(:esr_workspace_name_index, "linyilun-default")
    assert {:ok, ws} = WsRegistry.get_by_id(ws_id)
    assert ws.owner == "linyilun"

    assert {:ok, ^ws_id} = UserRegistry.get_default_workspace("linyilun")

    # Negative assertion: literal "default" still does not exist
    assert :not_found = NameIndex.id_for_name(:esr_workspace_name_index, "default")
  end

  test "idempotent: re-running with the same user does not create a second workspace" do
    UserRegistry.load_snapshot_with_uuids(
      %{
        "alice" => %UserRegistry.User{username: "alice", feishu_ids: ["ou_a"]}
      },
      %{"alice" => "alice-uuid"}
    )

    System.put_env("ESR_BOOTSTRAP_PRINCIPAL_ID", "ou_a")
    on_exit(fn -> System.delete_env("ESR_BOOTSTRAP_PRINCIPAL_ID") end)

    :ok = Bootstrap.run()
    {:ok, first_id} = NameIndex.id_for_name(:esr_workspace_name_index, "alice-default")

    :ok = Bootstrap.run()
    {:ok, second_id} = NameIndex.id_for_name(:esr_workspace_name_index, "alice-default")

    assert first_id == second_id
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd runtime && mix test test/esr/resource/workspace/bootstrap_test.exs
```

Expected: FAIL — current Bootstrap creates literal `"default"`, the negative assertion fires.

- [ ] **Step 3: Rewrite Bootstrap**

Replace the body of `runtime/lib/esr/resource/workspace/bootstrap.ex` with:

```elixir
defmodule Esr.Resource.Workspace.Bootstrap do
  @moduledoc """
  First-boot tasks for the workspace subsystem (M-5 / D4):

    * Delete legacy `workspaces.yaml` if present.
    * If `ESR_BOOTSTRAP_PRINCIPAL_ID` is set AND that principal resolves
      to an esr user AND the user has no `default_workspace_id`, create
      `<username>-default` and link it via
      `Esr.Entity.User.Registry.set_default_workspace/2`.

  No literal `default` workspace is created. After M-5 the resolver
  chain (Esr.Commands.Workspace.Resolve) walks chat-default →
  user-default → error, so a per-user default workspace replaces the
  pre-M-5 system fallback.
  """

  use Task, restart: :transient
  require Logger

  alias Esr.Entity.User.Registry, as: UserRegistry
  alias Esr.Resource.Workspace.NameIndex, as: WsNameIndex
  alias Esr.Resource.Workspace.Registry, as: WsRegistry

  def start_link(_), do: Task.start_link(__MODULE__, :run, [])

  def run do
    delete_legacy_yaml()
    ensure_bootstrap_user_default()
    :ok
  end

  defp delete_legacy_yaml do
    legacy_path = Path.join(Esr.Paths.runtime_home(), "workspaces.yaml")

    if File.exists?(legacy_path) do
      case File.rm(legacy_path) do
        :ok ->
          Logger.warning(
            "workspace.bootstrap: deleted legacy #{legacy_path}; recreate workspaces via /workspace:new"
          )

        {:error, reason} ->
          Logger.error(
            "workspace.bootstrap: failed to delete legacy #{legacy_path}: #{inspect(reason)}"
          )
      end
    end
  end

  defp ensure_bootstrap_user_default do
    with bootstrap_id when is_binary(bootstrap_id) and bootstrap_id != "" <-
           System.get_env("ESR_BOOTSTRAP_PRINCIPAL_ID"),
         {:ok, username} <- UserRegistry.lookup_by_feishu_id(bootstrap_id),
         :not_found <- UserRegistry.get_default_workspace(username) do
      create_user_default_for(username)
    else
      {:ok, _ws_id} ->
        # Already linked — idempotent skip.
        :ok

      _ ->
        :ok
    end
  rescue
    _ ->
      # Registry / NameIndex ETS tables not running (e.g. early test setups). Skip.
      :ok
  end

  defp create_user_default_for(username) do
    ws_name = "#{username}-default"

    case WsNameIndex.id_for_name(:esr_workspace_name_index, ws_name) do
      {:ok, ws_id} ->
        # Workspace already exists (perhaps from a prior /user:add).
        # Just link it to the user-default.
        _ = UserRegistry.set_default_workspace(username, ws_id)
        :ok

      :not_found ->
        ws_uuid = UUID.uuid4()
        dir = Esr.Paths.workspace_dir(ws_name)
        File.mkdir_p!(dir)

        ws = %Esr.Resource.Workspace.Struct{
          id: ws_uuid,
          name: ws_name,
          owner: username,
          folders: [],
          agent: "cc",
          settings: %{},
          env: %{},
          chats: [],
          transient: false,
          location: {:esr_bound, dir}
        }

        case WsRegistry.put(ws) do
          :ok ->
            _ = UserRegistry.set_default_workspace(username, ws_uuid)

            Logger.info(
              "workspace.bootstrap: created #{ws_name} at #{dir} (id=#{ws_uuid}) + linked as user-default"
            )

            :ok

          {:error, reason} ->
            Logger.error(
              "workspace.bootstrap: failed to put #{ws_name}: #{inspect(reason)}"
            )

            :ok
        end
    end
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

```bash
cd runtime && mix test test/esr/resource/workspace/bootstrap_test.exs --seed 0
```

Expected: PASS — 3 tests, 0 failures.

- [ ] **Step 5: Run the application_first_boot_test to catch any breakage**

```bash
cd runtime && mix test test/esr/application_first_boot_test.exs --seed 0 2>&1 | tail -3
```

Expected: 5 tests; some assertions about the literal `"default"` workspace will likely now fail — fix in next task.

- [ ] **Step 6: Commit**

```bash
git add runtime/lib/esr/resource/workspace/bootstrap.ex runtime/test/esr/resource/workspace/bootstrap_test.exs
git commit -m "feat(workspace): Bootstrap creates <bootstrap_user>-default, not literal default (M-5/D4)"
```

### Task 5.2: Update `application_first_boot_test.exs` for the new bootstrap shape

**Files:**
- Modify: `runtime/test/esr/application_first_boot_test.exs`

- [ ] **Step 1: Run the test and read the failures**

```bash
cd runtime && mix test test/esr/application_first_boot_test.exs --seed 0 2>&1 | tail -25
```

Expected: tests that assert on `name == "default"` fail.

- [ ] **Step 2: Update the assertions**

In `runtime/test/esr/application_first_boot_test.exs`, locate the `describe "ensure_default_workspace"` block. Replace each test that depends on a literal `"default"` workspace with a test that exercises the new bootstrap-user path. Keep the test name/structure but update assertions:

```elixir
  describe "bootstrap user-default workspace" do
    setup do
      # Seed a known user so Bootstrap can resolve the env id
      Esr.Entity.User.Registry.load_snapshot_with_uuids(
        %{
          "bootstrapper" => %Esr.Entity.User.Registry.User{
            username: "bootstrapper",
            feishu_ids: ["ou_boot"]
          }
        },
        %{"bootstrapper" => "bootstrapper-uuid"}
      )

      System.put_env("ESR_BOOTSTRAP_PRINCIPAL_ID", "ou_boot")
      on_exit(fn -> System.delete_env("ESR_BOOTSTRAP_PRINCIPAL_ID") end)
      :ok
    end

    test "Bootstrap creates <user>-default + links it" do
      assert :ok = Bootstrap.run()

      {:ok, id} =
        Esr.Resource.Workspace.NameIndex.id_for_name(
          :esr_workspace_name_index,
          "bootstrapper-default"
        )

      assert {:ok, ws} = Registry.get_by_id(id)
      assert ws.name == "bootstrapper-default"

      assert {:ok, ^id} =
               Esr.Entity.User.Registry.get_default_workspace("bootstrapper")
    end

    test "is idempotent — running twice does not create a second workspace" do
      assert :ok = Bootstrap.run()
      {:ok, id1} =
        Esr.Resource.Workspace.NameIndex.id_for_name(
          :esr_workspace_name_index,
          "bootstrapper-default"
        )

      assert :ok = Bootstrap.run()
      {:ok, id2} =
        Esr.Resource.Workspace.NameIndex.id_for_name(
          :esr_workspace_name_index,
          "bootstrapper-default"
        )

      assert id1 == id2
    end

    test "deletes legacy yaml + leaves bootstrap workspace intact",
         %{runtime_home: runtime_home} do
      File.write!(Path.join(runtime_home, "workspaces.yaml"), "stale: yes")

      assert :ok = Bootstrap.run()

      refute File.exists?(Path.join(runtime_home, "workspaces.yaml"))

      {:ok, id} =
        Esr.Resource.Workspace.NameIndex.id_for_name(
          :esr_workspace_name_index,
          "bootstrapper-default"
        )

      assert {:ok, _} = Registry.get_by_id(id)
    end
  end
```

Delete the old `describe "ensure_default_workspace"` block in its entirety.

- [ ] **Step 3: Run the test**

```bash
cd runtime && mix test test/esr/application_first_boot_test.exs --seed 0 2>&1 | tail -5
```

Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add runtime/test/esr/application_first_boot_test.exs
git commit -m "test(workspace): application_first_boot — drop literal default, assert <user>-default"
```

---

## Phase 6 — Workspace.Resolve helper + Scope.New chain rewrite

### Task 6.1: Create `Esr.Commands.Workspace.Resolve`

**Files:**
- Create: `runtime/lib/esr/commands/workspace/resolve.ex`
- Create: `runtime/test/esr/commands/workspace/resolve_test.exs`

- [ ] **Step 1: Write the failing test**

Create `runtime/test/esr/commands/workspace/resolve_test.exs`:

```elixir
defmodule Esr.Commands.Workspace.ResolveTest do
  use ExUnit.Case, async: false

  alias Esr.Commands.Workspace.Resolve
  alias Esr.Entity.User.Registry, as: UserRegistry
  alias Esr.Resource.ChatScope.Registry, as: ChatScope
  alias Esr.Resource.Workspace.Registry, as: WsRegistry
  alias Esr.Test.WorkspaceFixture

  setup do
    UserRegistry.load_snapshot_with_uuids(
      %{
        "alice" => %UserRegistry.User{username: "alice", feishu_ids: ["ou_a"]}
      },
      %{"alice" => "alice-uuid"}
    )

    on_exit(fn -> WorkspaceFixture.reset!() end)
    :ok
  end

  describe "resolve_workspace_for_args/1 — fallback chain" do
    test "explicit args.workspace wins" do
      ws = WorkspaceFixture.build(name: "explicit-ws", owner: "alice")
      :ok = WsRegistry.put(ws)

      args = %{"workspace" => "explicit-ws", "submitter_username" => "alice"}
      assert {:explicit, "explicit-ws"} = Resolve.resolve_workspace_for_args(args)
    end

    test "chat-default wins over user-default" do
      ws_chat = WorkspaceFixture.build(name: "chat-ws", owner: "alice")
      :ok = WsRegistry.put(ws_chat)

      ws_user = WorkspaceFixture.build(name: "user-ws", owner: "alice")
      :ok = WsRegistry.put(ws_user)

      :ok = ChatScope.set_default_workspace("oc_x", "cli_a", ws_chat.id)
      :ok = UserRegistry.set_default_workspace("alice", ws_user.id)

      args = %{
        "chat_id" => "oc_x",
        "app_id" => "cli_a",
        "submitter_username" => "alice"
      }

      assert {:chat_default, "chat-ws"} = Resolve.resolve_workspace_for_args(args)
    end

    test "user-default fires when no explicit + no chat-default" do
      ws_user = WorkspaceFixture.build(name: "user-ws", owner: "alice")
      :ok = WsRegistry.put(ws_user)
      :ok = UserRegistry.set_default_workspace("alice", ws_user.id)

      args = %{"submitter_username" => "alice"}
      assert {:user_default, "user-ws"} = Resolve.resolve_workspace_for_args(args)
    end

    test "no_match when nothing in any layer" do
      args = %{"submitter_username" => "alice"}
      assert :no_match = Resolve.resolve_workspace_for_args(args)
    end

    test "submitter_username resolved via lookup_by_feishu_id when only submitted_by present" do
      ws_user = WorkspaceFixture.build(name: "alice-ws", owner: "alice")
      :ok = WsRegistry.put(ws_user)
      :ok = UserRegistry.set_default_workspace("alice", ws_user.id)

      args = %{"submitted_by" => "ou_a"}
      assert {:user_default, "alice-ws"} = Resolve.resolve_workspace_for_args(args)
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd runtime && mix test test/esr/commands/workspace/resolve_test.exs
```

Expected: FAIL — module `Esr.Commands.Workspace.Resolve` not loaded.

- [ ] **Step 3: Create the module**

Create `runtime/lib/esr/commands/workspace/resolve.ex`:

```elixir
defmodule Esr.Commands.Workspace.Resolve do
  @moduledoc """
  Single workspace-resolution chain shared by `/session:new` and
  `/workspace:add-folder` (M-5).

  Specificity ladder:

      1. explicit args["workspace"]                  ← {:explicit, name}
      2. chat-default via ChatScope.Registry         ← {:chat_default, name}
      3. user-default via User.Registry              ← {:user_default, name}
      4. :no_match                                   ← caller maps to error

  The resolver only returns workspace **names** (not UUIDs); callers
  re-resolve via `Workspace.NameIndex` if they need the UUID — keeps
  the chain pure and testable without a UUID mocking layer.

  Submitter is sourced from `args["submitter_username"]` when present,
  otherwise resolved via `User.Registry.lookup_by_feishu_id/1` from
  `args["submitted_by"]`.
  """

  alias Esr.Entity.User.Registry, as: UserRegistry
  alias Esr.Resource.ChatScope.Registry, as: ChatScope
  alias Esr.Resource.Workspace.NameIndex, as: WsNameIndex
  alias Esr.Resource.Workspace.Registry, as: WsRegistry

  @type tag ::
          {:explicit, String.t()}
          | {:chat_default, String.t()}
          | {:user_default, String.t()}
          | :no_match

  @spec resolve_workspace_for_args(map()) :: tag()
  def resolve_workspace_for_args(args) when is_map(args) do
    cond do
      is_binary(args["workspace"]) and args["workspace"] != "" ->
        {:explicit, args["workspace"]}

      (chat_default_name = lookup_chat_default(args)) != nil ->
        {:chat_default, chat_default_name}

      (user_default_name = lookup_user_default(args)) != nil ->
        {:user_default, user_default_name}

      true ->
        :no_match
    end
  end

  defp lookup_chat_default(args) do
    with chat_id when is_binary(chat_id) and chat_id != "" <- args["chat_id"],
         app_id when is_binary(app_id) and app_id != "" <- args["app_id"],
         {:ok, ws_uuid} <- ChatScope.get_default_workspace(chat_id, app_id),
         {:ok, ws} <- WsRegistry.get_by_id(ws_uuid) do
      ws.name
    else
      _ -> nil
    end
  end

  defp lookup_user_default(args) do
    with {:ok, username} <- resolve_submitter(args),
         {:ok, ws_uuid} <- UserRegistry.get_default_workspace(username),
         {:ok, ws} <- WsRegistry.get_by_id(ws_uuid) do
      ws.name
    else
      _ -> nil
    end
  end

  defp resolve_submitter(%{"submitter_username" => username})
       when is_binary(username) and username != "",
       do: {:ok, username}

  defp resolve_submitter(%{"submitted_by" => ou_id}) when is_binary(ou_id) and ou_id != "" do
    UserRegistry.lookup_by_feishu_id(ou_id)
  end

  defp resolve_submitter(_), do: :not_found

  # Convenience for callers that only need a name and don't care which
  # layer hit — used by /workspace:add-folder.
  @spec workspace_name_for_args(map()) :: {:ok, String.t()} | :no_match
  def workspace_name_for_args(args) do
    case resolve_workspace_for_args(args) do
      {_tag, name} -> {:ok, name}
      :no_match -> :no_match
    end
  end

  # Convenience for callers that need the UUID directly.
  @spec workspace_id_for_args(map()) :: {:ok, String.t()} | :no_match | :workspace_gone
  def workspace_id_for_args(args) do
    with {:ok, name} <- workspace_name_for_args(args),
         {:ok, id} <- WsNameIndex.id_for_name(:esr_workspace_name_index, name) do
      {:ok, id}
    else
      :no_match -> :no_match
      :not_found -> :workspace_gone
    end
  rescue
    ArgumentError -> :no_match
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

```bash
cd runtime && mix test test/esr/commands/workspace/resolve_test.exs
```

Expected: PASS — 5 tests, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add runtime/lib/esr/commands/workspace/resolve.ex runtime/test/esr/commands/workspace/resolve_test.exs
git commit -m "feat(workspace): Resolve helper — explicit → chat-default → user-default chain"
```

### Task 6.2: Switch `Esr.Commands.Scope.New.resolve_workspace` to the shared chain

**Files:**
- Modify: `runtime/lib/esr/commands/scope/new.ex` — `resolve_workspace_if_needed/1` and `resolve_workspace/1`
- Test: `runtime/test/esr/commands/scope/new_resolve_workspace_test.exs`

- [ ] **Step 1: Write the failing test**

Append to `runtime/test/esr/commands/scope/new_resolve_workspace_test.exs` a new describe block:

```elixir
describe "resolve_workspace_if_needed/1 — M-5 chain (user-default replaces system default)" do
  setup do
    Esr.Entity.User.Registry.load_snapshot_with_uuids(
      %{
        "alice" => %Esr.Entity.User.Registry.User{username: "alice", feishu_ids: ["ou_a"]}
      },
      %{"alice" => "alice-uuid"}
    )

    on_exit(fn -> Esr.Test.WorkspaceFixture.reset!() end)
    :ok
  end

  test "no_workspace_resolvable when no chain layer matches" do
    args = %{"submitter_username" => "alice"}
    # No explicit, no chat-default, no user-default
    assert {:error, %{"type" => "no_workspace_resolvable"}} =
             Esr.Commands.Scope.New.resolve_workspace_if_needed(args)
  end

  test "user-default wins when chat-default absent" do
    ws = Esr.Test.WorkspaceFixture.build(name: "alice-ws", owner: "alice")
    :ok = Esr.Resource.Workspace.Registry.put(ws)
    :ok = Esr.Entity.User.Registry.set_default_workspace("alice", ws.id)

    args = %{"submitter_username" => "alice"}
    assert {:ok, "alice-ws"} = Esr.Commands.Scope.New.resolve_workspace_if_needed(args)
  end

  test "literal `default` no longer wins as a fallback" do
    # Even if a workspace named literally `default` exists, it must not be
    # preferred — only chat-default / user-default layers fire.
    ws = Esr.Test.WorkspaceFixture.build(name: "default", owner: "alice")
    :ok = Esr.Resource.Workspace.Registry.put(ws)

    # alice has NO user-default link. No chat context.
    args = %{"submitter_username" => "alice"}
    assert {:error, %{"type" => "no_workspace_resolvable"}} =
             Esr.Commands.Scope.New.resolve_workspace_if_needed(args)
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd runtime && mix test test/esr/commands/scope/new_resolve_workspace_test.exs --only describe:"resolve_workspace_if_needed/1 — M-5 chain"
```

Expected: FAIL on the `literal default no longer wins` test — current code falls through to literal `"default"`.

- [ ] **Step 3: Switch the implementation to call Resolve helper**

In `runtime/lib/esr/commands/scope/new.ex`, replace the body of `resolve_workspace_if_needed/1` (line ~296-323) and `resolve_workspace/1` (line ~325-339) with:

```elixir
  @doc false
  def resolve_workspace_if_needed(args) do
    cond do
      # (a) workspace explicitly given — nothing to do
      is_binary(args["workspace"]) and args["workspace"] != "" ->
        :no_resolution_needed

      # (b) agent explicitly given — legacy "no workspace, agent-only" mode
      is_binary(args["agent"]) and args["agent"] != "" ->
        :no_resolution_needed

      # (c) neither: walk the M-5 fallback chain
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
```

Delete the now-dead `resolve_workspace/1`, `lookup_chat_default/1`, `workspace_exists?/1` helpers (lines ~325-360) — they live on Resolve now.

- [ ] **Step 4: Run test to verify it passes**

```bash
cd runtime && mix test test/esr/commands/scope/new_resolve_workspace_test.exs --seed 0 2>&1 | tail -5
```

Expected: PASS — including the M-5 chain tests + every legacy resolve test.

- [ ] **Step 5: Run the broader scope/new test surface**

```bash
cd runtime && mix test test/esr/commands/scope/ --seed 0 2>&1 | tail -5
```

Expected: PASS for the entire scope/ folder.

- [ ] **Step 6: Commit**

```bash
git add runtime/lib/esr/commands/scope/new.ex runtime/test/esr/commands/scope/new_resolve_workspace_test.exs
git commit -m "feat(scope): /session:new fallback chain → Resolve helper (user-default replaces system default)"
```

---

## Phase 7 — `/workspace:add-folder name=` optional

### Task 7.1: AddFolder accepts implicit `name=` via Resolve chain

**Files:**
- Modify: `runtime/lib/esr/commands/workspace/add_folder.ex`
- Test: `runtime/test/esr/commands/workspace/add_folder_test.exs`

- [ ] **Step 1: Write the failing test**

Append to `runtime/test/esr/commands/workspace/add_folder_test.exs`:

```elixir
describe "name= optional via Resolve chain (M-5/D5)" do
  setup do
    Esr.Entity.User.Registry.load_snapshot_with_uuids(
      %{
        "alice" => %Esr.Entity.User.Registry.User{username: "alice", feishu_ids: ["ou_a"]}
      },
      %{"alice" => "alice-uuid"}
    )

    on_exit(fn -> Esr.Test.WorkspaceFixture.reset!() end)
    :ok
  end

  test "name= falls back to chat-current when omitted" do
    ws = Esr.Test.WorkspaceFixture.build(name: "alice-ws", owner: "alice")
    :ok = Esr.Resource.Workspace.Registry.put(ws)

    :ok =
      Esr.Resource.ChatScope.Registry.set_default_workspace("oc_x", "cli_a", ws.id)

    repo_path = make_tmp_git_repo!("addfolder-chat-current")

    cmd = %{
      "submitted_by" => "ou_a",
      "submitter_username" => "alice",
      "args" => %{
        "chat_id" => "oc_x",
        "app_id" => "cli_a",
        "path" => repo_path
      }
    }

    assert {:ok, %{"name" => "alice-ws"}} =
             Esr.Commands.Workspace.AddFolder.execute(cmd)
  end

  test "name= falls back to user-default when no chat-current" do
    ws = Esr.Test.WorkspaceFixture.build(name: "alice-ws", owner: "alice")
    :ok = Esr.Resource.Workspace.Registry.put(ws)
    :ok = Esr.Entity.User.Registry.set_default_workspace("alice", ws.id)

    repo_path = make_tmp_git_repo!("addfolder-user-default")

    cmd = %{
      "submitted_by" => "ou_a",
      "submitter_username" => "alice",
      "args" => %{"path" => repo_path}
    }

    assert {:ok, %{"name" => "alice-ws"}} =
             Esr.Commands.Workspace.AddFolder.execute(cmd)
  end

  test "name= omitted with no chain layer → no_workspace_target" do
    repo_path = make_tmp_git_repo!("addfolder-no-target")

    cmd = %{
      "submitted_by" => "ou_a",
      "submitter_username" => "alice",
      "args" => %{"path" => repo_path}
    }

    assert {:error, %{"type" => "no_workspace_target"}} =
             Esr.Commands.Workspace.AddFolder.execute(cmd)
  end

  defp make_tmp_git_repo!(label) do
    dir = Path.join(System.tmp_dir!(), "esr-addfolder-#{label}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, ".git"))
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd runtime && mix test test/esr/commands/workspace/add_folder_test.exs --only describe:"name= optional via Resolve chain"
```

Expected: FAIL — `AddFolder.execute/1` requires `name`, falls through to the catch-all `invalid_args` branch.

- [ ] **Step 3: Add the resolution branch**

In `runtime/lib/esr/commands/workspace/add_folder.ex`, ADD a new clause BEFORE the existing main clause (line ~29). The function head with `name` stays as-is for explicit-name calls; the new clause covers the omitted case:

```elixir
  # M-5/D5: name= is optional. When omitted, fall back through the
  # shared Resolve chain (chat-current → user-default → error).
  def execute(%{"args" => %{"path" => path} = args} = cmd)
      when is_binary(path) and path != "" and not is_map_key(args, "name") do
    case Esr.Commands.Workspace.Resolve.resolve_workspace_for_args(merge_submitter(cmd, args)) do
      {_tag, name} ->
        execute(%{cmd | "args" => Map.put(args, "name", name)})

      :no_match ->
        {:error,
         %{
           "type" => "no_workspace_target",
           "message" =>
             "name= omitted but no chat-default and no user-default for submitter; " <>
               "pass name=<workspace> explicitly or run `/user:use workspace=<n>` first"
         }}
    end
  end

  defp merge_submitter(cmd, args) do
    args
    |> Map.put_new("submitted_by", cmd["submitted_by"])
    |> Map.put_new("submitter_username", cmd["submitter_username"])
  end
```

- [ ] **Step 4: Run test to verify it passes**

```bash
cd runtime && mix test test/esr/commands/workspace/add_folder_test.exs --seed 0 2>&1 | tail -5
```

Expected: PASS for all old + new tests.

- [ ] **Step 5: Update slash-routes.default.yaml — `name` becomes optional**

In `runtime/priv/slash-routes.default.yaml`, locate the `/workspace:add-folder` block. Change `name` to `required: false` and update the description:

```yaml
  "/workspace:add-folder":
    kind: workspace_add_folder
    permission: "workspace.create"
    command_module: "Esr.Commands.Workspace.AddFolder"
    requires_workspace_binding: false
    requires_user_binding: true
    category: "Workspace"
    description: "追加 folder 到 workspace.folders[]（path 必须是绝对路径且为 git repo；name= 缺省时 fallback 到 chat-current → user-default）"
    args:
      - { name: name, required: false }
      - { name: path, required: true }
      - { name: folder_name, required: false }
```

- [ ] **Step 6: Commit**

```bash
git add runtime/lib/esr/commands/workspace/add_folder.ex runtime/test/esr/commands/workspace/add_folder_test.exs runtime/priv/slash-routes.default.yaml
git commit -m "feat(workspace): /workspace:add-folder name= optional, fall back through Resolve chain"
```

---

## Phase 8 — E2E scenario 19 (REQUIRED before PR per user)

### Task 8.1: Create scenario 19 — first-time-operator session-first path

**Files:**
- Create: `tests/e2e/scenarios/19_session_first_default.sh`
- Modify: `Makefile` — add `e2e-19` target

- [ ] **Step 1: Write the scenario script**

Create `tests/e2e/scenarios/19_session_first_default.sh`:

```bash
#!/usr/bin/env bash
# e2e scenario 19 — session-first default workspace resolution.
#
# Spec: docs/superpowers/specs/2026-05-08-session-first-default-resolution.md
#
# WHAT THIS TEST PROVES:
#   - /user:add auto-creates <username>-default workspace + sets as user-default
#     (M-5/D3).
#   - /user:use changes the user-default to a different workspace (M-5/§4.3).
#   - /session:new without any workspace= arg + no chat-default uses
#     user-default per Resolve chain (M-5/§4.6).
#   - The literal name "default" is no longer a fallback; sessions only
#     resolve via chat-default or user-default.
#   - /workspace:add-folder works without name= when chat-current or
#     user-default is set (M-5/D5).
#
# COMPLEMENTS scenario 14 + 18 which exercise multi-agent + multi-instance
# spawn paths after a session has been created.
#
# INVARIANT GATE (spec §11):
#   bash tests/e2e/scenarios/19_session_first_default.sh 2>&1 | tail -3
#   → "PASS: 19_session_first_default"

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./common.sh
source "${SCRIPT_DIR}/common.sh"

# --- setup ------------------------------------------------------------
load_agent_yaml
seed_plugin_config
seed_capabilities
# Note: NOT seeding any workspace via seed_workspaces — the whole point
# is the operator never typed a workspace name.
seed_adapters
start_esrd

# --- step 1: add a fresh user — auto-creates user-default workspace ---
USERNAME="autodef_$(uuidgen | tr '[:upper:]' '[:lower:]' | tr -d '-' | head -c 8)"

ADD_OUT=$(esr_cli admin submit user_add \
  --arg name="${USERNAME}" \
  --wait --timeout 30)

echo "19 user_add output: ${ADD_OUT}"
assert_contains "$ADD_OUT" "ok: true"                    "19: user_add ok"
assert_contains "$ADD_OUT" "default_workspace"           "19: result carries default_workspace"
assert_contains "$ADD_OUT" "${USERNAME}-default"         "19: name is <username>-default"

# --- step 2: /session:new — should resolve to user-default -----------
WORKDIR="/tmp/esr-e2e-${ESR_E2E_RUN_ID}/session-19"
mkdir -p "${WORKDIR}"

SESSION_OUT=$(esr_cli admin submit session_new \
  --arg agent=cc \
  --arg dir="${WORKDIR}" \
  --arg submitter_username="${USERNAME}" \
  --wait --timeout 30)

echo "19 session_new output: ${SESSION_OUT}"
assert_contains "$SESSION_OUT" "ok: true"               "19: session_new ok"
assert_contains "$SESSION_OUT" "${USERNAME}-default"    "19: session bound to user-default ws"

SID=$(echo "$SESSION_OUT" | awk -F': ' '/^session_id:/ {print $2; exit}')
[[ -n "$SID" ]] || _fail_with_context "19: no session_id from session_new"
echo "19: session created: ${SID}"

# --- step 3: /workspace:add-folder (no name=) — uses user-default ----
REPO_DIR="/tmp/esr-e2e-${ESR_E2E_RUN_ID}/repo-19"
mkdir -p "${REPO_DIR}/.git"

ADDFOLDER_OUT=$(esr_cli admin submit workspace_add_folder \
  --arg path="${REPO_DIR}" \
  --arg submitter_username="${USERNAME}" \
  --wait --timeout 30)

echo "19 workspace_add_folder (no name): ${ADDFOLDER_OUT}"
assert_contains "$ADDFOLDER_OUT" "ok: true"             "19: add-folder ok without name"
assert_contains "$ADDFOLDER_OUT" "${USERNAME}-default"  "19: add-folder routed to user-default"

# --- step 4: /user:use — switch user-default to a different ws -------
SECOND_WS="${USERNAME}-secondary"
esr_cli admin submit workspace_new \
  --arg name="${SECOND_WS}" \
  --arg owner="${USERNAME}" \
  --wait --timeout 30 > /dev/null

USE_OUT=$(esr_cli admin submit user_use \
  --arg workspace="${SECOND_WS}" \
  --arg submitter_username="${USERNAME}" \
  --wait --timeout 20)

echo "19 user_use: ${USE_OUT}"
assert_contains "$USE_OUT" "ok: true"                    "19: user_use ok"
assert_contains "$USE_OUT" "${SECOND_WS}"                "19: user_use returns new ws name"

# --- step 5: re-/session:new — should bind to the NEW user-default ---
SESSION2_OUT=$(esr_cli admin submit session_new \
  --arg agent=cc \
  --arg dir="${WORKDIR}-2" \
  --arg submitter_username="${USERNAME}" \
  --wait --timeout 30)

echo "19 session_new#2 output: ${SESSION2_OUT}"
assert_contains "$SESSION2_OUT" "ok: true"               "19: 2nd session_new ok"
assert_contains "$SESSION2_OUT" "${SECOND_WS}"           "19: 2nd session bound to new user-default"

# --- step 6: literal "default" workspace must NOT exist post-bootstrap
DESCRIBE_OUT=$(esr_cli admin submit workspace_describe \
  --arg workspace=default \
  --wait --timeout 15 2>&1 || true)

echo "19 describe default: ${DESCRIBE_OUT}"
assert_contains "$DESCRIBE_OUT" "unknown_workspace" \
  "19: literal `default` workspace must not exist (M-5/D4)"

# --- cleanup ----------------------------------------------------------
esr_cli admin submit session_end \
  --arg session_id="${SID}" \
  --wait --timeout 20 > /dev/null || true

mkdir -p "${WORKDIR}-2"
echo "PASS: 19_session_first_default"
```

- [ ] **Step 2: Make it executable**

```bash
chmod +x tests/e2e/scenarios/19_session_first_default.sh
```

- [ ] **Step 3: Add the Makefile target**

In `Makefile`, add `e2e-19` to the `.PHONY` line and a new target after `e2e-18`:

```makefile
# M-5: session-first default resolution. Verifies user-default replaces
# system "default" workspace, /user:use changes the user-default, and
# /workspace:add-folder name= falls back through the chain.
e2e-19:
	$(E2E_RUN) tests/e2e/scenarios/19_session_first_default.sh
```

Update the `.PHONY` list to include `e2e-19`.

- [ ] **Step 4: Syntax-check the script**

```bash
bash -n tests/e2e/scenarios/19_session_first_default.sh && echo "syntax OK"
```

Expected: `syntax OK`.

- [ ] **Step 5: Run scenario 19 against a fresh esrd**

Wipe the env first (every scenario starts from clean state):

```bash
echo yes | bash tools/wipe-esrd-home.sh --dev
make e2e-19 2>&1 | tail -10
```

Expected: `PASS: 19_session_first_default` in the tail.

- [ ] **Step 6: Commit**

```bash
git add tests/e2e/scenarios/19_session_first_default.sh Makefile
git commit -m "test(e2e): scenario 19 — session-first default workspace resolution"
```

---

## Phase 9 — Docs sweep

### Task 9.1: Update audit doc to close the gap

**Files:**
- Modify: `docs/manual-checks/2026-05-08-post-multi-instance-audit.md` + `.zh_cn.md`

- [ ] **Step 1: Update the gap-A entry**

In `docs/manual-checks/2026-05-08-post-multi-instance-audit.md`, locate "### A. `/session:list` + ..." (the §3 cross-cutting closure section). Add a new §3 closure block ABOVE the open gaps:

```markdown
### Session-first default resolution — **CLOSED 2026-05-08**

PR #<NN> (spec `2026-05-08-session-first-default-resolution.md`) replaced
the system "default" workspace fallback with a per-user default;
`/user:add` auto-creates `<username>-default`; new `/user:use`
slash sets the user-default; `/workspace:add-folder name=` falls back
through the same chain. Audit step 9's "session-first" 1-2-3 path
(`/session:new` → `/workspace:add-folder` → `/session:add-agent`)
now works without ever typing a workspace name.
```

Mirror the same change in `2026-05-08-post-multi-instance-audit.zh_cn.md` (Chinese phrasing).

- [ ] **Step 2: Commit**

```bash
git add docs/manual-checks/2026-05-08-post-multi-instance-audit.md docs/manual-checks/2026-05-08-post-multi-instance-audit.zh_cn.md
git commit -m "docs(audit): mark session-first default resolution closed"
```

### Task 9.2: Update `docs/futures/todo.md`

**Files:**
- Modify: `docs/futures/todo.md`

- [ ] **Step 1: Mark the item closed**

In `docs/futures/todo.md`, find the row for "Migrate to session-first model" (audit task 5). Update its row to:

```markdown
| **Migrate to session-first model** | ✅ Phase 1 shipped 2026-05-08 (PR #<NN>) — user-default replaces system default, /user:use, auto-create on /user:add. Phase 2 (`/session:add-folder` mutating running scope) deferred. | spec: `2026-05-08-session-first-default-resolution.md` |
```

- [ ] **Step 2: Commit**

```bash
git add docs/futures/todo.md
git commit -m "docs(todo): close audit task 5 Phase 1 (session-first default resolution)"
```

### Task 9.3: Update `tools/wipe-esrd-home.sh` docstring (optional)

**Files:**
- Modify: `tools/wipe-esrd-home.sh`

- [ ] **Step 1: Update the SPEC reference**

In `tools/wipe-esrd-home.sh`, replace the SPEC line:

```bash
# SPEC: docs/superpowers/specs/2026-05-07-metamodel-aligned-esr.md §11
#       (post-deploy migration steps, D7 wipe procedure)
```

with:

```bash
# SPEC: docs/superpowers/specs/2026-05-07-metamodel-aligned-esr.md §11
#       (post-deploy migration steps, D7 wipe procedure)
#       and docs/superpowers/specs/2026-05-08-session-first-default-resolution.md
#       §6 (D6 — old `default` workspace must be wiped before first boot
#       of post-2026-05-08 ESR).
```

- [ ] **Step 2: Commit**

```bash
git add tools/wipe-esrd-home.sh
git commit -m "docs(wipe): reference 2026-05-08 session-first spec in wipe script docstring"
```

---

## Phase 10 — Code review + PR + merge

### Task 10.1: Final regression sweep

**Files:** none (verification).

- [ ] **Step 1: Full unit suite**

```bash
cd runtime && mix test 2>&1 | tail -3
```

Expected: failure count ≤ baseline from Phase 0 Step 2 (i.e., no new failures introduced — only pre-existing flakies).

- [ ] **Step 2: M-5 invariant grep**

```bash
grep -rn '"default"' runtime/lib/esr/resource/workspace/bootstrap.ex
```

Expected: zero matches.

```bash
grep -n 'workspace_exists?\("default"\)\|fallback.*default\|literal.*default' runtime/lib/esr/commands/scope/new.ex
```

Expected: zero matches.

- [ ] **Step 3: e2e scenario 19 from a clean wipe**

```bash
echo yes | bash tools/wipe-esrd-home.sh --dev
make e2e-19 2>&1 | tail -3
```

Expected: `PASS: 19_session_first_default`.

- [ ] **Step 4: e2e scenario 14 + 18 still green (regression)**

```bash
echo yes | bash tools/wipe-esrd-home.sh --dev
make e2e-14 2>&1 | tail -3
echo yes | bash tools/wipe-esrd-home.sh --dev
make e2e-18 2>&1 | tail -3
```

Expected: both `PASS:`.

- [ ] **Step 5: No commit (verification only)**

### Task 10.2: Subagent code-reviewer pass

**Files:** none — dispatch a subagent.

- [ ] **Step 1: Dispatch a code-reviewer subagent**

Use the Agent tool with `subagent_type: "superpowers:code-reviewer"` and `model: "opus"`. Brief prompt:

> Review the M-5 session-first default resolution PR. Spec at `docs/superpowers/specs/2026-05-08-session-first-default-resolution.md`. Branch `feat/session-first-default-resolution`. Verify:
>
> 1. No `runtime/lib/` reference to literal `"default"` as a workspace fallback (search bootstrap.ex + scope/new.ex).
> 2. Auto-create on `/user:add` is atomic — partial-failure rollback exists.
> 3. `/user:use` validates submitter via `lookup_by_feishu_id` correctly.
> 4. `Esr.Commands.Workspace.Resolve` returns `{tag, name}` consistently — no UUID leaks.
> 5. The Bootstrap rewrite is idempotent (multiple `run/0` calls do not create duplicate workspaces).
> 6. Scenario 19 actually runs against a fresh wipe and asserts on user-default name + the literal `default` is unknown.
>
> Report under 200 words; flag risks, suggest fixes inline.

- [ ] **Step 2: Address findings**

If the reviewer flags real issues, fix inline as small commits per finding. Re-run the failing tests + the e2e if anything substantive changed.

- [ ] **Step 3: Re-run full unit suite and scenario 19 after any fix**

```bash
cd runtime && mix test 2>&1 | tail -3
echo yes | bash tools/wipe-esrd-home.sh --dev
make e2e-19 2>&1 | tail -3
```

Expected: green.

### Task 10.3: Push + open PR + admin merge

**Files:** none — git/gh.

- [ ] **Step 1: Push**

```bash
git push -u origin feat/session-first-default-resolution
```

- [ ] **Step 2: Open the PR with the spec link in the body**

```bash
gh pr create --base dev --head feat/session-first-default-resolution \
  --title "feat: session-first default workspace resolution (M-5)" \
  --body "$(cat <<'EOF'
## Summary

Implements `docs/superpowers/specs/2026-05-08-session-first-default-resolution.md` — replaces the system "default" workspace fallback with a per-user default. After this PR, an operator on a fresh install can `/user:add alice` → `/session:new` → `/session:add-agent` without ever typing a workspace name.

## What changed

- **Resolver chain (Esr.Commands.Workspace.Resolve)**: explicit → chat-default → user-default → error. Single helper used by `/session:new` and `/workspace:add-folder`.
- **User.Registry**: `:default_workspace_id` field + `set/get_default_workspace/2` API. Persisted to `user.json`.
- **`/user:use workspace=<n>`**: new slash, symmetric to `/workspace:use` at user scope.
- **User.Add**: auto-creates `<username>-default` workspace + sets it as the user-default. Atomic; partial failure rolls back.
- **Workspace.Bootstrap**: no longer creates the literal `default` workspace. When `ESR_BOOTSTRAP_PRINCIPAL_ID` resolves to a known user, creates `<bootstrap_user>-default` and links it. Idempotent.
- **`/workspace:add-folder name=` becomes optional**: falls back through the same chain.
- **Audit closure**: `docs/manual-checks/2026-05-08-post-multi-instance-audit.md` step 9 marked closed.

## Test plan

- [x] Targeted: `User.Registry`, `User.Use`, `User.Add`, `Workspace.Resolve`, `Scope.New.resolve_workspace`, `Workspace.AddFolder`, `Workspace.Bootstrap` — all green.
- [x] Full suite: failure count unchanged from baseline (pre-existing flakies only).
- [x] **e2e scenario 19**: `make e2e-19` after `tools/wipe-esrd-home.sh --dev` — `PASS: 19_session_first_default`.
- [x] Regression: `make e2e-14`, `make e2e-18` still green.

## Migration

Per spec §6 / D6: existing `default` workspace state was wiped 2026-05-07. Future deployments running this code wipe their existing `default` workspace via `tools/wipe-esrd-home.sh` before first boot.

## Out of scope (separate specs)

- `/session:add-folder` mutating the running scope's workspace view.
- §5.3 stance B (user-default winning over chat-default in shared chats).
- Plugin install-by-name registry.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

- [ ] **Step 3: Admin-merge to dev**

```bash
gh pr merge --admin --squash --delete-branch
```

- [ ] **Step 4: Verify**

```bash
git fetch origin dev && git log origin/dev -1 --oneline
```

Expected: the new PR's squash commit at the top of `origin/dev`.

- [ ] **Step 5: Send Feishu summary**

Use `mcp__openclaw-channel__reply` to chat `oc_d9b47511b085e9d5b66c4595b3ef9bb9` with the merged commit hash + scenario 19 result.

---

## Self-review

Done after writing. Items checked:

- ✅ Spec coverage: D1 (§4.6), D2 (§4.6), D3 (§4.4 → Tasks 4.1-4.2), D4 (§4.5 → Tasks 5.1-5.2), D5 (§4.7 → Task 7.1), D6 (Phase 0 Step 3 + scenario 19 wipe). Spec §4.2 user.json persistence (Tasks 2.1-2.3). Spec §4.3 `/user:use` (Tasks 3.1-3.2). Spec §7 test matrix → Phase 1-7 unit tests; spec scenario 19 → Phase 8.
- ✅ Placeholder scan: no "TBD" / "implement later" / "TODO" / "similar to Task N" left. Every step shows the actual code or command.
- ✅ Type consistency: `set_default_workspace/2` arity matches across spec and tasks; `Resolve.resolve_workspace_for_args/1` signature and `{:explicit, name}` / `{:chat_default, name}` / `{:user_default, name}` / `:no_match` tags consistent across Tasks 6.1, 6.2, 7.1; `User` struct field `:default_workspace_id` consistent across Tasks 1.1, 1.2, 2.2, 4.1, 4.2; `result["default_workspace"]` / `result["default_workspace_id"]` keys consistent across Tasks 4.1, 4.2.

## Execution handoff

Plan complete and saved to `docs/superpowers/plans/2026-05-08-session-first-default-resolution-plan.md`. Two execution options:

1. **Subagent-Driven (recommended)** — I dispatch a fresh subagent per task, review between tasks, fast iteration.
2. **Inline Execution** — Execute tasks in this session using executing-plans, batch execution with checkpoints.

Which approach?
