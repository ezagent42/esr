# Metamodel-Aligned ESR Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Migrate ESR from workspace-first single-agent to session-first multi-agent surface, aligned with concepts.md metamodel.

**Architecture:** Session is first-class with UUID; chat→[sessions] (attach/detach); multi-agent per session addressed by globally-unique @<name>; per-session workspace at $ESRD_HOME/<inst>/sessions/<uuid>/; user-default-workspace at users/<user_uuid>/; 3-layer plugin config (global/user/workspace); colon-namespace slash grammar (hard cutover).

**Tech Stack:** Elixir/OTP/Phoenix; ETS-backed registries; YAML config; JSON Schema validation; UUID v4; SemVer for plugin deps.

**Spec:** `docs/superpowers/specs/2026-05-07-metamodel-aligned-esr.md` (rev-2, user-approved 2026-05-07).

**Migration order (per spec §7):** 1 → 1b → 2 → 3 → 4 → 5 → 6 → 7 → 8 → 9. Each phase ships as one PR (target branch: `dev`).

---

## File Structure

New and modified files across all 11 phases, grouped by responsibility.

### New: `Esr.Resource.Session.*` (Phase 1)

| File | Module | Phase |
|---|---|---|
| `runtime/lib/esr/resource/session/struct.ex` | `Esr.Resource.Session.Struct` | 1 |
| `runtime/lib/esr/resource/session/file_loader.ex` | `Esr.Resource.Session.FileLoader` | 1 |
| `runtime/lib/esr/resource/session/json_writer.ex` | `Esr.Resource.Session.JsonWriter` | 1 |
| `runtime/lib/esr/resource/session/registry.ex` | `Esr.Resource.Session.Registry` | 1 |
| `runtime/lib/esr/resource/session/supervisor.ex` | `Esr.Resource.Session.Supervisor` | 1 |
| `runtime/priv/schemas/session.v1.json` | JSON Schema | 1 |
| `runtime/test/esr/resource/session/struct_test.exs` | Tests | 1 |
| `runtime/test/esr/resource/session/file_loader_test.exs` | Tests | 1 |
| `runtime/test/esr/resource/session/json_writer_test.exs` | Tests | 1 |
| `runtime/test/esr/resource/session/registry_test.exs` | Tests | 1 |
| `runtime/test/esr/resource/session/json_schema_test.exs` | Tests | 1 |

### New: `Esr.Entity.User.NameIndex` + migration (Phase 1b)

| File | Module | Phase |
|---|---|---|
| `runtime/lib/esr/entity/user/name_index.ex` | `Esr.Entity.User.NameIndex` | 1b |
| `runtime/lib/esr/entity/user/migration.ex` | `Esr.Entity.User.Migration` | 1b |
| `runtime/priv/schemas/user.v1.json` | JSON Schema | 1b |
| `runtime/test/esr/entity/user/name_index_test.exs` | Tests | 1b |
| `runtime/test/esr/entity/user/migration_test.exs` | Tests | 1b |
| `runtime/test/esr/entity/user/json_schema_test.exs` | Tests | 1b |

### Modified: `Esr.Entity.User.*` (Phase 1b)

| File | Change | Phase |
|---|---|---|
| `runtime/lib/esr/entity/user/file_loader.ex` | UUID assignment + per-user dir materialization | 1b |
| `runtime/lib/esr/entity/user/registry.ex` | Add `:esr_users_by_uuid` table; `get_by_id/1`, `list_all/0` | 1b |
| `runtime/test/esr/entity/user/registry_test.exs` | Extend with UUID-keyed API tests | 1b |

### New: `Esr.Entity.Agent.Instance.*` (Phase 3)

| File | Module | Phase |
|---|---|---|
| `runtime/lib/esr/entity/agent/instance.ex` | `Esr.Entity.Agent.Instance` | 3 |
| `runtime/lib/esr/entity/agent/instance_registry.ex` | `Esr.Entity.Agent.InstanceRegistry` | 3 |
| `runtime/test/esr/entity/agent/instance_test.exs` | Tests | 3 |
| `runtime/test/esr/entity/agent/instance_registry_test.exs` | Tests | 3 |

### New: `Esr.Entity.MentionParser` (Phase 4)

| File | Module | Phase |
|---|---|---|
| `runtime/lib/esr/entity/mention_parser.ex` | `Esr.Entity.MentionParser` | 4 |
| `runtime/test/esr/entity/mention_parser_test.exs` | Tests | 4 |

### New: `Esr.Plugin.Config.*` + `Esr.Plugin.Version` (Phase 7)

| File | Module | Phase |
|---|---|---|
| `runtime/lib/esr/plugin/config.ex` | `Esr.Plugin.Config` | 7 |
| `runtime/lib/esr/plugin/version.ex` | `Esr.Plugin.Version` | 7 |
| `runtime/test/esr/plugin/config_test.exs` | Tests | 7 |
| `runtime/test/esr/plugin/version_test.exs` | Tests | 7 |

### Modified: `Esr.Resource.ChatScope.Registry` (Phase 2)

| File | Change | Phase |
|---|---|---|
| `runtime/lib/esr/resource/chat_scope/registry.ex` | chat→[sessions] attached-set shape | 2 |
| `runtime/lib/esr/resource/chat_scope/file_loader.ex` | NEW: persist + boot-load attached-set | 2 |
| `runtime/test/esr/resource/chat_scope/registry_test.exs` | Extend with multi-session API | 2 |
| `runtime/test/esr/resource/chat_scope/multi_session_test.exs` | NEW: attach/detach scenarios | 2 |

### Modified: `Esr.Resource.Capability.UuidTranslator` (Phase 5)

| File | Change | Phase |
|---|---|---|
| `runtime/lib/esr/resource/capability/uuid_translator.ex` | Add `session_uuid_to_name/2` (output only); `validate_session_cap_input/1` | 5 |
| `runtime/test/esr/resource/capability/uuid_translator_test.exs` | Extend with session UUID tests | 5 |

### Modified: `Esr.Paths` (Phase 1 + 1b)

| File | Change | Phase |
|---|---|---|
| `runtime/lib/esr/paths.ex` | Add `session_json/1`, `session_workspace_dir/1`, `users_dir/0`, `user_dir/1`, `user_json/1`, `user_workspace_json/1`, `user_plugins_yaml/1`, `workspace_plugins_yaml/1` | 1 + 1b |
| `runtime/test/esr/paths_test.exs` | Extend with new helpers | 1 + 1b |

### Modified: slash-routes (Phase 6)

| File | Change | Phase |
|---|---|---|
| `runtime/priv/slash-routes.default.yaml` | Hard cutover to colon-namespace; add session/pty/cap/plugin groups | 6 |

### Deleted: shell scripts (Phase 8)

| File | Phase |
|---|---|
| `scripts/esr-cc.sh` | 8 |
| `scripts/esr-cc.local.sh` | 8 |

### New: `Esr.Plugins.ClaudeCode.Launcher` (Phase 8)

| File | Module | Phase |
|---|---|---|
| `runtime/lib/esr/plugins/claude_code/launcher.ex` | `Esr.Plugins.ClaudeCode.Launcher` | 8 |
| `runtime/test/esr/plugins/claude_code/launcher_test.exs` | Tests | 8 |

### New: e2e scenarios (Phase 9)

| File | Phase |
|---|---|
| `tests/e2e/scenarios/14_session_multiagent.sh` | 9 |
| `tests/e2e/scenarios/15_plugin_config_layers.sh` | 9 |
| `tests/e2e/scenarios/16_session_share.sh` | 9 |

---

## Phase 1: Session UUID identity + storage layout

**PR title:** `feat: session UUID identity + storage layout (Phase 1)`
**Branch:** `feat/phase-1-session-uuid`
**Target:** `dev`
**Est LOC:** ~800
**Depends on:** Phase 0 (spec)

### Task 1.1: `Esr.Resource.Session.Struct`

**Files:**
- Create: `runtime/lib/esr/resource/session/struct.ex`
- Create: `runtime/test/esr/resource/session/struct_test.exs`

**Reference:** `runtime/lib/esr/resource/workspace/struct.ex` — read before writing test.

- [ ] **Step 1 — Write failing test.** Create `runtime/test/esr/resource/session/struct_test.exs`:

```elixir
defmodule Esr.Resource.Session.StructTest do
  use ExUnit.Case, async: true
  alias Esr.Resource.Session.Struct

  @uuid "a1b2c3d4-e5f6-4a7b-8c9d-e0f1a2b3c4d5"

  test "default struct has expected keys" do
    s = %Struct{}
    assert Map.has_key?(s, :id)
    assert Map.has_key?(s, :name)
    assert Map.has_key?(s, :owner_user)
    assert Map.has_key?(s, :workspace_id)
    assert Map.has_key?(s, :agents)
    assert Map.has_key?(s, :primary_agent)
    assert Map.has_key?(s, :attached_chats)
    assert Map.has_key?(s, :created_at)
    assert Map.has_key?(s, :transient)
  end

  test "agents defaults to empty list" do
    assert %Struct{}.agents == []
  end

  test "attached_chats defaults to empty list" do
    assert %Struct{}.attached_chats == []
  end

  test "transient defaults to false" do
    assert %Struct{}.transient == false
  end

  test "can be constructed with all fields" do
    s = %Struct{
      id: @uuid,
      name: "esr-dev",
      owner_user: "user-uuid-1",
      workspace_id: "ws-uuid-1",
      agents: [%{type: "cc", name: "esr-dev", config: %{}}],
      primary_agent: "esr-dev",
      attached_chats: [%{chat_id: "oc_x", app_id: "cli_y", attached_by: "user-uuid-1", attached_at: "2026-05-07T12:00:00Z"}],
      created_at: "2026-05-07T12:00:00Z",
      transient: true
    }
    assert s.id == @uuid
    assert s.name == "esr-dev"
    assert s.transient == true
    assert length(s.agents) == 1
  end
end
```

- [ ] **Step 2 — Run failing test.** Confirm it fails with `module Esr.Resource.Session.Struct is not available`.

```bash
cd runtime && mix test test/esr/resource/session/struct_test.exs 2>&1 | tail -10
```

- [ ] **Step 3 — Implement struct.** Create `runtime/lib/esr/resource/session/struct.ex`:

```elixir
defmodule Esr.Resource.Session.Struct do
  @moduledoc """
  In-memory representation of a session, parsed from session.json.

  Fields:
    * `id` — UUID v4, canonical identity (stable for session lifetime).
    * `name` — operator-provided display alias; unique within (owner_user, name). May change.
    * `owner_user` — user UUID of the user who created this session.
    * `workspace_id` — UUID of the workspace this session is bound to.
    * `agents` — ordered list of agent instance maps (%{type, name, config}).
      First entry is the default primary if primary_agent is not set.
    * `primary_agent` — name of the agent receiving un-addressed plain text (Q8=A).
    * `attached_chats` — list of chats with this session in their attached-set.
      Each entry: %{chat_id, app_id, attached_by, attached_at}.
    * `created_at` — ISO 8601 string; set at session creation.
    * `transient` — if true, workspace at sessions/<uuid>/ is pruned when session
      ends and the workspace is clean.
  """

  @type agent_entry :: %{
          required(:type) => String.t(),
          required(:name) => String.t(),
          required(:config) => map()
        }

  @type chat_entry :: %{
          required(:chat_id) => String.t(),
          required(:app_id) => String.t(),
          required(:attached_by) => String.t(),
          required(:attached_at) => String.t()
        }

  @type t :: %__MODULE__{
          id: String.t() | nil,
          name: String.t() | nil,
          owner_user: String.t() | nil,
          workspace_id: String.t() | nil,
          agents: [agent_entry()],
          primary_agent: String.t() | nil,
          attached_chats: [chat_entry()],
          created_at: String.t() | nil,
          transient: boolean()
        }

  defstruct [
    :id,
    :name,
    :owner_user,
    :workspace_id,
    :primary_agent,
    :created_at,
    agents: [],
    attached_chats: [],
    transient: false
  ]
end
```

- [ ] **Step 4 — Run passing test.** Confirm all 4 assertions pass.

```bash
cd runtime && mix test test/esr/resource/session/struct_test.exs 2>&1 | tail -5
```

- [ ] **Step 5 — Commit.**

```bash
cd runtime && git add lib/esr/resource/session/struct.ex test/esr/resource/session/struct_test.exs
git commit -m "feat(session): add Session.Struct with typed fields (Phase 1.1)"
```

---

### Task 1.2: JSON Schema for `session.json`

**Files:**
- Create: `runtime/priv/schemas/session.v1.json`
- Create: `runtime/test/esr/resource/session/json_schema_test.exs`

**Reference:** `runtime/priv/schemas/workspace.v1.json` — mirror structure.

- [ ] **Step 1 — Write failing test.** Create `runtime/test/esr/resource/session/json_schema_test.exs`:

```elixir
defmodule Esr.Resource.Session.JsonSchemaTest do
  use ExUnit.Case, async: true

  @uuid_v4 "a1b2c3d4-e5f6-4a7b-8c9d-e0f1a2b3c4d5"
  @owner_uuid "b2c3d4e5-f6a7-4b8c-9d0e-f1a2b3c4d5e6"

  @valid %{
    "schema_version" => 1,
    "id" => @uuid_v4,
    "name" => "esr-dev",
    "owner_user" => @owner_uuid,
    "workspace_id" => @uuid_v4,
    "agents" => [%{"type" => "cc", "name" => "esr-dev", "config" => %{}}],
    "primary_agent" => "esr-dev",
    "attached_chats" => [],
    "created_at" => "2026-05-07T12:00:00Z",
    "transient" => false
  }

  defp schema_path do
    Application.app_dir(:esr, "priv/schemas/session.v1.json")
  end

  defp validate(doc) do
    schema = schema_path() |> File.read!() |> Jason.decode!() |> ExJsonSchema.Schema.resolve()
    ExJsonSchema.Validator.validate(schema, doc)
  end

  test "schema file exists" do
    assert File.exists?(schema_path())
  end

  test "valid document passes validation" do
    assert :ok = validate(@valid)
  end

  test "missing required field id fails" do
    bad = Map.delete(@valid, "id")
    assert {:error, _} = validate(bad)
  end

  test "missing required field owner_user fails" do
    bad = Map.delete(@valid, "owner_user")
    assert {:error, _} = validate(bad)
  end

  test "invalid uuid in id fails" do
    bad = Map.put(@valid, "id", "not-a-uuid")
    assert {:error, _} = validate(bad)
  end

  test "wrong schema_version fails" do
    bad = Map.put(@valid, "schema_version", 2)
    assert {:error, _} = validate(bad)
  end

  test "transient as non-boolean fails" do
    bad = Map.put(@valid, "transient", "yes")
    assert {:error, _} = validate(bad)
  end
end
```

- [ ] **Step 2 — Run failing test.** Confirm file-exists assertion fails.

```bash
cd runtime && mix test test/esr/resource/session/json_schema_test.exs 2>&1 | tail -10
```

- [ ] **Step 3 — Implement schema.** Create `runtime/priv/schemas/session.v1.json`:

```json
{
  "$schema": "http://json-schema.org/draft-07/schema#",
  "$id": "https://esr.local/schema/session.v1.json",
  "title": "ESR session.json (v1)",
  "type": "object",
  "required": ["schema_version", "id", "name", "owner_user", "workspace_id", "agents", "primary_agent", "attached_chats", "created_at", "transient"],
  "additionalProperties": false,
  "properties": {
    "$schema": { "type": "string" },
    "schema_version": { "const": 1 },
    "id": {
      "type": "string",
      "pattern": "^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"
    },
    "name": { "type": "string", "minLength": 1 },
    "owner_user": {
      "type": "string",
      "pattern": "^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"
    },
    "workspace_id": {
      "type": "string",
      "pattern": "^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"
    },
    "agents": {
      "type": "array",
      "items": {
        "type": "object",
        "required": ["type", "name", "config"],
        "additionalProperties": false,
        "properties": {
          "type": { "type": "string", "minLength": 1 },
          "name": { "type": "string", "minLength": 1 },
          "config": { "type": "object" }
        }
      }
    },
    "primary_agent": { "type": "string" },
    "attached_chats": {
      "type": "array",
      "items": {
        "type": "object",
        "required": ["chat_id", "app_id", "attached_by", "attached_at"],
        "additionalProperties": false,
        "properties": {
          "chat_id": { "type": "string" },
          "app_id": { "type": "string" },
          "attached_by": { "type": "string" },
          "attached_at": { "type": "string" }
        }
      }
    },
    "created_at": { "type": "string" },
    "transient": { "type": "boolean", "default": false }
  }
}
```

- [ ] **Step 4 — Run passing test.** Confirm all assertions pass.

```bash
cd runtime && mix test test/esr/resource/session/json_schema_test.exs 2>&1 | tail -5
```

- [ ] **Step 5 — Commit.**

```bash
git add runtime/priv/schemas/session.v1.json runtime/test/esr/resource/session/json_schema_test.exs
git commit -m "feat(session): add session.v1.json schema + validation tests (Phase 1.2)"
```

---

### Task 1.3: `Esr.Resource.Session.FileLoader.load/2`

**Files:**
- Create: `runtime/lib/esr/resource/session/file_loader.ex`
- Create: `runtime/test/esr/resource/session/file_loader_test.exs`

**Reference:** `runtime/lib/esr/resource/workspace/file_loader.ex` — mirror validation pattern.

- [ ] **Step 1 — Write failing test.** Create `runtime/test/esr/resource/session/file_loader_test.exs`:

```elixir
defmodule Esr.Resource.Session.FileLoaderTest do
  use ExUnit.Case, async: true
  alias Esr.Resource.Session.{FileLoader, Struct}

  @uuid "a1b2c3d4-e5f6-4a7b-8c9d-e0f1a2b3c4d5"
  @owner_uuid "b2c3d4e5-f6a7-4b8c-9d0e-f1a2b3c4d5e6"
  @ws_uuid "c3d4e5f6-a7b8-4c9d-0e1f-a2b3c4d5e6f7"

  @valid %{
    "schema_version" => 1,
    "id" => @uuid,
    "name" => "esr-dev",
    "owner_user" => @owner_uuid,
    "workspace_id" => @ws_uuid,
    "agents" => [%{"type" => "cc", "name" => "esr-dev", "config" => %{}}],
    "primary_agent" => "esr-dev",
    "attached_chats" => [],
    "created_at" => "2026-05-07T12:00:00Z",
    "transient" => false
  }

  setup do
    tmp = Path.join(System.tmp_dir!(), "session_fl_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)
    %{tmp: tmp}
  end

  defp write_fixture(tmp, data) do
    path = Path.join(tmp, "session.json")
    File.write!(path, Jason.encode!(data))
    path
  end

  test "loads a valid session.json", %{tmp: tmp} do
    path = write_fixture(tmp, @valid)
    assert {:ok, %Struct{} = s} = FileLoader.load(path, [])
    assert s.id == @uuid
    assert s.name == "esr-dev"
    assert s.owner_user == @owner_uuid
    assert s.workspace_id == @ws_uuid
    assert s.agents == [%{type: "cc", name: "esr-dev", config: %{}}]
    assert s.primary_agent == "esr-dev"
    assert s.transient == false
  end

  test "returns :file_missing when file does not exist", %{tmp: tmp} do
    assert {:error, :file_missing} = FileLoader.load(Path.join(tmp, "nofile.json"), [])
  end

  test "rejects wrong schema_version", %{tmp: tmp} do
    path = write_fixture(tmp, Map.put(@valid, "schema_version", 2))
    assert {:error, {:bad_schema_version, 2}} = FileLoader.load(path, [])
  end

  test "rejects malformed UUID in id", %{tmp: tmp} do
    path = write_fixture(tmp, Map.put(@valid, "id", "not-a-uuid"))
    assert {:error, {:bad_uuid, "not-a-uuid"}} = FileLoader.load(path, [])
  end

  test "rejects empty owner_user", %{tmp: tmp} do
    path = write_fixture(tmp, Map.put(@valid, "owner_user", ""))
    assert {:error, {:missing_field, "owner_user"}} = FileLoader.load(path, [])
  end

  test "rejects missing required field name", %{tmp: tmp} do
    path = write_fixture(tmp, Map.delete(@valid, "name"))
    assert {:error, {:missing_field, "name"}} = FileLoader.load(path, [])
  end
end
```

- [ ] **Step 2 — Run failing test.** Confirm `module Esr.Resource.Session.FileLoader is not available`.

```bash
cd runtime && mix test test/esr/resource/session/file_loader_test.exs 2>&1 | tail -10
```

- [ ] **Step 3 — Implement FileLoader.** Create `runtime/lib/esr/resource/session/file_loader.ex`:

```elixir
defmodule Esr.Resource.Session.FileLoader do
  @moduledoc """
  Read a session.json file from disk and return an
  `%Esr.Resource.Session.Struct{}` or a structured error.

  Validates schema_version, UUID format for id, non-empty owner_user.
  Does not validate owner_user format against UUID regex — the registry
  does cross-reference checks at boot.
  """

  alias Esr.Resource.Session.Struct

  @uuid_re ~r/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/

  @spec load(String.t(), keyword()) :: {:ok, Struct.t()} | {:error, term()}
  def load(path, _opts) do
    with {:ok, body} <- read_file(path),
         {:ok, doc} <- decode_json(body),
         :ok <- check_schema_version(doc),
         :ok <- check_required(doc, ["id", "name", "owner_user", "workspace_id"]),
         :ok <- check_nonempty(doc, "owner_user"),
         :ok <- check_uuid(doc["id"]) do
      {:ok, build_struct(doc)}
    end
  end

  defp read_file(path) do
    case File.read(path) do
      {:ok, body} -> {:ok, body}
      {:error, :enoent} -> {:error, :file_missing}
      {:error, reason} -> {:error, {:file_read_failed, reason}}
    end
  end

  defp decode_json(body) do
    case Jason.decode(body) do
      {:ok, %{} = doc} -> {:ok, doc}
      {:ok, _} -> {:error, :json_not_object}
      {:error, _} -> {:error, :json_decode_failed}
    end
  end

  defp check_schema_version(%{"schema_version" => 1}), do: :ok
  defp check_schema_version(%{"schema_version" => v}), do: {:error, {:bad_schema_version, v}}
  defp check_schema_version(_), do: {:error, {:bad_schema_version, nil}}

  defp check_required(doc, fields) do
    case Enum.find(fields, fn f -> not Map.has_key?(doc, f) or doc[f] == nil end) do
      nil -> :ok
      missing -> {:error, {:missing_field, missing}}
    end
  end

  defp check_nonempty(doc, field) do
    case Map.get(doc, field) do
      v when is_binary(v) and v != "" -> :ok
      _ -> {:error, {:missing_field, field}}
    end
  end

  defp check_uuid(uuid) when is_binary(uuid) do
    if Regex.match?(@uuid_re, uuid), do: :ok, else: {:error, {:bad_uuid, uuid}}
  end

  defp check_uuid(other), do: {:error, {:bad_uuid, other}}

  defp build_struct(doc) do
    %Struct{
      id: doc["id"],
      name: doc["name"],
      owner_user: doc["owner_user"],
      workspace_id: doc["workspace_id"],
      agents: Enum.map(doc["agents"] || [], &normalize_agent/1),
      primary_agent: doc["primary_agent"],
      attached_chats: Enum.map(doc["attached_chats"] || [], &normalize_chat/1),
      created_at: doc["created_at"],
      transient: doc["transient"] || false
    }
  end

  defp normalize_agent(%{"type" => t, "name" => n, "config" => c}),
    do: %{type: t, name: n, config: c}

  defp normalize_agent(%{"type" => t, "name" => n}),
    do: %{type: t, name: n, config: %{}}

  defp normalize_chat(%{"chat_id" => cid, "app_id" => aid, "attached_by" => by, "attached_at" => at}),
    do: %{chat_id: cid, app_id: aid, attached_by: by, attached_at: at}
end
```

- [ ] **Step 4 — Run passing test.** Confirm all assertions pass.

```bash
cd runtime && mix test test/esr/resource/session/file_loader_test.exs 2>&1 | tail -5
```

- [ ] **Step 5 — Commit.**

```bash
git add runtime/lib/esr/resource/session/file_loader.ex runtime/test/esr/resource/session/file_loader_test.exs
git commit -m "feat(session): add Session.FileLoader load/2 with schema + UUID validation (Phase 1.3)"
```

---

### Task 1.4: `Esr.Resource.Session.JsonWriter.write/2`

**Files:**
- Create: `runtime/lib/esr/resource/session/json_writer.ex`
- Create: `runtime/test/esr/resource/session/json_writer_test.exs`

**Reference:** `runtime/lib/esr/resource/workspace/json_writer.ex` — atomic tmp + rename pattern.

- [ ] **Step 1 — Write failing test.** Create `runtime/test/esr/resource/session/json_writer_test.exs`:

```elixir
defmodule Esr.Resource.Session.JsonWriterTest do
  use ExUnit.Case, async: true
  alias Esr.Resource.Session.{JsonWriter, FileLoader, Struct}

  @uuid "a1b2c3d4-e5f6-4a7b-8c9d-e0f1a2b3c4d5"
  @owner_uuid "b2c3d4e5-f6a7-4b8c-9d0e-f1a2b3c4d5e6"
  @ws_uuid "c3d4e5f6-a7b8-4c9d-0e1f-a2b3c4d5e6f7"

  setup do
    tmp = Path.join(System.tmp_dir!(), "session_jw_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)
    %{tmp: tmp}
  end

  defp sample_struct do
    %Struct{
      id: @uuid,
      name: "esr-dev",
      owner_user: @owner_uuid,
      workspace_id: @ws_uuid,
      agents: [%{type: "cc", name: "esr-dev", config: %{}}],
      primary_agent: "esr-dev",
      attached_chats: [],
      created_at: "2026-05-07T12:00:00Z",
      transient: false
    }
  end

  test "writes session.json and produces valid JSON", %{tmp: tmp} do
    path = Path.join(tmp, "session.json")
    assert :ok = JsonWriter.write(path, sample_struct())
    assert File.exists?(path)
    assert {:ok, _decoded} = Jason.decode(File.read!(path))
  end

  test "no .tmp file remains after successful write", %{tmp: tmp} do
    path = Path.join(tmp, "session.json")
    JsonWriter.write(path, sample_struct())
    refute File.exists?(path <> ".tmp")
  end

  test "creates parent directories as needed", %{tmp: tmp} do
    path = Path.join([tmp, "deep", "nested", "session.json"])
    assert :ok = JsonWriter.write(path, sample_struct())
    assert File.exists?(path)
  end

  test "round-trip: write then load returns equal struct", %{tmp: tmp} do
    path = Path.join(tmp, "session.json")
    original = sample_struct()
    JsonWriter.write(path, original)
    assert {:ok, loaded} = FileLoader.load(path, [])
    assert loaded.id == original.id
    assert loaded.name == original.name
    assert loaded.owner_user == original.owner_user
    assert loaded.workspace_id == original.workspace_id
    assert loaded.primary_agent == original.primary_agent
    assert loaded.transient == original.transient
  end
end
```

- [ ] **Step 2 — Run failing test.** Confirm `module Esr.Resource.Session.JsonWriter is not available`.

```bash
cd runtime && mix test test/esr/resource/session/json_writer_test.exs 2>&1 | tail -10
```

- [ ] **Step 3 — Implement JsonWriter.** Create `runtime/lib/esr/resource/session/json_writer.ex`:

```elixir
defmodule Esr.Resource.Session.JsonWriter do
  @moduledoc """
  Atomic write of a `Session.Struct` to a `session.json` file.

  Uses `*.tmp` → rename to avoid torn state on crash. Creates parent
  directories as needed.
  """

  alias Esr.Resource.Session.Struct

  @spec write(String.t(), Struct.t()) :: :ok | {:error, term()}
  def write(path, %Struct{} = session) do
    with :ok <- File.mkdir_p(Path.dirname(path)),
         {:ok, json} <- encode(session),
         tmp = path <> ".tmp",
         :ok <- File.write(tmp, json),
         :ok <- File.rename(tmp, path) do
      :ok
    end
  end

  defp encode(s) do
    map = %{
      "schema_version" => 1,
      "id" => s.id,
      "name" => s.name,
      "owner_user" => s.owner_user,
      "workspace_id" => s.workspace_id,
      "agents" => Enum.map(s.agents, &serialise_agent/1),
      "primary_agent" => s.primary_agent,
      "attached_chats" => Enum.map(s.attached_chats, &serialise_chat/1),
      "created_at" => s.created_at,
      "transient" => s.transient
    }

    Jason.encode(map, pretty: true)
  end

  defp serialise_agent(%{type: t, name: n, config: c}),
    do: %{"type" => t, "name" => n, "config" => c}

  defp serialise_chat(%{chat_id: cid, app_id: aid, attached_by: by, attached_at: at}),
    do: %{"chat_id" => cid, "app_id" => aid, "attached_by" => by, "attached_at" => at}
end
```

- [ ] **Step 4 — Run passing test.** Confirm all assertions pass.

```bash
cd runtime && mix test test/esr/resource/session/json_writer_test.exs 2>&1 | tail -5
```

- [ ] **Step 5 — Commit.**

```bash
git add runtime/lib/esr/resource/session/json_writer.ex runtime/test/esr/resource/session/json_writer_test.exs
git commit -m "feat(session): add Session.JsonWriter atomic write + round-trip test (Phase 1.4)"
```

---

### Task 1.5: `Esr.Paths` extensions

**Files:**
- Modify: `runtime/lib/esr/paths.ex`
- Modify: `runtime/test/esr/paths_test.exs`

**Read before modifying:** `runtime/lib/esr/paths.ex` — `session_dir/1` already exists; add only missing helpers.

- [ ] **Step 1 — Write failing tests.** Append to `runtime/test/esr/paths_test.exs` (inside the module, after existing tests):

```elixir
  # Phase 1.5 additions

  test "session_json/1 builds correct path" do
    uuid = "a1b2c3d4-e5f6-4a7b-8c9d-e0f1a2b3c4d5"
    assert Esr.Paths.session_json(uuid) ==
             "/tmp/pth-test/default/sessions/#{uuid}/session.json"
  end

  test "session_workspace_dir/1 builds .esr dir path" do
    uuid = "a1b2c3d4-e5f6-4a7b-8c9d-e0f1a2b3c4d5"
    assert Esr.Paths.session_workspace_dir(uuid) ==
             "/tmp/pth-test/default/sessions/#{uuid}/.esr"
  end

  test "sessions_dir/0 already exists (verify it's consistent)" do
    assert Esr.Paths.sessions_dir() == "/tmp/pth-test/default/sessions"
  end
```

- [ ] **Step 2 — Run failing tests.** Confirm `session_json/1` and `session_workspace_dir/1` are undefined.

```bash
cd runtime && mix test test/esr/paths_test.exs 2>&1 | tail -10
```

- [ ] **Step 3 — Add helpers to `Esr.Paths`.** In `runtime/lib/esr/paths.ex`, append after the existing `session_dir/1` helper:

```elixir
  @doc "Path to session.json inside a session state dir."
  def session_json(uuid) when is_binary(uuid),
    do: Path.join(session_dir(uuid), "session.json")

  @doc "Path to .esr/ config overlay dir inside a session state dir."
  def session_workspace_dir(uuid) when is_binary(uuid),
    do: Path.join(session_dir(uuid), ".esr")

  @doc "Path to session.v1.json schema shipped in priv."
  def session_schema_v1, do: Application.app_dir(:esr, "priv/schemas/session.v1.json")
```

- [ ] **Step 4 — Run passing tests.** Confirm all paths tests pass.

```bash
cd runtime && mix test test/esr/paths_test.exs 2>&1 | tail -5
```

- [ ] **Step 5 — Commit.**

```bash
git add runtime/lib/esr/paths.ex runtime/test/esr/paths_test.exs
git commit -m "feat(paths): add session_json/1, session_workspace_dir/1, session_schema_v1/0 (Phase 1.5)"
```

---

### Task 1.6: `Esr.Resource.Session.Registry` boot + ETS skeleton

**Files:**
- Create: `runtime/lib/esr/resource/session/registry.ex`
- Create: `runtime/test/esr/resource/session/registry_test.exs`

**Reference:** `runtime/lib/esr/resource/workspace/registry.ex` — two-ETS-table pattern, `scan_*` boot, `NameIndex`.

- [ ] **Step 1 — Write failing test.** Create `runtime/test/esr/resource/session/registry_test.exs`:

```elixir
defmodule Esr.Resource.Session.RegistryTest do
  use ExUnit.Case, async: false
  alias Esr.Resource.Session.{Registry, Struct}

  @uuid "a1b2c3d4-e5f6-4a7b-8c9d-e0f1a2b3c4d5"
  @owner_uuid "b2c3d4e5-f6a7-4b8c-9d0e-f1a2b3c4d5e6"
  @ws_uuid "c3d4e5f6-a7b8-4c9d-0e1f-a2b3c4d5e6f7"

  setup do
    tmp = Path.join(System.tmp_dir!(), "sreg_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(tmp)
    System.put_env("ESRD_HOME", tmp)
    System.put_env("ESR_INSTANCE", "default")
    File.mkdir_p!(Path.join([tmp, "default", "sessions"]))

    on_exit(fn ->
      System.delete_env("ESRD_HOME")
      System.delete_env("ESR_INSTANCE")
      File.rm_rf!(tmp)
    end)

    unless Process.whereis(Registry), do: Registry.start_link([])
    Registry.reload()
    %{tmp: tmp}
  end

  defp write_session(tmp, uuid, name, owner_uuid) do
    dir = Path.join([tmp, "default", "sessions", uuid])
    File.mkdir_p!(dir)
    data = %{
      "schema_version" => 1,
      "id" => uuid,
      "name" => name,
      "owner_user" => owner_uuid,
      "workspace_id" => @ws_uuid,
      "agents" => [],
      "primary_agent" => nil,
      "attached_chats" => [],
      "created_at" => "2026-05-07T12:00:00Z",
      "transient" => false
    }
    File.write!(Path.join(dir, "session.json"), Jason.encode!(data))
    dir
  end

  test "starts empty", _ctx do
    assert Registry.list_all() == []
  end

  test "get_by_id returns :not_found for unknown", _ctx do
    assert :not_found = Registry.get_by_id("00000000-0000-4000-8000-000000000000")
  end

  test "reload discovers sessions on disk", %{tmp: tmp} do
    write_session(tmp, @uuid, "esr-dev", @owner_uuid)
    Registry.reload()
    assert {:ok, %Struct{id: @uuid, name: "esr-dev"}} = Registry.get_by_id(@uuid)
  end

  test "list_all returns all loaded sessions", %{tmp: tmp} do
    uuid2 = "b2c3d4e5-f6a7-4b8c-9d0e-f1a2b3c4d5e6"
    write_session(tmp, @uuid, "esr-dev", @owner_uuid)
    write_session(tmp, uuid2, "docs", @owner_uuid)
    Registry.reload()
    ids = Registry.list_all() |> Enum.map(& &1.id) |> Enum.sort()
    assert ids == Enum.sort([@uuid, uuid2])
  end

  test "get_by_id returns correct struct after reload", %{tmp: tmp} do
    write_session(tmp, @uuid, "my-session", @owner_uuid)
    Registry.reload()
    assert {:ok, sess} = Registry.get_by_id(@uuid)
    assert sess.name == "my-session"
    assert sess.owner_user == @owner_uuid
  end
end
```

- [ ] **Step 2 — Run failing test.** Confirm `module Esr.Resource.Session.Registry is not available`.

```bash
cd runtime && mix test test/esr/resource/session/registry_test.exs 2>&1 | tail -10
```

- [ ] **Step 3 — Implement Registry.** Create `runtime/lib/esr/resource/session/registry.ex`:

```elixir
defmodule Esr.Resource.Session.Registry do
  @moduledoc """
  In-memory registry of all sessions, rebuilt from disk at boot.

  ETS layout:
    * `:esr_sessions_by_uuid` — UUID-keyed: `{uuid, %Struct{}}`.
    * `:esr_session_name_index` — composite-keyed: `{{owner_user_uuid, name}, uuid}`.
      Composite key per spec D6: session names unique within (owner_user, name), not globally.

  Public API (Phase 1 — read-side + reload):
    * `start_link/1`, `reload/0`
    * `get_by_id/1` — returns `{:ok, Struct.t()} | :not_found`
    * `list_all/0` — returns `[Struct.t()]`

  Mutation API (put/1, delete_by_id/1) added in Phase 2 when session
  create/end commands ship.
  """

  @behaviour Esr.Role.State
  use GenServer
  require Logger

  alias Esr.Paths
  alias Esr.Resource.Session.{Struct, FileLoader}

  @uuid_table :esr_sessions_by_uuid
  @name_index :esr_session_name_index

  ## Public API -----------------------------------------------------------

  def start_link(opts \\ []),
    do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @spec reload() :: :ok | {:error, term()}
  def reload, do: GenServer.call(__MODULE__, :reload)

  @spec get_by_id(String.t()) :: {:ok, Struct.t()} | :not_found
  def get_by_id(uuid) when is_binary(uuid) do
    case :ets.lookup(@uuid_table, uuid) do
      [{^uuid, s}] -> {:ok, s}
      [] -> :not_found
    end
  rescue
    ArgumentError -> :not_found
  end

  @spec list_all() :: [Struct.t()]
  def list_all do
    @uuid_table
    |> :ets.tab2list()
    |> Enum.map(fn {_id, s} -> s end)
  rescue
    ArgumentError -> []
  end

  ## GenServer callbacks ---------------------------------------------------

  @impl GenServer
  def init(_opts) do
    ensure_tables()

    case do_reload() do
      :ok ->
        {:ok, %{}}

      {:error, reason} ->
        Logger.warning("session.registry: boot reload failed (#{inspect(reason)}); starting empty")
        {:ok, %{}}
    end
  end

  @impl GenServer
  def handle_call(:reload, _from, state) do
    {:reply, do_reload(), state}
  end

  ## Internals -------------------------------------------------------------

  defp ensure_tables do
    if :ets.info(@uuid_table) == :undefined do
      :ets.new(@uuid_table, [:named_table, :set, :public, read_concurrency: true])
    end

    if :ets.info(@name_index) == :undefined do
      :ets.new(@name_index, [:named_table, :set, :public, read_concurrency: true])
    end
  end

  defp do_reload do
    :ets.delete_all_objects(@uuid_table)
    :ets.delete_all_objects(@name_index)

    sessions = scan_sessions_dir()

    Enum.each(sessions, fn s ->
      :ets.insert(@uuid_table, {s.id, s})
      :ets.insert(@name_index, {{s.owner_user, s.name}, s.id})
    end)

    :ok
  end

  defp scan_sessions_dir do
    base = Paths.sessions_dir()

    if File.exists?(base) do
      base
      |> File.ls!()
      |> Enum.flat_map(fn entry ->
        path = Path.join([base, entry, "session.json"])

        case FileLoader.load(path, []) do
          {:ok, s} ->
            [s]

          {:error, :file_missing} ->
            []

          {:error, reason} ->
            Logger.warning("session.registry: skipping #{path} (#{inspect(reason)})")
            []
        end
      end)
    else
      []
    end
  end
end
```

- [ ] **Step 4 — Run passing test.** Confirm all 5 assertions pass.

```bash
cd runtime && mix test test/esr/resource/session/registry_test.exs 2>&1 | tail -5
```

- [ ] **Step 5 — Commit.**

```bash
git add runtime/lib/esr/resource/session/registry.ex runtime/test/esr/resource/session/registry_test.exs
git commit -m "feat(session): add Session.Registry ETS skeleton + disk scan boot (Phase 1.6)"
```

---

### Phase 1 PR checklist

Before opening the PR:

- [ ] Run full test suite: `cd runtime && mix test 2>&1 | tail -20`
- [ ] Confirm no compilation warnings for new modules: `mix compile 2>&1 | grep -i warning`
- [ ] Add `Esr.Resource.Session.Supervisor` to `Esr.Application` child list (before `ChatScope.Registry`). The supervisor wraps `Registry.start_link/1`. If a `session/supervisor.ex` stub is not created yet, inline the child spec directly in `application.ex`.

```
git commit -m "feat: session UUID identity + storage layout (Phase 1)"
```

---

## Phase 1b: User UUID identity + NameIndex + user.json migration

**PR title:** `feat: user UUID identity + NameIndex + user.json migration (Phase 1b)`
**Branch:** `feat/phase-1b-user-uuid`
**Target:** `dev`
**Est LOC:** ~600
**Depends on:** Phase 1 (Paths conventions)

### Task 1b.1: `Esr.Entity.User.NameIndex`

**Files:**
- Create: `runtime/lib/esr/entity/user/name_index.ex`
- Create: `runtime/test/esr/entity/user/name_index_test.exs`

**Reference:** `runtime/lib/esr/resource/workspace/name_index.ex` — bidirectional ETS pattern. Mirror it exactly, changing `workspace` → `user` and `name_index` → `user_name_index`.

- [ ] **Step 1 — Write failing test.** Create `runtime/test/esr/entity/user/name_index_test.exs`:

```elixir
defmodule Esr.Entity.User.NameIndexTest do
  use ExUnit.Case, async: true
  alias Esr.Entity.User.NameIndex

  @table :esr_user_name_index_test

  setup do
    {:ok, _pid} = NameIndex.start_link(table: @table)
    :ok
  end

  test "put and id_for_name" do
    assert :ok = NameIndex.put(@table, "linyilun", "uuid-001")
    assert {:ok, "uuid-001"} = NameIndex.id_for_name(@table, "linyilun")
  end

  test "name_for_id returns name" do
    NameIndex.put(@table, "alice", "uuid-002")
    assert {:ok, "alice"} = NameIndex.name_for_id(@table, "uuid-002")
  end

  test "id_for_name returns :not_found for unknown" do
    assert :not_found = NameIndex.id_for_name(@table, "nobody")
  end

  test "name_for_id returns :not_found for unknown" do
    assert :not_found = NameIndex.name_for_id(@table, "uuid-999")
  end

  test "put rejects duplicate name" do
    NameIndex.put(@table, "bob", "uuid-003")
    assert {:error, :name_exists} = NameIndex.put(@table, "bob", "uuid-004")
  end

  test "put rejects duplicate id" do
    NameIndex.put(@table, "carol", "uuid-005")
    assert {:error, :id_exists} = NameIndex.put(@table, "dave", "uuid-005")
  end

  test "rename updates both directions" do
    NameIndex.put(@table, "eve", "uuid-006")
    assert :ok = NameIndex.rename(@table, "eve", "eva")
    assert {:ok, "uuid-006"} = NameIndex.id_for_name(@table, "eva")
    assert :not_found = NameIndex.id_for_name(@table, "eve")
  end

  test "rename returns :not_found for unknown name" do
    assert {:error, :not_found} = NameIndex.rename(@table, "ghost", "new-name")
  end

  test "rename returns :name_exists if new name taken" do
    NameIndex.put(@table, "frank", "uuid-007")
    NameIndex.put(@table, "grace", "uuid-008")
    assert {:error, :name_exists} = NameIndex.rename(@table, "frank", "grace")
  end

  test "delete_by_id removes both directions" do
    NameIndex.put(@table, "hal", "uuid-009")
    assert :ok = NameIndex.delete_by_id(@table, "uuid-009")
    assert :not_found = NameIndex.id_for_name(@table, "hal")
    assert :not_found = NameIndex.name_for_id(@table, "uuid-009")
  end

  test "all returns all name→id pairs" do
    NameIndex.put(@table, "ivan", "uuid-010")
    NameIndex.put(@table, "judy", "uuid-011")
    pairs = NameIndex.all(@table) |> Enum.sort()
    assert {"ivan", "uuid-010"} in pairs
    assert {"judy", "uuid-011"} in pairs
  end
end
```

- [ ] **Step 2 — Run failing test.** Confirm `module Esr.Entity.User.NameIndex is not available`.

```bash
cd runtime && mix test test/esr/entity/user/name_index_test.exs 2>&1 | tail -10
```

- [ ] **Step 3 — Implement NameIndex.** Create `runtime/lib/esr/entity/user/name_index.ex`:

```elixir
defmodule Esr.Entity.User.NameIndex do
  @moduledoc """
  Bidirectional username↔UUID index for users, backed by two ETS tables.

  Two tables:
    * `:esr_user_name_to_id` — `{username, uuid}`
    * `:esr_user_id_to_name` — `{uuid, username}`

  Mirrors `Esr.Resource.Workspace.NameIndex` exactly, scoped to users.
  Owned by `Esr.Entity.User.Registry` GenServer; ETS table is configurable
  for test isolation.
  """

  use GenServer

  @default_table :esr_user_name_index

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts,
      name: name_for(Keyword.get(opts, :table, @default_table))
    )
  end

  defp name_for(table), do: :"#{__MODULE__}.#{table}"

  @impl true
  def init(opts) do
    table = Keyword.get(opts, :table, @default_table)
    name_to_id = :ets.new(:"#{table}_name_to_id", [:named_table, :set, :public, read_concurrency: true])
    id_to_name = :ets.new(:"#{table}_id_to_name", [:named_table, :set, :public, read_concurrency: true])
    {:ok, %{table: table, name_to_id: name_to_id, id_to_name: id_to_name}}
  end

  @spec put(atom(), String.t(), String.t()) :: :ok | {:error, :name_exists | :id_exists}
  def put(table \\ @default_table, name, id) do
    name_to_id = :"#{table}_name_to_id"
    id_to_name = :"#{table}_id_to_name"

    cond do
      :ets.lookup(name_to_id, name) != [] -> {:error, :name_exists}
      :ets.lookup(id_to_name, id) != [] -> {:error, :id_exists}
      true ->
        :ets.insert(name_to_id, {name, id})
        :ets.insert(id_to_name, {id, name})
        :ok
    end
  end

  @spec id_for_name(atom(), String.t()) :: {:ok, String.t()} | :not_found
  def id_for_name(table \\ @default_table, name) do
    case :ets.lookup(:"#{table}_name_to_id", name) do
      [{^name, id}] -> {:ok, id}
      [] -> :not_found
    end
  end

  @spec name_for_id(atom(), String.t()) :: {:ok, String.t()} | :not_found
  def name_for_id(table \\ @default_table, id) do
    case :ets.lookup(:"#{table}_id_to_name", id) do
      [{^id, name}] -> {:ok, name}
      [] -> :not_found
    end
  end

  @spec rename(atom(), String.t(), String.t()) :: :ok | {:error, :not_found | :name_exists}
  def rename(table \\ @default_table, old_name, new_name) do
    name_to_id = :"#{table}_name_to_id"
    id_to_name = :"#{table}_id_to_name"

    case :ets.lookup(name_to_id, old_name) do
      [] ->
        {:error, :not_found}

      [{^old_name, id}] ->
        if :ets.lookup(name_to_id, new_name) != [] do
          {:error, :name_exists}
        else
          :ets.delete(name_to_id, old_name)
          :ets.insert(name_to_id, {new_name, id})
          :ets.insert(id_to_name, {id, new_name})
          :ok
        end
    end
  end

  @spec delete_by_id(atom(), String.t()) :: :ok
  def delete_by_id(table \\ @default_table, id) do
    id_to_name = :"#{table}_id_to_name"
    name_to_id = :"#{table}_name_to_id"

    case :ets.lookup(id_to_name, id) do
      [{^id, name}] ->
        :ets.delete(id_to_name, id)
        :ets.delete(name_to_id, name)
        :ok

      [] ->
        :ok
    end
  end

  @spec all(atom()) :: [{String.t(), String.t()}]
  def all(table \\ @default_table) do
    :ets.tab2list(:"#{table}_name_to_id")
  end
end
```

- [ ] **Step 4 — Run passing test.** Confirm all 11 assertions pass.

```bash
cd runtime && mix test test/esr/entity/user/name_index_test.exs 2>&1 | tail -5
```

- [ ] **Step 5 — Commit.**

```bash
git add runtime/lib/esr/entity/user/name_index.ex runtime/test/esr/entity/user/name_index_test.exs
git commit -m "feat(user): add User.NameIndex bidirectional ETS username/UUID index (Phase 1b.1)"
```

---

### Task 1b.2: JSON Schema for `user.json`

**Files:**
- Create: `runtime/priv/schemas/user.v1.json`
- Create: `runtime/test/esr/entity/user/json_schema_test.exs`

**Reference:** `runtime/priv/schemas/workspace.v1.json` — mirror structure.

- [ ] **Step 1 — Write failing test.** Create `runtime/test/esr/entity/user/json_schema_test.exs`:

```elixir
defmodule Esr.Entity.User.JsonSchemaTest do
  use ExUnit.Case, async: true

  @uuid "a1b2c3d4-e5f6-4a7b-8c9d-e0f1a2b3c4d5"

  @valid %{
    "schema_version" => 1,
    "id" => @uuid,
    "username" => "linyilun",
    "display_name" => "林懿伦",
    "created_at" => "2026-05-07T12:00:00Z"
  }

  defp schema_path do
    Application.app_dir(:esr, "priv/schemas/user.v1.json")
  end

  defp validate(doc) do
    schema = schema_path() |> File.read!() |> Jason.decode!() |> ExJsonSchema.Schema.resolve()
    ExJsonSchema.Validator.validate(schema, doc)
  end

  test "schema file exists" do
    assert File.exists?(schema_path())
  end

  test "valid document passes" do
    assert :ok = validate(@valid)
  end

  test "missing id fails" do
    assert {:error, _} = validate(Map.delete(@valid, "id"))
  end

  test "missing username fails" do
    assert {:error, _} = validate(Map.delete(@valid, "username"))
  end

  test "invalid UUID in id fails" do
    assert {:error, _} = validate(Map.put(@valid, "id", "bad"))
  end

  test "empty username fails" do
    assert {:error, _} = validate(Map.put(@valid, "username", ""))
  end

  test "wrong schema_version fails" do
    assert {:error, _} = validate(Map.put(@valid, "schema_version", 2))
  end

  test "display_name is optional — minimal valid doc" do
    minimal = Map.take(@valid, ["schema_version", "id", "username"])
    assert :ok = validate(minimal)
  end
end
```

- [ ] **Step 2 — Run failing test.** Confirm file-exists assertion fails.

```bash
cd runtime && mix test test/esr/entity/user/json_schema_test.exs 2>&1 | tail -10
```

- [ ] **Step 3 — Implement schema.** Create `runtime/priv/schemas/user.v1.json`:

```json
{
  "$schema": "http://json-schema.org/draft-07/schema#",
  "$id": "https://esr.local/schema/user.v1.json",
  "title": "ESR user.json (v1)",
  "type": "object",
  "required": ["schema_version", "id", "username"],
  "additionalProperties": false,
  "properties": {
    "$schema": { "type": "string" },
    "schema_version": { "const": 1 },
    "id": {
      "type": "string",
      "pattern": "^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"
    },
    "username": { "type": "string", "minLength": 1 },
    "display_name": { "type": "string" },
    "created_at": { "type": "string" }
  }
}
```

- [ ] **Step 4 — Run passing test.** Confirm all assertions pass.

```bash
cd runtime && mix test test/esr/entity/user/json_schema_test.exs 2>&1 | tail -5
```

- [ ] **Step 5 — Commit.**

```bash
git add runtime/priv/schemas/user.v1.json runtime/test/esr/entity/user/json_schema_test.exs
git commit -m "feat(user): add user.v1.json schema + validation tests (Phase 1b.2)"
```

---

### Task 1b.3: User boot migration (`users.yaml` → `users/<uuid>/user.json`)

**Files:**
- Modify: `runtime/lib/esr/entity/user/file_loader.ex`
- Create: `runtime/lib/esr/entity/user/migration.ex`
- Create: `runtime/test/esr/entity/user/migration_test.exs`

**Read before modifying:** `runtime/lib/esr/entity/user/file_loader.ex` — understand existing YAML parse logic before adding migration call.

- [ ] **Step 1 — Write failing test.** Create `runtime/test/esr/entity/user/migration_test.exs`:

```elixir
defmodule Esr.Entity.User.MigrationTest do
  use ExUnit.Case, async: true
  alias Esr.Entity.User.Migration

  setup do
    tmp = Path.join(System.tmp_dir!(), "user_mig_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(tmp)
    System.put_env("ESRD_HOME", tmp)
    System.put_env("ESR_INSTANCE", "default")
    inst_dir = Path.join([tmp, "default"])
    File.mkdir_p!(inst_dir)
    on_exit(fn ->
      System.delete_env("ESRD_HOME")
      System.delete_env("ESR_INSTANCE")
      File.rm_rf!(tmp)
    end)
    %{tmp: tmp, inst_dir: inst_dir}
  end

  defp write_users_yaml(inst_dir, content) do
    File.write!(Path.join(inst_dir, "users.yaml"), content)
  end

  test "no-op when users.yaml does not exist", %{inst_dir: inst_dir} do
    assert :ok = Migration.run(inst_dir)
    refute File.exists?(Path.join(inst_dir, "users"))
  end

  test "creates users/<uuid>/user.json for each entry", %{inst_dir: inst_dir} do
    write_users_yaml(inst_dir, """
    users:
      linyilun:
        feishu_ids:
          - ou_aaabbbccc
    """)

    assert :ok = Migration.run(inst_dir)

    users_dir = Path.join(inst_dir, "users")
    assert File.exists?(users_dir)
    uuids = File.ls!(users_dir)
    assert length(uuids) == 1
    [uuid] = uuids
    user_json_path = Path.join([users_dir, uuid, "user.json"])
    assert File.exists?(user_json_path)
    {:ok, doc} = Jason.decode(File.read!(user_json_path))
    assert doc["username"] == "linyilun"
    assert doc["id"] == uuid
    assert doc["schema_version"] == 1
  end

  test "creates .esr/workspace.json stub for each user", %{inst_dir: inst_dir} do
    write_users_yaml(inst_dir, """
    users:
      alice:
        feishu_ids: []
    """)

    Migration.run(inst_dir)
    users_dir = Path.join(inst_dir, "users")
    [uuid] = File.ls!(users_dir)
    ws_json = Path.join([users_dir, uuid, ".esr", "workspace.json"])
    assert File.exists?(ws_json)
    {:ok, doc} = Jason.decode(File.read!(ws_json))
    assert doc["kind"] == "user-default"
    assert doc["owner"] == uuid
    assert doc["schema_version"] == 1
  end

  test "renames users.yaml to users.yaml.migrated-<timestamp>", %{inst_dir: inst_dir} do
    write_users_yaml(inst_dir, "users:\n  bob:\n    feishu_ids: []\n")
    Migration.run(inst_dir)
    refute File.exists?(Path.join(inst_dir, "users.yaml"))
    migrated = Path.join(inst_dir, "users") |> Path.dirname()
    backups = Path.join(inst_dir, "users.yaml.migrated-*") |> Path.wildcard()
    assert length(backups) == 1
  end

  test "idempotent: running twice does not duplicate entries", %{inst_dir: inst_dir} do
    write_users_yaml(inst_dir, "users:\n  carol:\n    feishu_ids: []\n")
    Migration.run(inst_dir)
    # users.yaml was renamed; second run is a no-op
    assert :ok = Migration.run(inst_dir)
    users_dir = Path.join(inst_dir, "users")
    assert length(File.ls!(users_dir)) == 1
  end
end
```

- [ ] **Step 2 — Run failing test.** Confirm `module Esr.Entity.User.Migration is not available`.

```bash
cd runtime && mix test test/esr/entity/user/migration_test.exs 2>&1 | tail -10
```

- [ ] **Step 3 — Implement Migration.** Create `runtime/lib/esr/entity/user/migration.ex`:

```elixir
defmodule Esr.Entity.User.Migration do
  @moduledoc """
  Boot migration: `users.yaml` → per-user `users/<uuid>/user.json` + `.esr/workspace.json`.

  Called once at boot by `Esr.Entity.User.FileLoader.load/1` when
  `users.yaml` exists and the `users/` directory is absent or empty.

  Behavior:
  1. Parse `users.yaml` (existing format: `users: { <username>: { feishu_ids: [...] } }`).
  2. For each user entry: assign UUID v4, write `users/<uuid>/user.json`,
     write `users/<uuid>/.esr/workspace.json` (user-default workspace stub).
  3. Atomically rename `users.yaml` → `users.yaml.migrated-<unix_timestamp>`.

  Idempotent: if `users.yaml` is absent (already renamed), returns `:ok` immediately.
  Non-destructive: rename preserves the original YAML as a backup.
  """

  require Logger

  @spec run(String.t()) :: :ok | {:error, term()}
  def run(inst_dir) do
    yaml_path = Path.join(inst_dir, "users.yaml")

    if File.exists?(yaml_path) do
      do_migrate(inst_dir, yaml_path)
    else
      :ok
    end
  end

  defp do_migrate(inst_dir, yaml_path) do
    with {:ok, yaml} <- YamlElixir.read_from_file(yaml_path),
         {:ok, users} <- extract_users(yaml) do
      Enum.each(users, fn {username, row} ->
        uuid = UUID.uuid4()
        feishu_ids = (is_map(row) && row["feishu_ids"]) || []
        write_user_json(inst_dir, uuid, username, feishu_ids)
        write_workspace_stub(inst_dir, uuid, username)
      end)

      ts = System.system_time(:second)
      backup = yaml_path <> ".migrated-#{ts}"
      File.rename!(yaml_path, backup)
      Logger.info("user.migration: migrated #{length(users)} users; backup at #{backup}")
      :ok
    end
  end

  defp extract_users(%{"users" => users}) when is_map(users), do: {:ok, Map.to_list(users)}
  defp extract_users(_), do: {:ok, []}

  defp write_user_json(inst_dir, uuid, username, _feishu_ids) do
    dir = Path.join([inst_dir, "users", uuid])
    File.mkdir_p!(dir)
    path = Path.join(dir, "user.json")

    doc = %{
      "schema_version" => 1,
      "id" => uuid,
      "username" => username,
      "display_name" => "",
      "created_at" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    tmp = path <> ".tmp"
    File.write!(tmp, Jason.encode!(doc, pretty: true))
    File.rename!(tmp, path)
  end

  defp write_workspace_stub(inst_dir, uuid, username) do
    esr_dir = Path.join([inst_dir, "users", uuid, ".esr"])
    File.mkdir_p!(esr_dir)
    path = Path.join(esr_dir, "workspace.json")

    unless File.exists?(path) do
      ws_uuid = UUID.uuid4()
      doc = %{
        "schema_version" => 1,
        "id" => ws_uuid,
        "name" => username,
        "owner" => uuid,
        "kind" => "user-default",
        "folders" => [],
        "chats" => [],
        "transient" => false,
        "created_at" => DateTime.utc_now() |> DateTime.to_iso8601()
      }

      tmp = path <> ".tmp"
      File.write!(tmp, Jason.encode!(doc, pretty: true))
      File.rename!(tmp, path)
    end
  end
end
```

- [ ] **Step 4 — Run passing test.** Confirm all 5 assertions pass.

```bash
cd runtime && mix test test/esr/entity/user/migration_test.exs 2>&1 | tail -5
```

- [ ] **Step 5 — Commit.**

```bash
git add runtime/lib/esr/entity/user/migration.ex runtime/test/esr/entity/user/migration_test.exs
git commit -m "feat(user): add User.Migration users.yaml → per-uuid dirs (Phase 1b.3)"
```

---

### Task 1b.4: `Esr.Entity.User.Registry` UUID-keyed extension

**Files:**
- Modify: `runtime/lib/esr/entity/user/registry.ex`
- Modify: `runtime/test/esr/entity/user/registry_test.exs` (extend)

**Read before modifying:** `runtime/lib/esr/entity/user/registry.ex` — understand existing `@by_name` + `@by_feishu_id` tables and `load_snapshot/1` call.

- [ ] **Step 1 — Write failing tests.** Append to `runtime/test/esr/entity/user/registry_test.exs` (confirm the test file exists first; if absent, create with full module):

```elixir
  # Phase 1b.4 additions

  describe "UUID-keyed API" do
    setup do
      snapshot = %{
        "linyilun" => %Esr.Entity.User.Registry.User{username: "linyilun", feishu_ids: ["ou_aaa"]},
        "alice" => %Esr.Entity.User.Registry.User{username: "alice", feishu_ids: []}
      }
      uuids = %{"linyilun" => "uuid-lyl-001", "alice" => "uuid-alice-002"}
      Esr.Entity.User.Registry.load_snapshot_with_uuids(snapshot, uuids)
      :ok
    end

    test "get_by_id returns the user struct" do
      assert {:ok, user} = Esr.Entity.User.Registry.get_by_id("uuid-lyl-001")
      assert user.username == "linyilun"
    end

    test "get_by_id returns :not_found for unknown uuid" do
      assert :not_found = Esr.Entity.User.Registry.get_by_id("00000000-0000-4000-8000-000000000000")
    end

    test "list_all returns all users" do
      all = Esr.Entity.User.Registry.list_all()
      usernames = Enum.map(all, fn {_uuid, u} -> u.username end) |> Enum.sort()
      assert usernames == ["alice", "linyilun"]
    end

    test "existing lookup_by_name still works after UUID load" do
      assert {:ok, user} = Esr.Entity.User.Registry.get("linyilun")
      assert user.username == "linyilun"
    end
  end
```

- [ ] **Step 2 — Run failing test.** Confirm `load_snapshot_with_uuids/2` is undefined.

```bash
cd runtime && mix test test/esr/entity/user/registry_test.exs 2>&1 | tail -10
```

- [ ] **Step 3 — Extend Registry.** In `runtime/lib/esr/entity/user/registry.ex`, add:
  - `@by_uuid :esr_users_by_uuid` module attribute
  - ETS table creation in `init/1` (alongside existing tables)
  - `load_snapshot_with_uuids/2` public function (GenServer call)
  - `get_by_id/1` public function (direct ETS read)
  - `list_all/0` public function (direct ETS read)
  - `handle_call({:load_with_uuids, ...})` handler that populates both old tables AND new `@by_uuid` table

The existing `load_snapshot/1` path is left unchanged for backward compat. The new `load_snapshot_with_uuids/2` adds the UUID table on top.

- [ ] **Step 4 — Run passing test.** Confirm all new assertions pass and existing registry tests still pass.

```bash
cd runtime && mix test test/esr/entity/user/registry_test.exs 2>&1 | tail -5
```

- [ ] **Step 5 — Commit.**

```bash
git add runtime/lib/esr/entity/user/registry.ex runtime/test/esr/entity/user/registry_test.exs
git commit -m "feat(user): extend User.Registry with UUID-keyed ETS table + get_by_id/1 (Phase 1b.4)"
```

---

### Task 1b.5: `Esr.Paths` user helpers + user-default-workspace materialization

**Files:**
- Modify: `runtime/lib/esr/paths.ex`
- Modify: `runtime/test/esr/paths_test.exs`

**Note:** The user-default-workspace materialization (`users/<uuid>/.esr/workspace.json`) is already handled by `Migration.write_workspace_stub/3` in Task 1b.3. This task adds the Paths helpers and verifies `Workspace.Registry` boot sweeps pick up `kind: "user-default"` workspaces (they do via the ESR-bound scan — no changes needed to `Workspace.Registry` itself; it already calls `scan_esr_bound/0` which will find the `.esr/workspace.json` if pointed at the users dir).

- [ ] **Step 1 — Write failing tests.** Append to `runtime/test/esr/paths_test.exs` (inside the module):

```elixir
  # Phase 1b.5 additions

  test "users_dir/0 builds correct path" do
    assert Esr.Paths.users_dir() == "/tmp/pth-test/default/users"
  end

  test "user_dir/1 builds correct path" do
    uuid = "a1b2c3d4-e5f6-4a7b-8c9d-e0f1a2b3c4d5"
    assert Esr.Paths.user_dir(uuid) ==
             "/tmp/pth-test/default/users/#{uuid}"
  end

  test "user_json/1 builds correct path" do
    uuid = "a1b2c3d4-e5f6-4a7b-8c9d-e0f1a2b3c4d5"
    assert Esr.Paths.user_json(uuid) ==
             "/tmp/pth-test/default/users/#{uuid}/user.json"
  end

  test "user_workspace_json/1 builds correct path" do
    uuid = "a1b2c3d4-e5f6-4a7b-8c9d-e0f1a2b3c4d5"
    assert Esr.Paths.user_workspace_json(uuid) ==
             "/tmp/pth-test/default/users/#{uuid}/.esr/workspace.json"
  end

  test "user_plugins_yaml/1 builds correct path" do
    uuid = "a1b2c3d4-e5f6-4a7b-8c9d-e0f1a2b3c4d5"
    assert Esr.Paths.user_plugins_yaml(uuid) ==
             "/tmp/pth-test/default/users/#{uuid}/.esr/plugins.yaml"
  end

  test "workspace_plugins_yaml/1 builds correct path" do
    assert Esr.Paths.workspace_plugins_yaml("/tmp/myrepo") ==
             "/tmp/myrepo/.esr/plugins.yaml"
  end
```

- [ ] **Step 2 — Run failing tests.** Confirm `users_dir/0` and user helpers are undefined.

```bash
cd runtime && mix test test/esr/paths_test.exs 2>&1 | tail -10
```

- [ ] **Step 3 — Add helpers to `Esr.Paths`.** Append after the existing `workspace_schema_v1/0` helper:

```elixir
  @doc "Top-level dir for user-default workspaces. Per-instance."
  def users_dir, do: Path.join(runtime_home(), "users")

  @doc "Per-user dir. Keyed by user UUID (not username)."
  def user_dir(user_uuid) when is_binary(user_uuid),
    do: Path.join(users_dir(), user_uuid)

  @doc "Path to user.json for the given user UUID."
  def user_json(user_uuid) when is_binary(user_uuid),
    do: Path.join(user_dir(user_uuid), "user.json")

  @doc "Path to workspace.json for the user-default workspace."
  def user_workspace_json(user_uuid) when is_binary(user_uuid),
    do: Path.join([user_dir(user_uuid), ".esr", "workspace.json"])

  @doc "Path to user-layer plugins.yaml."
  def user_plugins_yaml(user_uuid) when is_binary(user_uuid),
    do: Path.join([user_dir(user_uuid), ".esr", "plugins.yaml"])

  @doc "Path to workspace-layer plugins.yaml inside a workspace root dir."
  def workspace_plugins_yaml(workspace_root) when is_binary(workspace_root),
    do: Path.join([workspace_root, ".esr", "plugins.yaml"])

  @doc "Path to user.v1.json schema shipped in priv."
  def user_schema_v1, do: Application.app_dir(:esr, "priv/schemas/user.v1.json")
```

- [ ] **Step 4 — Run passing tests.** Confirm all paths tests pass.

```bash
cd runtime && mix test test/esr/paths_test.exs 2>&1 | tail -5
```

- [ ] **Step 5 — Commit.**

```bash
git add runtime/lib/esr/paths.ex runtime/test/esr/paths_test.exs
git commit -m "feat(paths): add user_dir/1, user_json/1, user_workspace_json/1, user_plugins_yaml/1, workspace_plugins_yaml/1 (Phase 1b.5)"
```

---

### Phase 1b PR checklist

Before opening the PR:

- [ ] Integrate `Migration.run/1` call into `Esr.Entity.User.FileLoader.load/1`: at the top, call `Migration.run(inst_dir)` where `inst_dir = Esr.Paths.runtime_home()`, before the existing YAML parse block. The migration is a no-op if `users.yaml` is absent.
- [ ] Run full test suite: `cd runtime && mix test 2>&1 | tail -20`
- [ ] Confirm no compilation warnings: `mix compile 2>&1 | grep -i warning`
- [ ] Start `Esr.Entity.User.NameIndex` under `Esr.Entity.User.Supervisor`. Add `{NameIndex, []}` as a child before the `FileLoader` call in supervisor.

```
git commit -m "feat: user UUID identity + NameIndex + user.json migration (Phase 1b)"
```

---

## Phase 2: ChatScope.Registry — chat→[sessions] + attach/detach state

**PR title:** `feat: chat→[sessions] attach/detach state (Phase 2)`
**Branch:** `feat/phase-2-chat-attach-detach`
**Target:** `dev`
**Est LOC:** ~600
**Depends on:** Phase 1b

### Task 2.1: ChatScope state shape rewrite

**Files:**
- Modify: `runtime/lib/esr/resource/chat_scope/registry.ex`
- Modify: `runtime/test/esr/resource/chat_scope/registry_test.exs` (extend)

**Read before modifying:** `runtime/lib/esr/resource/chat_scope/registry.ex` — understand existing ETS table `@ets_table`, `register_session/3`, `lookup_by_chat/2`, and the `{_k, sid, refs}` tuple format.

- [ ] **Step 1 — Write failing tests.** Append to `runtime/test/esr/resource/chat_scope/registry_test.exs`:

```elixir
  # Phase 2.1 — multi-session attach/detach API

  describe "attach_session/3" do
    test "attaches a session and sets it as current" do
      chat_id = "oc_attach_test"
      app_id = "cli_app"
      uuid = "a1b2c3d4-e5f6-4a7b-8c9d-e0f1a2b3c4d5"

      assert :ok = ChatScope.Registry.attach_session(chat_id, app_id, uuid)
      assert {:ok, ^uuid} = ChatScope.Registry.current_session(chat_id, app_id)
      assert [^uuid] = ChatScope.Registry.attached_sessions(chat_id, app_id)
    end

    test "attaching a second session adds it but keeps first as current" do
      chat_id = "oc_multi_test"
      app_id = "cli_app"
      uuid1 = "a1b2c3d4-e5f6-4a7b-8c9d-e0f1a2b3c4d5"
      uuid2 = "b2c3d4e5-f6a7-4b8c-9d0e-f1a2b3c4d5e6"

      ChatScope.Registry.attach_session(chat_id, app_id, uuid1)
      ChatScope.Registry.attach_session(chat_id, app_id, uuid2)

      sessions = ChatScope.Registry.attached_sessions(chat_id, app_id) |> Enum.sort()
      assert Enum.sort([uuid1, uuid2]) == sessions
    end

    test "re-attaching already-attached session is idempotent" do
      chat_id = "oc_idem_test"
      app_id = "cli_app"
      uuid = "c3d4e5f6-a7b8-4c9d-0e1f-a2b3c4d5e6f7"

      ChatScope.Registry.attach_session(chat_id, app_id, uuid)
      ChatScope.Registry.attach_session(chat_id, app_id, uuid)

      assert [^uuid] = ChatScope.Registry.attached_sessions(chat_id, app_id)
    end
  end

  describe "detach_session/3" do
    test "detach removes session from attached set" do
      chat_id = "oc_detach1"
      app_id = "cli_app"
      uuid1 = "d4e5f6a7-b8c9-4d0e-1f2a-b3c4d5e6f7a8"
      uuid2 = "e5f6a7b8-c9d0-4e1f-2a3b-c4d5e6f7a8b9"

      ChatScope.Registry.attach_session(chat_id, app_id, uuid1)
      ChatScope.Registry.attach_session(chat_id, app_id, uuid2)

      assert :ok = ChatScope.Registry.detach_session(chat_id, app_id, uuid1)
      assert ChatScope.Registry.attached_sessions(chat_id, app_id) == [uuid2]
    end

    test "detaching current session promotes next as current" do
      chat_id = "oc_detach2"
      app_id = "cli_app"
      uuid1 = "f6a7b8c9-d0e1-4f2a-3b4c-d5e6f7a8b9c0"
      uuid2 = "a7b8c9d0-e1f2-4a3b-4c5d-e6f7a8b9c0d1"

      ChatScope.Registry.attach_session(chat_id, app_id, uuid1)
      ChatScope.Registry.attach_session(chat_id, app_id, uuid2)
      # uuid1 is current (first attached)
      assert {:ok, ^uuid1} = ChatScope.Registry.current_session(chat_id, app_id)

      ChatScope.Registry.detach_session(chat_id, app_id, uuid1)

      # uuid2 becomes current
      assert {:ok, _remaining} = ChatScope.Registry.current_session(chat_id, app_id)
      assert ChatScope.Registry.attached_sessions(chat_id, app_id) == [uuid2]
    end

    test "detaching last session leaves current as nil" do
      chat_id = "oc_detach3"
      app_id = "cli_app"
      uuid = "b8c9d0e1-f2a3-4b4c-5d6e-f7a8b9c0d1e2"

      ChatScope.Registry.attach_session(chat_id, app_id, uuid)
      ChatScope.Registry.detach_session(chat_id, app_id, uuid)

      assert :not_found = ChatScope.Registry.current_session(chat_id, app_id)
      assert [] = ChatScope.Registry.attached_sessions(chat_id, app_id)
    end
  end
```

- [ ] **Step 2 — Run failing tests.** Confirm `attach_session/3`, `detach_session/3`, `current_session/2`, `attached_sessions/2` are undefined.

```bash
cd runtime && mix test test/esr/resource/chat_scope/registry_test.exs 2>&1 | tail -15
```

- [ ] **Step 3 — Rewrite ChatScope state shape.** In `runtime/lib/esr/resource/chat_scope/registry.ex`:

  Replace the `@ets_table` entry format from `{key, sid, refs}` (old 1:1 model) to `{key, %{current: sid | nil, attached: MapSet.t()}}`. Add the following new public API functions above the existing `register_session/3`:

```elixir
  @doc "Attach a session to this chat. Adds to attached set. If first attach, sets as current."
  @spec attach_session(String.t(), String.t(), String.t()) :: :ok
  def attach_session(chat_id, app_id, session_uuid)
      when is_binary(chat_id) and is_binary(app_id) and is_binary(session_uuid) do
    GenServer.call(__MODULE__, {:attach_session, chat_id, app_id, session_uuid})
  end

  @doc "Detach a session from this chat. If it was current, promote the next remaining or nil."
  @spec detach_session(String.t(), String.t(), String.t()) :: :ok
  def detach_session(chat_id, app_id, session_uuid)
      when is_binary(chat_id) and is_binary(app_id) and is_binary(session_uuid) do
    GenServer.call(__MODULE__, {:detach_session, chat_id, app_id, session_uuid})
  end

  @doc "Return the current (attached-current) session UUID for this chat, or :not_found."
  @spec current_session(String.t(), String.t()) :: {:ok, String.t()} | :not_found
  def current_session(chat_id, app_id) do
    case :ets.lookup(@ets_table, {chat_id, app_id}) do
      [{_, %{current: nil}}] -> :not_found
      [{_, %{current: sid}}] when is_binary(sid) -> {:ok, sid}
      [] -> :not_found
    end
  rescue
    ArgumentError -> :not_found
  end

  @doc "Return the list of attached session UUIDs for this chat (order undefined)."
  @spec attached_sessions(String.t(), String.t()) :: [String.t()]
  def attached_sessions(chat_id, app_id) do
    case :ets.lookup(@ets_table, {chat_id, app_id}) do
      [{_, %{attached: set}}] -> MapSet.to_list(set)
      [] -> []
    end
  rescue
    ArgumentError -> []
  end
```

  Add `handle_call` clauses for `:attach_session` and `:detach_session`:

```elixir
  def handle_call({:attach_session, chat_id, app_id, uuid}, _from, state) do
    key = {chat_id, app_id}
    slot = case :ets.lookup(@ets_table, key) do
      [{_, s}] -> s
      [] -> %{current: nil, attached: MapSet.new()}
    end

    new_attached = MapSet.put(slot.attached, uuid)
    new_current = slot.current || uuid
    :ets.insert(@ets_table, {key, %{current: new_current, attached: new_attached}})
    {:reply, :ok, state}
  end

  def handle_call({:detach_session, chat_id, app_id, uuid}, _from, state) do
    key = {chat_id, app_id}
    case :ets.lookup(@ets_table, key) do
      [{_, slot}] ->
        new_attached = MapSet.delete(slot.attached, uuid)
        new_current =
          cond do
            slot.current != uuid -> slot.current
            MapSet.size(new_attached) == 0 -> nil
            true -> MapSet.to_list(new_attached) |> List.first()
          end

        :ets.insert(@ets_table, {key, %{current: new_current, attached: new_attached}})

      [] ->
        :ok
    end

    {:reply, :ok, state}
  end
```

- [ ] **Step 4 — Run passing tests.** Confirm new attach/detach tests pass.

```bash
cd runtime && mix test test/esr/resource/chat_scope/registry_test.exs 2>&1 | tail -5
```

- [ ] **Step 5 — Commit.**

```bash
git add runtime/lib/esr/resource/chat_scope/registry.ex runtime/test/esr/resource/chat_scope/registry_test.exs
git commit -m "feat(chat_scope): add attach_session/3, detach_session/3, current_session/2, attached_sessions/2 (Phase 2.1)"
```

---

### Task 2.2: `lookup_by_chat/2` migration shim

**Files:**
- Modify: `runtime/lib/esr/resource/chat_scope/registry.ex`
- Modify: `runtime/test/esr/resource/chat_scope/registry_test.exs` (extend)

- [ ] **Step 1 — Write failing test.** Append to registry_test:

```elixir
  describe "lookup_by_chat/2 shim (backward compat)" do
    test "returns current session in old {sid, refs} form after attach" do
      chat_id = "oc_shim_test"
      app_id = "cli_app"
      uuid = "c9d0e1f2-a3b4-4c5d-6e7f-a8b9c0d1e2f3"

      ChatScope.Registry.attach_session(chat_id, app_id, uuid)

      assert {:ok, ^uuid, _refs} = ChatScope.Registry.lookup_by_chat(chat_id, app_id)
    end

    test "returns :not_found when no session is attached" do
      assert :not_found = ChatScope.Registry.lookup_by_chat("oc_empty", "cli_app")
    end
  end
```

- [ ] **Step 2 — Run failing test.** Confirm `lookup_by_chat` returns unexpected format.

```bash
cd runtime && mix test test/esr/resource/chat_scope/registry_test.exs 2>&1 | grep -E "shim|FAILED|error" | head -10
```

- [ ] **Step 3 — Update `lookup_by_chat/2` to proxy through new shape.** Replace the existing `lookup_by_chat/2` implementation in `registry.ex`:

```elixir
  def lookup_by_chat(chat_id, app_id) do
    case :ets.lookup(@ets_table, {chat_id, app_id}) do
      [{_, %{current: nil}}] -> :not_found
      [{_, %{current: sid}}] when is_binary(sid) -> {:ok, sid, %{}}
      [{_, sid, refs}] when is_binary(sid) -> {:ok, sid, refs}  # old format compat
      [] -> :not_found
    end
  rescue
    ArgumentError -> :not_found
  end
```

- [ ] **Step 4 — Run passing tests.** Confirm shim tests + all prior registry tests pass.

```bash
cd runtime && mix test test/esr/resource/chat_scope/registry_test.exs 2>&1 | tail -5
```

- [ ] **Step 5 — Commit.**

```bash
git add runtime/lib/esr/resource/chat_scope/registry.ex runtime/test/esr/resource/chat_scope/registry_test.exs
git commit -m "feat(chat_scope): update lookup_by_chat/2 shim for new attached-set shape (Phase 2.2)"
```

---

### Task 2.3: Multi-session attach/detach test suite

**Files:**
- Create: `runtime/test/esr/resource/chat_scope/multi_session_test.exs`

- [ ] **Step 1 — Write tests.** Create `runtime/test/esr/resource/chat_scope/multi_session_test.exs`:

```elixir
defmodule Esr.Resource.ChatScope.MultiSessionTest do
  use ExUnit.Case, async: false
  alias Esr.Resource.ChatScope.Registry, as: ChatScope

  @chat "oc_multi_full"
  @app "cli_test"
  @uuid1 "aaaaaaaa-0001-4000-8000-000000000001"
  @uuid2 "aaaaaaaa-0002-4000-8000-000000000002"
  @uuid3 "aaaaaaaa-0003-4000-8000-000000000003"

  setup do
    unless Process.whereis(ChatScope), do: ChatScope.start_link([])
    # Clean slate for this chat key
    ChatScope.detach_session(@chat, @app, @uuid1)
    ChatScope.detach_session(@chat, @app, @uuid2)
    ChatScope.detach_session(@chat, @app, @uuid3)
    :ok
  end

  test "attach 2 sessions: both in attached, first attached = current" do
    ChatScope.attach_session(@chat, @app, @uuid1)
    ChatScope.attach_session(@chat, @app, @uuid2)

    sessions = ChatScope.attached_sessions(@chat, @app) |> Enum.sort()
    assert sessions == Enum.sort([@uuid1, @uuid2])
    assert {:ok, @uuid1} = ChatScope.current_session(@chat, @app)
  end

  test "detach current: next remaining becomes current" do
    ChatScope.attach_session(@chat, @app, @uuid1)
    ChatScope.attach_session(@chat, @app, @uuid2)
    ChatScope.detach_session(@chat, @app, @uuid1)

    assert {:ok, @uuid2} = ChatScope.current_session(@chat, @app)
    assert ChatScope.attached_sessions(@chat, @app) == [@uuid2]
  end

  test "detach non-current: current unchanged" do
    ChatScope.attach_session(@chat, @app, @uuid1)
    ChatScope.attach_session(@chat, @app, @uuid2)
    assert {:ok, @uuid1} = ChatScope.current_session(@chat, @app)

    ChatScope.detach_session(@chat, @app, @uuid2)

    assert {:ok, @uuid1} = ChatScope.current_session(@chat, @app)
    assert ChatScope.attached_sessions(@chat, @app) == [@uuid1]
  end

  test "re-attach already-attached: idempotent (no duplicates)" do
    ChatScope.attach_session(@chat, @app, @uuid1)
    ChatScope.attach_session(@chat, @app, @uuid1)

    assert length(ChatScope.attached_sessions(@chat, @app)) == 1
  end

  test "list sessions: returns all attached" do
    ChatScope.attach_session(@chat, @app, @uuid1)
    ChatScope.attach_session(@chat, @app, @uuid2)
    ChatScope.attach_session(@chat, @app, @uuid3)

    result = ChatScope.attached_sessions(@chat, @app) |> Enum.sort()
    assert result == Enum.sort([@uuid1, @uuid2, @uuid3])
  end

  test "detach all: empty list + :not_found current" do
    ChatScope.attach_session(@chat, @app, @uuid1)
    ChatScope.detach_session(@chat, @app, @uuid1)

    assert [] = ChatScope.attached_sessions(@chat, @app)
    assert :not_found = ChatScope.current_session(@chat, @app)
  end
end
```

- [ ] **Step 2 — Run tests.** Confirm all 6 pass with no setup needed (implementation from Task 2.1 already in place).

```bash
cd runtime && mix test test/esr/resource/chat_scope/multi_session_test.exs 2>&1 | tail -10
```

- [ ] **Step 3 — If any tests fail:** Diagnose the attach/detach implementation from Task 2.1 and fix. Do not modify the test file to match wrong behavior.

- [ ] **Step 4 — Run full registry test suite:** Confirm all registry tests pass.

```bash
cd runtime && mix test test/esr/resource/chat_scope/ 2>&1 | tail -5
```

- [ ] **Step 5 — Commit.**

```bash
git add runtime/test/esr/resource/chat_scope/multi_session_test.exs
git commit -m "test(chat_scope): multi-session attach/detach invariant suite (Phase 2.3)"
```

---

### Task 2.4: Persistent attached-set across restart

**Files:**
- Create: `runtime/lib/esr/resource/chat_scope/file_loader.ex`
- Modify: `runtime/lib/esr/resource/chat_scope/registry.ex` (init + write hooks)
- Modify: `runtime/test/esr/resource/chat_scope/registry_test.exs` (extend)

- [ ] **Step 1 — Write failing test.** Append to `registry_test.exs`:

```elixir
  describe "persistence across restart" do
    setup do
      tmp = Path.join(System.tmp_dir!(), "cs_persist_#{:rand.uniform(1_000_000)}")
      File.mkdir_p!(tmp)
      System.put_env("ESRD_HOME", tmp)
      System.put_env("ESR_INSTANCE", "default")
      File.mkdir_p!(Path.join([tmp, "default"]))

      on_exit(fn ->
        System.delete_env("ESRD_HOME")
        System.delete_env("ESR_INSTANCE")
        File.rm_rf!(tmp)
      end)

      %{tmp: tmp}
    end

    test "attached set is written to disk on attach", %{tmp: tmp} do
      unless Process.whereis(ChatScope.Registry), do: ChatScope.Registry.start_link([])
      ChatScope.Registry.reload()

      uuid = "f0e1d2c3-b4a5-4967-8b12-a3b4c5d6e7f8"
      ChatScope.Registry.attach_session("oc_persist", "cli_p", uuid)

      persist_path = Path.join([tmp, "default", "chat_attached.yaml"])
      assert File.exists?(persist_path)
    end

    test "boot loads persisted attached set", %{tmp: tmp} do
      unless Process.whereis(ChatScope.Registry), do: ChatScope.Registry.start_link([])

      uuid = "a0b1c2d3-e4f5-4678-9a0b-c1d2e3f4a5b6"
      persist_path = Path.join([tmp, "default", "chat_attached.yaml"])

      # Pre-write a fixture
      File.write!(persist_path, """
      chat_attached:
        - chat_id: "oc_boot"
          app_id: "cli_b"
          sessions:
            - "#{uuid}"
          current: "#{uuid}"
      """)

      ChatScope.Registry.reload()

      assert {:ok, ^uuid} = ChatScope.Registry.current_session("oc_boot", "cli_b")
    end
  end
```

- [ ] **Step 2 — Run failing test.** Confirm persistence-related assertions fail.

```bash
cd runtime && mix test test/esr/resource/chat_scope/registry_test.exs 2>&1 | grep -E "persistence|FAILED" | head -10
```

- [ ] **Step 3 — Implement FileLoader.** Create `runtime/lib/esr/resource/chat_scope/file_loader.ex`:

```elixir
defmodule Esr.Resource.ChatScope.FileLoader do
  @moduledoc """
  Persist and load the `(chat_id, app_id)` → attached-set mapping.

  File: `$ESRD_HOME/<inst>/chat_attached.yaml`
  Format:
    chat_attached:
      - chat_id: "oc_xxx"
        app_id: "cli_yyy"
        sessions: ["uuid1", "uuid2"]
        current: "uuid1"

  Atomic write: tmp → rename. Read is non-destructive.
  """

  @spec load(String.t()) :: {:ok, [map()]} | {:error, term()}
  def load(path) do
    if File.exists?(path) do
      with {:ok, yaml} <- YamlElixir.read_from_file(path) do
        entries = (yaml["chat_attached"] || [])
          |> Enum.map(fn e ->
            %{
              chat_id: e["chat_id"],
              app_id: e["app_id"],
              sessions: e["sessions"] || [],
              current: e["current"]
            }
          end)
        {:ok, entries}
      end
    else
      {:ok, []}
    end
  end

  @spec write(String.t(), [map()]) :: :ok | {:error, term()}
  def write(path, entries) do
    serialised = Enum.map(entries, fn e ->
      %{
        "chat_id" => e.chat_id,
        "app_id" => e.app_id,
        "sessions" => e.sessions,
        "current" => e.current
      }
    end)

    yaml_str = Ymlr.document!(%{"chat_attached" => serialised})
    tmp = path <> ".tmp"

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(tmp, yaml_str),
         :ok <- File.rename(tmp, path) do
      :ok
    end
  end
end
```

- [ ] **Step 4 — Wire persistence into Registry.** In `runtime/lib/esr/resource/chat_scope/registry.ex`:

  - In `init/1`: call `Esr.Resource.ChatScope.FileLoader.load/1` on the persist path; populate `@ets_table` with loaded entries.
  - Add `reload/0` public API (GenServer call: clears and reloads from disk).
  - After `attach_session` and `detach_session` `handle_call` handlers: write updated state to disk via `FileLoader.write/2`.

  Helper to get persist path: `Path.join(Esr.Paths.runtime_home(), "chat_attached.yaml")`.

- [ ] **Step 5 — Run passing test.** Confirm persistence tests pass.

```bash
cd runtime && mix test test/esr/resource/chat_scope/registry_test.exs 2>&1 | tail -5
```

- [ ] **Step 6 — Commit.**

```bash
git add runtime/lib/esr/resource/chat_scope/file_loader.ex runtime/lib/esr/resource/chat_scope/registry.ex runtime/test/esr/resource/chat_scope/registry_test.exs
git commit -m "feat(chat_scope): persist attached-set to chat_attached.yaml + boot reload (Phase 2.4)"
```

---

### Phase 2 PR checklist

Before opening the PR:

- [ ] Run full test suite: `cd runtime && mix test 2>&1 | tail -20`
- [ ] Confirm existing callers of `register_session/3` still compile (deprecated but not removed): `mix compile 2>&1 | grep -i error`
- [ ] Verify `lookup_by_chat/2` returns the correct format to all callers by scanning: `grep -r "lookup_by_chat" runtime/lib/ | grep -v registry.ex`

```
git commit -m "feat: chat→[sessions] attach/detach state (Phase 2)"
```

---

<!-- PLAN_END_PHASE_2 — next subagent: append "## Phase 3" here -->
