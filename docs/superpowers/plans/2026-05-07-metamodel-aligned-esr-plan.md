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

## Phase 3: Multi-agent per session — instance model + name uniqueness

**PR title:** `feat: multi-agent per session — instance model + name uniqueness (Phase 3)`
**Branch:** `feat/phase-3-multi-agent`
**Target:** `dev`
**Est LOC:** ~700
**Depends on:** Phase 2

**Goal:** Every session can host multiple named agent instances. Names must be globally unique within a session regardless of type. `Session.Registry` persists the agents list to `session.json`. Slash commands (`/session:add-agent`, `/session:remove-agent`, `/session:set-primary`) are implemented as pure command modules here; their slash-routes entries land in Phase 6.

---

### Task 3.1: `Esr.Entity.Agent.Instance` struct + JSON schema

**Files:**
- Create: `runtime/lib/esr/entity/agent/instance.ex`
- Create: `runtime/priv/schemas/agent_instance.v1.json`
- Create: `runtime/test/esr/entity/agent/instance_test.exs`
- Create: `runtime/test/esr/entity/agent/instance_schema_test.exs`

**Reference:** `runtime/lib/esr/resource/session/struct.ex` — mirror the struct + `@type t` pattern.

- [ ] **Step 1 — Write failing test.** Create `runtime/test/esr/entity/agent/instance_test.exs`:

```elixir
defmodule Esr.Entity.Agent.InstanceTest do
  use ExUnit.Case, async: true
  alias Esr.Entity.Agent.Instance

  @session_uuid "a1b2c3d4-e5f6-4a7b-8c9d-e0f1a2b3c4d5"

  test "default struct has expected keys" do
    i = %Instance{}
    assert Map.has_key?(i, :id)
    assert Map.has_key?(i, :session_id)
    assert Map.has_key?(i, :type)
    assert Map.has_key?(i, :name)
    assert Map.has_key?(i, :config)
    assert Map.has_key?(i, :created_at)
  end

  test "config defaults to empty map" do
    assert %Instance{}.config == %{}
  end

  test "can be constructed with all fields" do
    i = %Instance{
      id: "b2c3d4e5-f6a7-4b8c-9d0e-f1a2b3c4d5e6",
      session_id: @session_uuid,
      type: "cc",
      name: "esr-dev",
      config: %{"model" => "claude-opus-4"},
      created_at: "2026-05-07T12:00:00Z"
    }
    assert i.type == "cc"
    assert i.name == "esr-dev"
    assert i.config == %{"model" => "claude-opus-4"}
  end

  test "name accepts dash-separated strings" do
    i = %Instance{name: "my-agent-1"}
    assert i.name == "my-agent-1"
  end
end
```

Create `runtime/test/esr/entity/agent/instance_schema_test.exs`:

```elixir
defmodule Esr.Entity.Agent.InstanceSchemaTest do
  use ExUnit.Case, async: true

  @session_uuid "a1b2c3d4-e5f6-4a7b-8c9d-e0f1a2b3c4d5"
  @instance_uuid "b2c3d4e5-f6a7-4b8c-9d0e-f1a2b3c4d5e6"

  @valid %{
    "schema_version" => 1,
    "id" => @instance_uuid,
    "session_id" => @session_uuid,
    "type" => "cc",
    "name" => "esr-dev",
    "config" => %{},
    "created_at" => "2026-05-07T12:00:00Z"
  }

  defp schema_path do
    Application.app_dir(:esr, "priv/schemas/agent_instance.v1.json")
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

  test "missing required field type fails" do
    bad = Map.delete(@valid, "type")
    assert {:error, _} = validate(bad)
  end

  test "missing required field name fails" do
    bad = Map.delete(@valid, "name")
    assert {:error, _} = validate(bad)
  end

  test "missing required field session_id fails" do
    bad = Map.delete(@valid, "session_id")
    assert {:error, _} = validate(bad)
  end

  test "wrong schema_version fails" do
    bad = Map.put(@valid, "schema_version", 2)
    assert {:error, _} = validate(bad)
  end

  test "empty type string fails" do
    bad = Map.put(@valid, "type", "")
    assert {:error, _} = validate(bad)
  end

  test "empty name string fails" do
    bad = Map.put(@valid, "name", "")
    assert {:error, _} = validate(bad)
  end
end
```

- [ ] **Step 2 — Run failing tests.** Confirm `module Esr.Entity.Agent.Instance is not available`.

```bash
cd runtime && mix test test/esr/entity/agent/instance_test.exs test/esr/entity/agent/instance_schema_test.exs 2>&1 | tail -10
```

- [ ] **Step 3 — Implement struct.** Create `runtime/lib/esr/entity/agent/instance.ex`:

```elixir
defmodule Esr.Entity.Agent.Instance do
  @moduledoc """
  An agent instance within a session.

  Fields:
    * `id` — UUID v4, stable identity for this instance.
    * `session_id` — UUID of the owning session.
    * `type` — agent type string declared in a plugin manifest (e.g. `"cc"`).
    * `name` — operator-chosen display name; globally unique within the session
      regardless of type (spec §3, Q7=B).
    * `config` — plugin-specific configuration map (validated against plugin's
      `config_schema:` in Phase 7).
    * `created_at` — ISO 8601 string, set at creation.
  """

  @type t :: %__MODULE__{
          id: String.t() | nil,
          session_id: String.t() | nil,
          type: String.t() | nil,
          name: String.t() | nil,
          config: map(),
          created_at: String.t() | nil
        }

  defstruct [
    :id,
    :session_id,
    :type,
    :name,
    :created_at,
    config: %{}
  ]
end
```

Create `runtime/priv/schemas/agent_instance.v1.json`:

```json
{
  "$schema": "http://json-schema.org/draft-07/schema#",
  "$id": "https://esr.local/schema/agent_instance.v1.json",
  "title": "ESR agent instance (v1)",
  "type": "object",
  "required": ["schema_version", "id", "session_id", "type", "name", "config", "created_at"],
  "additionalProperties": false,
  "properties": {
    "$schema": { "type": "string" },
    "schema_version": { "const": 1 },
    "id": {
      "type": "string",
      "pattern": "^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"
    },
    "session_id": {
      "type": "string",
      "pattern": "^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"
    },
    "type": { "type": "string", "minLength": 1 },
    "name": { "type": "string", "minLength": 1 },
    "config": { "type": "object" },
    "created_at": { "type": "string" }
  }
}
```

- [ ] **Step 4 — Run passing tests.** Confirm all assertions pass.

```bash
cd runtime && mix test test/esr/entity/agent/instance_test.exs test/esr/entity/agent/instance_schema_test.exs 2>&1 | tail -5
```

- [ ] **Step 5 — Commit.**

```bash
git add runtime/lib/esr/entity/agent/instance.ex \
        runtime/priv/schemas/agent_instance.v1.json \
        runtime/test/esr/entity/agent/instance_test.exs \
        runtime/test/esr/entity/agent/instance_schema_test.exs
git commit -m "feat(agent): add Agent.Instance struct + agent_instance.v1.json schema (Phase 3.1)"
```

---

### Task 3.2: `Esr.Entity.Agent.InstanceRegistry` (per-session ETS)

**Files:**
- Create: `runtime/lib/esr/entity/agent/instance_registry.ex`
- Create: `runtime/test/esr/entity/agent/instance_registry_test.exs`

**Reference:** `runtime/lib/esr/entity/agent/stateful_registry.ex` — mirror the GenServer-with-ETS pattern. Key difference: single ETS table keyed by `{session_uuid, agent_name}` for O(1) name-uniqueness checks.

- [ ] **Step 1 — Write failing test.** Create `runtime/test/esr/entity/agent/instance_registry_test.exs`:

```elixir
defmodule Esr.Entity.Agent.InstanceRegistryTest do
  use ExUnit.Case, async: false
  alias Esr.Entity.Agent.InstanceRegistry

  @sess1 "a1b2c3d4-e5f6-4a7b-8c9d-e0f1a2b3c4d5"
  @sess2 "b2c3d4e5-f6a7-4b8c-9d0e-f1a2b3c4d5e6"

  setup do
    # Each test uses a fresh GenServer under a unique name to isolate ETS state.
    name = :"ir_test_#{:erlang.unique_integer([:positive])}"
    {:ok, _} = start_supervised({InstanceRegistry, name: name})
    %{reg: name}
  end

  describe "add_instance/2" do
    test "adds instance to session", %{reg: reg} do
      assert :ok = InstanceRegistry.add_instance(reg, %{session_id: @sess1, type: "cc", name: "dev", config: %{}})
      assert {:ok, inst} = InstanceRegistry.get(reg, @sess1, "dev")
      assert inst.type == "cc"
      assert inst.name == "dev"
    end

    test "rejects duplicate name in same session regardless of type", %{reg: reg} do
      :ok = InstanceRegistry.add_instance(reg, %{session_id: @sess1, type: "cc", name: "dev", config: %{}})
      assert {:error, {:duplicate_agent_name, "dev"}} =
               InstanceRegistry.add_instance(reg, %{session_id: @sess1, type: "codex", name: "dev", config: %{}})
    end

    test "same name in different sessions is allowed", %{reg: reg} do
      :ok = InstanceRegistry.add_instance(reg, %{session_id: @sess1, type: "cc", name: "dev", config: %{}})
      assert :ok = InstanceRegistry.add_instance(reg, %{session_id: @sess2, type: "cc", name: "dev", config: %{}})
    end

    test "sets as primary if first agent in session", %{reg: reg} do
      :ok = InstanceRegistry.add_instance(reg, %{session_id: @sess1, type: "cc", name: "alice", config: %{}})
      assert {:ok, "alice"} = InstanceRegistry.primary(reg, @sess1)
    end

    test "does not change primary if not first agent", %{reg: reg} do
      :ok = InstanceRegistry.add_instance(reg, %{session_id: @sess1, type: "cc", name: "alice", config: %{}})
      :ok = InstanceRegistry.add_instance(reg, %{session_id: @sess1, type: "cc", name: "bob", config: %{}})
      assert {:ok, "alice"} = InstanceRegistry.primary(reg, @sess1)
    end
  end

  describe "remove_instance/3" do
    test "removes instance from session", %{reg: reg} do
      :ok = InstanceRegistry.add_instance(reg, %{session_id: @sess1, type: "cc", name: "dev", config: %{}})
      :ok = InstanceRegistry.add_instance(reg, %{session_id: @sess1, type: "cc", name: "reviewer", config: %{}})
      :ok = InstanceRegistry.set_primary(reg, @sess1, "reviewer")

      assert :ok = InstanceRegistry.remove_instance(reg, @sess1, "dev")
      assert :not_found = InstanceRegistry.get(reg, @sess1, "dev")
    end

    test "cannot remove primary agent without first setting another primary", %{reg: reg} do
      :ok = InstanceRegistry.add_instance(reg, %{session_id: @sess1, type: "cc", name: "alice", config: %{}})
      assert {:error, :cannot_remove_primary} = InstanceRegistry.remove_instance(reg, @sess1, "alice")
    end

    test "remove last agent clears primary", %{reg: reg} do
      :ok = InstanceRegistry.add_instance(reg, %{session_id: @sess1, type: "cc", name: "only", config: %{}})
      :ok = InstanceRegistry.set_primary(reg, @sess1, "only")
      # Must set_primary to something else first — but there is nothing else.
      # This tests that remove guard fires correctly.
      assert {:error, :cannot_remove_primary} = InstanceRegistry.remove_instance(reg, @sess1, "only")
    end

    test "returns :not_found for unknown agent", %{reg: reg} do
      assert {:error, :not_found} = InstanceRegistry.remove_instance(reg, @sess1, "ghost")
    end
  end

  describe "list/2" do
    test "returns all instances for session", %{reg: reg} do
      :ok = InstanceRegistry.add_instance(reg, %{session_id: @sess1, type: "cc", name: "a", config: %{}})
      :ok = InstanceRegistry.add_instance(reg, %{session_id: @sess1, type: "cc", name: "b", config: %{}})
      :ok = InstanceRegistry.add_instance(reg, %{session_id: @sess2, type: "cc", name: "a", config: %{}})

      instances = InstanceRegistry.list(reg, @sess1)
      names = Enum.map(instances, & &1.name) |> Enum.sort()
      assert names == ["a", "b"]
    end

    test "returns empty list for unknown session", %{reg: reg} do
      assert [] = InstanceRegistry.list(reg, @sess1)
    end
  end

  describe "set_primary/3 + primary/2" do
    test "set_primary changes the primary agent", %{reg: reg} do
      :ok = InstanceRegistry.add_instance(reg, %{session_id: @sess1, type: "cc", name: "alice", config: %{}})
      :ok = InstanceRegistry.add_instance(reg, %{session_id: @sess1, type: "cc", name: "bob", config: %{}})

      assert :ok = InstanceRegistry.set_primary(reg, @sess1, "bob")
      assert {:ok, "bob"} = InstanceRegistry.primary(reg, @sess1)
    end

    test "set_primary on unknown name returns error", %{reg: reg} do
      assert {:error, :not_found} = InstanceRegistry.set_primary(reg, @sess1, "ghost")
    end

    test "primary returns :not_found for session with no agents", %{reg: reg} do
      assert :not_found = InstanceRegistry.primary(reg, @sess1)
    end
  end

  describe "names_for_session/2" do
    test "returns list of agent names for session", %{reg: reg} do
      :ok = InstanceRegistry.add_instance(reg, %{session_id: @sess1, type: "cc", name: "x", config: %{}})
      :ok = InstanceRegistry.add_instance(reg, %{session_id: @sess1, type: "cc", name: "y", config: %{}})
      names = InstanceRegistry.names_for_session(reg, @sess1)
      assert Enum.sort(names) == ["x", "y"]
    end
  end
end
```

- [ ] **Step 2 — Run failing tests.** Confirm `module Esr.Entity.Agent.InstanceRegistry is not available`.

```bash
cd runtime && mix test test/esr/entity/agent/instance_registry_test.exs 2>&1 | tail -10
```

- [ ] **Step 3 — Implement InstanceRegistry.** Create `runtime/lib/esr/entity/agent/instance_registry.ex`:

```elixir
defmodule Esr.Entity.Agent.InstanceRegistry do
  @moduledoc """
  Per-process ETS-backed registry of agent instances within sessions.

  ## ETS layout

  Single table: `{session_uuid, agent_name} => %Instance{}` for O(1)
  name-uniqueness checks and O(1) per-agent lookup.

  A separate `{:primary, session_uuid} => agent_name` entry tracks the
  primary agent for each session.

  ## Name uniqueness

  Names are unique within a session across all agent types (spec Q7=B).
  `add_instance/2` rejects a second instance with the same name in the
  same session regardless of type.

  ## Primary agent

  The first agent added to a session automatically becomes the primary
  (spec §4.B `/session:new` → "Primary = first agent added").
  `set_primary/3` changes it at any time. `remove_instance/3` is
  guarded: the primary agent cannot be removed until another is made
  primary first.

  ## Usage

  Start as a named GenServer (tests pass an atom as `name:`; production
  code starts a single global instance named `__MODULE__`):

      {:ok, _} = InstanceRegistry.start_link(name: Esr.Entity.Agent.InstanceRegistry)
  """

  use GenServer
  alias Esr.Entity.Agent.Instance

  @table :esr_agent_instances

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Add an agent instance to `session_id`. The `attrs` map must contain at
  minimum: `session_id`, `type`, `name`, `config`.

  Returns `:ok` on success, `{:error, {:duplicate_agent_name, name}}` if the
  name already exists in the session.
  """
  @spec add_instance(GenServer.server(), map()) ::
          :ok | {:error, {:duplicate_agent_name, String.t()}}
  def add_instance(server \\ __MODULE__, attrs) when is_map(attrs) do
    GenServer.call(server, {:add_instance, attrs})
  end

  @doc """
  Remove the agent named `name` from `session_id`.

  Returns `:ok`, `{:error, :cannot_remove_primary}`, or `{:error, :not_found}`.
  """
  @spec remove_instance(GenServer.server(), String.t(), String.t()) ::
          :ok | {:error, :cannot_remove_primary | :not_found}
  def remove_instance(server \\ __MODULE__, session_id, name)
      when is_binary(session_id) and is_binary(name) do
    GenServer.call(server, {:remove_instance, session_id, name})
  end

  @doc "Return all instances for `session_id` as a list of `%Instance{}`."
  @spec list(GenServer.server(), String.t()) :: [Instance.t()]
  def list(server \\ __MODULE__, session_id) when is_binary(session_id) do
    tab = GenServer.call(server, :table_name)

    :ets.match_object(tab, {{session_id, :_}, :_})
    |> Enum.filter(fn {{_s, k}, _} -> k != :__primary__ end)
    |> Enum.map(fn {_key, inst} -> inst end)
  end

  @doc "Fetch a single instance by session + name. Returns `{:ok, inst}` or `:not_found`."
  @spec get(GenServer.server(), String.t(), String.t()) ::
          {:ok, Instance.t()} | :not_found
  def get(server \\ __MODULE__, session_id, name)
      when is_binary(session_id) and is_binary(name) do
    tab = GenServer.call(server, :table_name)
    case :ets.lookup(tab, {session_id, name}) do
      [{_, inst}] -> {:ok, inst}
      [] -> :not_found
    end
  end

  @doc """
  Set `name` as the primary agent for `session_id`.

  Returns `:ok` or `{:error, :not_found}` if the name doesn't exist.
  """
  @spec set_primary(GenServer.server(), String.t(), String.t()) ::
          :ok | {:error, :not_found}
  def set_primary(server \\ __MODULE__, session_id, name)
      when is_binary(session_id) and is_binary(name) do
    GenServer.call(server, {:set_primary, session_id, name})
  end

  @doc """
  Return the primary agent name for `session_id`.

  Returns `{:ok, name}` or `:not_found`.
  """
  @spec primary(GenServer.server(), String.t()) :: {:ok, String.t()} | :not_found
  def primary(server \\ __MODULE__, session_id) when is_binary(session_id) do
    tab = GenServer.call(server, :table_name)
    case :ets.lookup(tab, {session_id, :__primary__}) do
      [{_, name}] when is_binary(name) -> {:ok, name}
      _ -> :not_found
    end
  end

  @doc "Return agent names for session (used by name-uniqueness check in AddAgent)."
  @spec names_for_session(GenServer.server(), String.t()) :: [String.t()]
  def names_for_session(server \\ __MODULE__, session_id) when is_binary(session_id) do
    list(server, session_id) |> Enum.map(& &1.name)
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(opts) do
    # Each named process owns its own ETS table (named by the server name so
    # tests using unique atom names don't collide).
    server_name = Keyword.get(opts, :name, __MODULE__)
    table = :ets.new(server_name, [:set, :public, :named_table])
    {:ok, %{table: table}}
  end

  @impl true
  def handle_call(:table_name, _from, state), do: {:reply, state.table, state}

  @impl true
  def handle_call({:add_instance, attrs}, _from, state) do
    session_id = Map.fetch!(attrs, :session_id)
    name = Map.fetch!(attrs, :name)

    case :ets.lookup(state.table, {session_id, name}) do
      [_] ->
        {:reply, {:error, {:duplicate_agent_name, name}}, state}

      [] ->
        inst = %Instance{
          id: uuid_v4(),
          session_id: session_id,
          type: Map.fetch!(attrs, :type),
          name: name,
          config: Map.get(attrs, :config, %{}),
          created_at: iso_now()
        }

        :ets.insert(state.table, {{session_id, name}, inst})

        # Auto-promote to primary if this is the first agent in the session.
        unless :ets.lookup(state.table, {session_id, :__primary__}) != [] do
          :ets.insert(state.table, {{session_id, :__primary__}, name})
        end

        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_call({:remove_instance, session_id, name}, _from, state) do
    case :ets.lookup(state.table, {session_id, name}) do
      [] ->
        {:reply, {:error, :not_found}, state}

      [_] ->
        primary_name =
          case :ets.lookup(state.table, {session_id, :__primary__}) do
            [{_, n}] -> n
            _ -> nil
          end

        if primary_name == name do
          {:reply, {:error, :cannot_remove_primary}, state}
        else
          :ets.delete(state.table, {session_id, name})
          {:reply, :ok, state}
        end
    end
  end

  @impl true
  def handle_call({:set_primary, session_id, name}, _from, state) do
    case :ets.lookup(state.table, {session_id, name}) do
      [] ->
        {:reply, {:error, :not_found}, state}

      [_] ->
        :ets.insert(state.table, {{session_id, :__primary__}, name})
        {:reply, :ok, state}
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp uuid_v4 do
    # Delegate to Uniq or fallback to Erlang random bytes.
    if Code.ensure_loaded?(Uniq.UUID) do
      Uniq.UUID.uuid4()
    else
      <<a::32, b::16, c::16, d::16, e::48>> = :crypto.strong_rand_bytes(16)
      c = Bitwise.bor(Bitwise.band(c, 0x0FFF), 0x4000)
      d = Bitwise.bor(Bitwise.band(d, 0x3FFF), 0x8000)
      :io_lib.format(
        "~8.16.0b-~4.16.0b-~4.16.0b-~4.16.0b-~12.16.0b",
        [a, b, c, d, e]
      )
      |> IO.iodata_to_binary()
    end
  end

  defp iso_now do
    DateTime.utc_now() |> DateTime.to_iso8601()
  end
end
```

- [ ] **Step 4 — Run passing tests.** Confirm all 14 assertions pass.

```bash
cd runtime && mix test test/esr/entity/agent/instance_registry_test.exs 2>&1 | tail -5
```

- [ ] **Step 5 — Commit.**

```bash
git add runtime/lib/esr/entity/agent/instance_registry.ex \
        runtime/test/esr/entity/agent/instance_registry_test.exs
git commit -m "feat(agent): add Agent.InstanceRegistry per-session ETS + name-uniqueness guard (Phase 3.2)"
```

---

### Task 3.3: `Session.Registry` integration — agents field + persistence

**Files:**
- Modify: `runtime/lib/esr/resource/session/registry.ex`
- Modify: `runtime/test/esr/resource/session/registry_test.exs` (extend)

**Goal:** `Session.Registry` gains `add_agent_to_session/4` and `remove_agent_from_session/3` that write through to `InstanceRegistry` and persist the updated `agents` list back to `session.json` on disk. On Registry restart, `InstanceRegistry` is re-populated from the persisted JSON.

- [ ] **Step 1 — Write failing test.** Append to `runtime/test/esr/resource/session/registry_test.exs`:

```elixir
  describe "add_agent_to_session/4 + persistence round-trip" do
    setup do
      tmp = Path.join(System.tmp_dir!(), "sess_reg_agents_#{:rand.uniform(1_000_000)}")
      File.mkdir_p!(tmp)
      on_exit(fn -> File.rm_rf!(tmp) end)
      %{tmp: tmp}
    end

    test "add_agent persists to session.json and survives registry restart", %{tmp: tmp} do
      {:ok, _} = Esr.Resource.Session.Registry.start_link(data_dir: tmp)

      {:ok, session_id} =
        Esr.Resource.Session.Registry.create_session(tmp, %{
          name: "my-sess",
          owner_user: "b2c3d4e5-f6a7-4b8c-9d0e-f1a2b3c4d5e6",
          workspace_id: "c3d4e5f6-a7b8-4c9d-0e1f-a2b3c4d5e6f7"
        })

      :ok =
        Esr.Resource.Session.Registry.add_agent_to_session(
          tmp, session_id, "cc", "dev", %{}
        )

      # Verify persisted JSON contains the agent.
      session_json_path = Path.join([tmp, "sessions", session_id, "session.json"])
      persisted = File.read!(session_json_path) |> Jason.decode!()
      assert [%{"type" => "cc", "name" => "dev"}] = persisted["agents"]
      assert persisted["primary_agent"] == "dev"

      # Simulate restart: reload session from disk.
      {:ok, sess} = Esr.Resource.Session.Registry.get_session(session_id)
      assert [%{type: "cc", name: "dev"}] = sess.agents
      assert sess.primary_agent == "dev"
    end

    test "add_agent returns error on duplicate name" do
      {:ok, session_id} =
        Esr.Resource.Session.Registry.create_session(System.tmp_dir!(), %{
          name: "dup-test-sess",
          owner_user: "b2c3d4e5-f6a7-4b8c-9d0e-f1a2b3c4d5e6",
          workspace_id: "c3d4e5f6-a7b8-4c9d-0e1f-a2b3c4d5e6f7"
        })

      :ok = Esr.Resource.Session.Registry.add_agent_to_session(
        System.tmp_dir!(), session_id, "cc", "dev", %{}
      )

      assert {:error, {:duplicate_agent_name, "dev"}} =
               Esr.Resource.Session.Registry.add_agent_to_session(
                 System.tmp_dir!(), session_id, "codex", "dev", %{}
               )
    end
  end
```

- [ ] **Step 2 — Run failing tests.** Confirm `add_agent_to_session/4` is undefined.

```bash
cd runtime && mix test test/esr/resource/session/registry_test.exs 2>&1 | grep -E "add_agent|undefined" | head -5
```

- [ ] **Step 3 — Add `add_agent_to_session/4` and `remove_agent_from_session/3` to `Session.Registry`.** In `runtime/lib/esr/resource/session/registry.ex`, add the following public API functions and matching `handle_call` clauses:

```elixir
  @doc """
  Add an agent instance to the session with `session_id`.

  Delegates name-uniqueness enforcement to `InstanceRegistry`.
  On success, writes the updated agents list back to `session.json`.

  Returns `:ok` or `{:error, {:duplicate_agent_name, name}}`.
  """
  @spec add_agent_to_session(String.t(), String.t(), String.t(), String.t(), map()) ::
          :ok | {:error, {:duplicate_agent_name, String.t()}}
  def add_agent_to_session(data_dir, session_id, type, name, config) do
    GenServer.call(
      __MODULE__,
      {:add_agent_to_session, data_dir, session_id, type, name, config}
    )
  end

  @doc """
  Remove the agent named `name` from the session with `session_id`.

  Returns `:ok`, `{:error, :cannot_remove_primary}`, or `{:error, :not_found}`.
  """
  @spec remove_agent_from_session(String.t(), String.t(), String.t()) ::
          :ok | {:error, :cannot_remove_primary | :not_found}
  def remove_agent_from_session(session_id, name, data_dir) do
    GenServer.call(__MODULE__, {:remove_agent_from_session, session_id, name, data_dir})
  end
```

Add corresponding `handle_call` clauses in the GenServer implementation:

```elixir
  def handle_call({:add_agent_to_session, data_dir, session_id, type, name, config}, _from, state) do
    case Esr.Entity.Agent.InstanceRegistry.add_instance(%{
           session_id: session_id,
           type: type,
           name: name,
           config: config
         }) do
      :ok ->
        # Re-read all instances for this session and persist to session.json.
        case persist_agents(data_dir, session_id) do
          :ok -> {:reply, :ok, state}
          {:error, _} = err -> {:reply, err, state}
        end

      {:error, _} = err ->
        {:reply, err, state}
    end
  end

  def handle_call({:remove_agent_from_session, session_id, name, data_dir}, _from, state) do
    case Esr.Entity.Agent.InstanceRegistry.remove_instance(session_id, name) do
      :ok ->
        case persist_agents(data_dir, session_id) do
          :ok -> {:reply, :ok, state}
          {:error, _} = err -> {:reply, err, state}
        end

      {:error, _} = err ->
        {:reply, err, state}
    end
  end
```

Add the private `persist_agents/2` helper:

```elixir
  defp persist_agents(data_dir, session_id) do
    instances = Esr.Entity.Agent.InstanceRegistry.list(session_id)
    primary =
      case Esr.Entity.Agent.InstanceRegistry.primary(session_id) do
        {:ok, n} -> n
        :not_found -> nil
      end

    agents_json = Enum.map(instances, fn i -> %{"type" => i.type, "name" => i.name, "config" => i.config} end)

    session_json_path =
      Path.join([data_dir, "sessions", session_id, "session.json"])

    case File.read(session_json_path) do
      {:ok, raw} ->
        doc =
          raw
          |> Jason.decode!()
          |> Map.put("agents", agents_json)
          |> Map.put("primary_agent", primary || "")

        tmp_path = session_json_path <> ".tmp"
        File.write!(tmp_path, Jason.encode!(doc, pretty: true))
        File.rename!(tmp_path, session_json_path)
        :ok

      {:error, reason} ->
        {:error, {:session_json_missing, reason}}
    end
  end
```

- [ ] **Step 4 — Run passing tests.** Confirm persistence round-trip tests pass.

```bash
cd runtime && mix test test/esr/resource/session/registry_test.exs 2>&1 | tail -5
```

- [ ] **Step 5 — Commit.**

```bash
git add runtime/lib/esr/resource/session/registry.ex \
        runtime/test/esr/resource/session/registry_test.exs
git commit -m "feat(session): add_agent_to_session/4 write-through to InstanceRegistry + persist (Phase 3.3)"
```

---

### Task 3.4: Session-scoped agent commands (low-level API)

**Files:**
- Create: `runtime/lib/esr/commands/session/add_agent.ex`
- Create: `runtime/lib/esr/commands/session/remove_agent.ex`
- Create: `runtime/lib/esr/commands/session/set_primary.ex`
- Create: `runtime/test/esr/commands/session/add_agent_test.exs`
- Create: `runtime/test/esr/commands/session/remove_agent_test.exs`
- Create: `runtime/test/esr/commands/session/set_primary_test.exs`

**Reference:** `runtime/lib/esr/commands/cap/grant.ex` — mirror the `@behaviour Esr.Role.Control` + `execute/1` pattern.

Note: Slash-routes YAML entries for `/session:add-agent`, `/session:remove-agent`, `/session:set-primary` are added in Phase 6 (colon-namespace cutover). These modules are pure `execute/1` functions callable directly from the admin dispatcher or tests.

- [ ] **Step 1 — Write failing tests.**

Create `runtime/test/esr/commands/session/add_agent_test.exs`:

```elixir
defmodule Esr.Commands.Session.AddAgentTest do
  use ExUnit.Case, async: false
  alias Esr.Commands.Session.AddAgent

  @sess "a1b2c3d4-e5f6-4a7b-8c9d-e0f1a2b3c4d5"

  setup do
    # Ensure InstanceRegistry is running for tests.
    case Process.whereis(Esr.Entity.Agent.InstanceRegistry) do
      nil -> start_supervised!(Esr.Entity.Agent.InstanceRegistry)
      _ -> :ok
    end
    :ok
  end

  test "success: adds agent to session" do
    cmd = %{"args" => %{"session_id" => @sess, "type" => "cc", "name" => "dev-#{:rand.uniform(9999)}", "config" => %{}}}
    assert {:ok, result} = AddAgent.execute(cmd)
    assert result["action"] == "added"
    assert result["type"] == "cc"
  end

  test "error: duplicate name returns structured error" do
    name = "dup-#{:rand.uniform(9999)}"
    cmd = %{"args" => %{"session_id" => @sess, "type" => "cc", "name" => name, "config" => %{}}}
    {:ok, _} = AddAgent.execute(cmd)
    assert {:error, %{"type" => "duplicate_agent_name"}} = AddAgent.execute(cmd)
  end

  test "error: missing session_id" do
    cmd = %{"args" => %{"type" => "cc", "name" => "dev"}}
    assert {:error, %{"type" => "invalid_args"}} = AddAgent.execute(cmd)
  end

  test "error: missing name" do
    cmd = %{"args" => %{"session_id" => @sess, "type" => "cc"}}
    assert {:error, %{"type" => "invalid_args"}} = AddAgent.execute(cmd)
  end

  test "error: missing type" do
    cmd = %{"args" => %{"session_id" => @sess, "name" => "dev"}}
    assert {:error, %{"type" => "invalid_args"}} = AddAgent.execute(cmd)
  end
end
```

Create `runtime/test/esr/commands/session/remove_agent_test.exs`:

```elixir
defmodule Esr.Commands.Session.RemoveAgentTest do
  use ExUnit.Case, async: false
  alias Esr.Commands.Session.{AddAgent, RemoveAgent, SetPrimary}

  @sess "b2c3d4e5-f6a7-4b8c-9d0e-f1a2b3c4d5e6"

  setup do
    case Process.whereis(Esr.Entity.Agent.InstanceRegistry) do
      nil -> start_supervised!(Esr.Entity.Agent.InstanceRegistry)
      _ -> :ok
    end
    :ok
  end

  test "success: removes a non-primary agent" do
    alice = "alice-#{:rand.uniform(9999)}"
    bob = "bob-#{:rand.uniform(9999)}"
    sess = "c3d4e5f6-a7b8-4c9d-0e1f-#{:rand.uniform(999_999_999_999)}"

    AddAgent.execute(%{"args" => %{"session_id" => sess, "type" => "cc", "name" => alice, "config" => %{}}})
    AddAgent.execute(%{"args" => %{"session_id" => sess, "type" => "cc", "name" => bob, "config" => %{}}})
    SetPrimary.execute(%{"args" => %{"session_id" => sess, "name" => bob}})

    assert {:ok, %{"action" => "removed"}} =
             RemoveAgent.execute(%{"args" => %{"session_id" => sess, "name" => alice}})
  end

  test "error: cannot remove primary agent" do
    name = "primary-#{:rand.uniform(9999)}"
    sess = "d4e5f6a7-b8c9-4d0e-1f2a-#{:rand.uniform(999_999_999_999)}"
    AddAgent.execute(%{"args" => %{"session_id" => sess, "type" => "cc", "name" => name, "config" => %{}}})

    assert {:error, %{"type" => "cannot_remove_primary"}} =
             RemoveAgent.execute(%{"args" => %{"session_id" => sess, "name" => name}})
  end

  test "error: unknown agent name" do
    assert {:error, %{"type" => "not_found"}} =
             RemoveAgent.execute(%{"args" => %{"session_id" => @sess, "name" => "ghost"}})
  end

  test "error: missing session_id" do
    assert {:error, %{"type" => "invalid_args"}} =
             RemoveAgent.execute(%{"args" => %{"name" => "dev"}})
  end
end
```

Create `runtime/test/esr/commands/session/set_primary_test.exs`:

```elixir
defmodule Esr.Commands.Session.SetPrimaryTest do
  use ExUnit.Case, async: false
  alias Esr.Commands.Session.{AddAgent, SetPrimary}

  setup do
    case Process.whereis(Esr.Entity.Agent.InstanceRegistry) do
      nil -> start_supervised!(Esr.Entity.Agent.InstanceRegistry)
      _ -> :ok
    end
    :ok
  end

  test "success: changes primary agent and persists to session" do
    sess = "e5f6a7b8-c9d0-4e1f-2a3b-#{:rand.uniform(999_999_999_999)}"
    alice = "alice-#{:rand.uniform(9999)}"
    bob = "bob-#{:rand.uniform(9999)}"

    AddAgent.execute(%{"args" => %{"session_id" => sess, "type" => "cc", "name" => alice, "config" => %{}}})
    AddAgent.execute(%{"args" => %{"session_id" => sess, "type" => "cc", "name" => bob, "config" => %{}}})

    assert {:ok, %{"action" => "primary_set", "primary_agent" => ^bob}} =
             SetPrimary.execute(%{"args" => %{"session_id" => sess, "name" => bob}})
  end

  test "error: unknown agent name" do
    sess = "f6a7b8c9-d0e1-4f2a-3b4c-#{:rand.uniform(999_999_999_999)}"
    assert {:error, %{"type" => "not_found"}} =
             SetPrimary.execute(%{"args" => %{"session_id" => sess, "name" => "ghost"}})
  end

  test "error: missing session_id" do
    assert {:error, %{"type" => "invalid_args"}} =
             SetPrimary.execute(%{"args" => %{"name" => "dev"}})
  end

  test "error: missing name" do
    assert {:error, %{"type" => "invalid_args"}} =
             SetPrimary.execute(%{"args" => %{"session_id" => "a1b2c3d4-e5f6-4a7b-8c9d-e0f1a2b3c4d5"}})
  end
end
```

- [ ] **Step 2 — Run failing tests.** Confirm command modules are not available.

```bash
cd runtime && mix test test/esr/commands/session/add_agent_test.exs \
                       test/esr/commands/session/remove_agent_test.exs \
                       test/esr/commands/session/set_primary_test.exs 2>&1 | tail -10
```

- [ ] **Step 3 — Implement command modules.**

Create `runtime/lib/esr/commands/session/add_agent.ex`:

```elixir
defmodule Esr.Commands.Session.AddAgent do
  @moduledoc """
  Add an agent instance to a session (`/session:add-agent`).

  Slash-routes YAML entry added in Phase 6.
  """

  @behaviour Esr.Role.Control

  alias Esr.Entity.Agent.InstanceRegistry

  @spec execute(map()) :: {:ok, map()} | {:error, map()}
  def execute(%{"args" => %{"session_id" => sid, "type" => type, "name" => name} = args})
      when is_binary(sid) and sid != ""
      and is_binary(type) and type != ""
      and is_binary(name) and name != "" do
    config = Map.get(args, "config", %{})

    case InstanceRegistry.add_instance(%{session_id: sid, type: type, name: name, config: config}) do
      :ok ->
        {:ok,
         %{
           "action" => "added",
           "session_id" => sid,
           "type" => type,
           "name" => name
         }}

      {:error, {:duplicate_agent_name, n}} ->
        {:error,
         %{
           "type" => "duplicate_agent_name",
           "message" =>
             "agent name '#{n}' already exists in session '#{sid}' (pick a different name)"
         }}
    end
  end

  def execute(_cmd) do
    {:error,
     %{
       "type" => "invalid_args",
       "message" =>
         "add_agent requires args.session_id, args.type, and args.name (all non-empty strings)"
     }}
  end
end
```

Create `runtime/lib/esr/commands/session/remove_agent.ex`:

```elixir
defmodule Esr.Commands.Session.RemoveAgent do
  @moduledoc """
  Remove an agent instance from a session (`/session:remove-agent`).

  Cannot remove the primary agent — the caller must set another agent as
  primary first via `/session:set-primary`.

  Slash-routes YAML entry added in Phase 6.
  """

  @behaviour Esr.Role.Control

  alias Esr.Entity.Agent.InstanceRegistry

  @spec execute(map()) :: {:ok, map()} | {:error, map()}
  def execute(%{"args" => %{"session_id" => sid, "name" => name}})
      when is_binary(sid) and sid != "" and is_binary(name) and name != "" do
    case InstanceRegistry.remove_instance(sid, name) do
      :ok ->
        {:ok, %{"action" => "removed", "session_id" => sid, "name" => name}}

      {:error, :cannot_remove_primary} ->
        {:error,
         %{
           "type" => "cannot_remove_primary",
           "message" =>
             "cannot remove primary agent '#{name}'; use /session:set-primary to promote another agent first"
         }}

      {:error, :not_found} ->
        {:error,
         %{
           "type" => "not_found",
           "message" => "no agent named '#{name}' in session '#{sid}'"
         }}
    end
  end

  def execute(_cmd) do
    {:error,
     %{
       "type" => "invalid_args",
       "message" => "remove_agent requires args.session_id and args.name (non-empty strings)"
     }}
  end
end
```

Create `runtime/lib/esr/commands/session/set_primary.ex`:

```elixir
defmodule Esr.Commands.Session.SetPrimary do
  @moduledoc """
  Set the primary agent for a session (`/session:set-primary`).

  The primary agent receives all plain-text messages that do not contain
  an explicit `@<name>` mention (spec Q8=A).

  Slash-routes YAML entry added in Phase 6.
  """

  @behaviour Esr.Role.Control

  alias Esr.Entity.Agent.InstanceRegistry

  @spec execute(map()) :: {:ok, map()} | {:error, map()}
  def execute(%{"args" => %{"session_id" => sid, "name" => name}})
      when is_binary(sid) and sid != "" and is_binary(name) and name != "" do
    case InstanceRegistry.set_primary(sid, name) do
      :ok ->
        {:ok,
         %{
           "action" => "primary_set",
           "session_id" => sid,
           "primary_agent" => name
         }}

      {:error, :not_found} ->
        {:error,
         %{
           "type" => "not_found",
           "message" => "no agent named '#{name}' in session '#{sid}'"
         }}
    end
  end

  def execute(_cmd) do
    {:error,
     %{
       "type" => "invalid_args",
       "message" => "set_primary requires args.session_id and args.name (non-empty strings)"
     }}
  end
end
```

- [ ] **Step 4 — Run passing tests.**

```bash
cd runtime && mix test test/esr/commands/session/add_agent_test.exs \
                       test/esr/commands/session/remove_agent_test.exs \
                       test/esr/commands/session/set_primary_test.exs 2>&1 | tail -5
```

- [ ] **Step 5 — Commit.**

```bash
git add runtime/lib/esr/commands/session/add_agent.ex \
        runtime/lib/esr/commands/session/remove_agent.ex \
        runtime/lib/esr/commands/session/set_primary.ex \
        runtime/test/esr/commands/session/add_agent_test.exs \
        runtime/test/esr/commands/session/remove_agent_test.exs \
        runtime/test/esr/commands/session/set_primary_test.exs
git commit -m "feat(commands): add AddAgent, RemoveAgent, SetPrimary session commands (Phase 3.4)"
```

---

### Task 3.5: Plugin agent-type validation in `AddAgent`

**Files:**
- Modify: `runtime/lib/esr/commands/session/add_agent.ex`
- Modify: `runtime/test/esr/commands/session/add_agent_test.exs` (extend)

**Goal:** Reject any `type` that is not declared in an enabled plugin's manifest. The `claude_code` plugin declares `type: "cc"` in its manifest; any other undeclared type returns a structured error. This uses `Esr.Entity.Agent.Registry` (the agents.yaml-based type registry introduced in PR-21κ) to enumerate known types.

- [ ] **Step 1 — Write failing tests.** Append to `runtime/test/esr/commands/session/add_agent_test.exs`:

```elixir
  describe "plugin type validation" do
    test "type declared in enabled plugin manifest is accepted" do
      # "cc" is the claude_code plugin type — declared in agents.yaml / plugin manifest.
      cmd = %{"args" => %{"session_id" => @sess, "type" => "cc", "name" => "valid-#{:rand.uniform(9999)}", "config" => %{}}}
      assert {:ok, _} = AddAgent.execute(cmd)
    end

    test "type not declared in any enabled plugin is rejected" do
      cmd = %{"args" => %{"session_id" => @sess, "type" => "nonexistent_type_xyz", "name" => "x", "config" => %{}}}
      assert {:error, %{"type" => "unknown_agent_type"}} = AddAgent.execute(cmd)
    end
  end
```

- [ ] **Step 2 — Run failing tests.** Confirm `unknown_agent_type` error is not returned yet.

```bash
cd runtime && mix test test/esr/commands/session/add_agent_test.exs 2>&1 | grep -E "unknown_agent|FAILED" | head -5
```

- [ ] **Step 3 — Add type validation to `AddAgent.execute/1`.** Replace the guard clause in `add_agent.ex` with:

```elixir
  @spec execute(map()) :: {:ok, map()} | {:error, map()}
  def execute(%{"args" => %{"session_id" => sid, "type" => type, "name" => name} = args})
      when is_binary(sid) and sid != ""
      and is_binary(type) and type != ""
      and is_binary(name) and name != "" do
    config = Map.get(args, "config", %{})

    with :ok <- validate_agent_type(type),
         :ok <- Esr.Entity.Agent.InstanceRegistry.add_instance(%{
                  session_id: sid,
                  type: type,
                  name: name,
                  config: config
                }) do
      {:ok,
       %{
         "action" => "added",
         "session_id" => sid,
         "type" => type,
         "name" => name
       }}
    else
      {:error, :unknown_agent_type} ->
        known = known_agent_types()
        {:error,
         %{
           "type" => "unknown_agent_type",
           "message" =>
             "agent type '#{type}' is not declared in any enabled plugin; known types: #{Enum.join(known, ", ")}"
         }}

      {:error, {:duplicate_agent_name, n}} ->
        {:error,
         %{
           "type" => "duplicate_agent_name",
           "message" =>
             "agent name '#{n}' already exists in session '#{sid}' (pick a different name)"
         }}
    end
  end
```

Add private helpers after `execute/1`:

```elixir
  defp validate_agent_type(type) do
    known = known_agent_types()
    if type in known, do: :ok, else: {:error, :unknown_agent_type}
  end

  defp known_agent_types do
    # Enumerate agent names known to the Agent.Registry (agents.yaml cache).
    # Each entry in agents.yaml declares an agent pipeline whose "type" key
    # maps to its top-level name.
    case Esr.Entity.Agent.Registry.list_agents() do
      names when is_list(names) -> names
      _ -> []
    end
  end
```

- [ ] **Step 4 — Run passing tests.** Confirm the `"cc"` type passes and `"nonexistent_type_xyz"` is rejected.

```bash
cd runtime && mix test test/esr/commands/session/add_agent_test.exs 2>&1 | tail -5
```

- [ ] **Step 5 — Commit.**

```bash
git add runtime/lib/esr/commands/session/add_agent.ex \
        runtime/test/esr/commands/session/add_agent_test.exs
git commit -m "feat(commands): AddAgent validates type against enabled plugin manifest (Phase 3.5)"
```

---

### Phase 3 PR checklist

Before opening the PR:

- [ ] Run full test suite: `cd runtime && mix test 2>&1 | tail -20`
- [ ] Confirm `InstanceRegistry` is added to supervision tree: `grep -r "InstanceRegistry" runtime/lib/esr/application.ex`
- [ ] Confirm `Esr.Commands.Session.{AddAgent,RemoveAgent,SetPrimary}` are reachable from `Esr.Admin.Dispatcher`: `grep -r "AddAgent\|RemoveAgent\|SetPrimary" runtime/lib/esr/admin/`

```bash
git commit -m "feat: multi-agent per session — instance model + name uniqueness (Phase 3)"
```

---

## Phase 4: Mention parser + primary-agent routing

**PR title:** `feat: mention parser + primary-agent routing on plain text (Phase 4)`
**Branch:** `feat/phase-4-mention-routing`
**Target:** `dev`
**Est LOC:** ~400
**Depends on:** Phase 3

**Goal:** Plain-text inbound messages containing `@<name>` are routed to the named agent. Plain text without a mention is routed to the session's primary agent. The `MentionParser` module implements the detection algorithm from spec §4 (mention parser specification). The inbound dispatch integration wires this into `SlashHandler` for non-slash plain-text messages.

---

### Task 4.1: `Esr.Entity.Agent.MentionParser`

**Files:**
- Create: `runtime/lib/esr/entity/agent/mention_parser.ex`
- Create: `runtime/test/esr/entity/agent/mention_parser_test.exs`

**Spec algorithm (§4):**
1. Scan text for `@` followed by `[a-zA-Z0-9_-]+`.
2. If found: check if the extracted name is in `agent_names` (case-sensitive).
3. If matched: return `{:mention, name, stripped_text}` where `stripped_text` has the `@<name>` removed and leading/trailing whitespace trimmed.
4. If not matched (name not in list): return `{:plain, text}` — route to primary.
5. Lone `@` not followed by `[a-zA-Z0-9_-]+`: return `{:plain, text}`.

- [ ] **Step 1 — Write failing test.** Create `runtime/test/esr/entity/agent/mention_parser_test.exs`:

```elixir
defmodule Esr.Entity.Agent.MentionParserTest do
  use ExUnit.Case, async: true
  alias Esr.Entity.Agent.MentionParser

  @agents ["esr-dev", "alice", "bob-reviewer"]

  describe "parse/2 — mention matched" do
    test "leading mention: '@esr-dev hello'" do
      assert {:mention, "esr-dev", "hello"} =
               MentionParser.parse("@esr-dev hello", @agents)
    end

    test "leading mention with no trailing text: '@alice'" do
      assert {:mention, "alice", ""} = MentionParser.parse("@alice", @agents)
    end

    test "mid-text mention: 'hey @alice what do you think'" do
      assert {:mention, "alice", "hey  what do you think"} =
               MentionParser.parse("hey @alice what do you think", @agents)
    end

    test "mention with dashes in name: '@bob-reviewer please check'" do
      assert {:mention, "bob-reviewer", "please check"} =
               MentionParser.parse("@bob-reviewer please check", @agents)
    end

    test "leading whitespace before @: '  @alice msg'" do
      assert {:mention, "alice", "msg"} =
               MentionParser.parse("  @alice msg", @agents)
    end
  end

  describe "parse/2 — no mention (plain)" do
    test "no @ in text" do
      assert {:plain, "just plain text"} =
               MentionParser.parse("just plain text", @agents)
    end

    test "lone @ not followed by identifier" do
      assert {:plain, "@ hello"} = MentionParser.parse("@ hello", @agents)
    end

    test "lone @ at end" do
      assert {:plain, "end @"} = MentionParser.parse("end @", @agents)
    end

    test "@name not in agent list routes to plain" do
      assert {:plain, "@unknown hello"} =
               MentionParser.parse("@unknown hello", @agents)
    end

    test "empty text" do
      assert {:plain, ""} = MentionParser.parse("", @agents)
    end

    test "text is just whitespace" do
      assert {:plain, "   "} = MentionParser.parse("   ", @agents)
    end
  end

  describe "parse/2 — multiple @ patterns" do
    test "first matched @ wins; second is left in rest text" do
      # @alice is matched first; @bob-reviewer stays in the remaining text.
      assert {:mention, "alice", "cc @bob-reviewer too"} =
               MentionParser.parse("@alice cc @bob-reviewer too", @agents)
    end

    test "@x@y — @x not in list, @y not extracted (treated as one token)" do
      # '@x@y' — the regex captures 'x@y' or stops at '@y'? Per spec algorithm
      # step 1: scan for '@' + '[a-zA-Z0-9_-]+'. The first match is @x (captures
      # 'x' before '@'); 'x' is not in agent list → :plain.
      assert {:plain, "@x@y"} = MentionParser.parse("@x@y", ["esr-dev"])
    end

    test "@alice@bob — @alice matched; stripped text is '@bob'" do
      assert {:mention, "alice", "@bob"} =
               MentionParser.parse("@alice@bob", ["alice", "bob"])
    end
  end

  describe "parse/2 — empty agent list" do
    test "any @name → plain when no agents registered" do
      assert {:plain, "@alice hello"} = MentionParser.parse("@alice hello", [])
    end
  end
end
```

- [ ] **Step 2 — Run failing tests.** Confirm `module Esr.Entity.Agent.MentionParser is not available`.

```bash
cd runtime && mix test test/esr/entity/agent/mention_parser_test.exs 2>&1 | tail -10
```

- [ ] **Step 3 — Implement `MentionParser`.** Create `runtime/lib/esr/entity/agent/mention_parser.ex`:

```elixir
defmodule Esr.Entity.Agent.MentionParser do
  @moduledoc """
  Parse `@<name>` mentions from inbound message text.

  ## Algorithm (spec §4 — mention parser specification)

  1. Scan text for the first occurrence of `@` followed by `[a-zA-Z0-9_-]+`.
  2. If found, check the extracted name against `agent_names` (case-sensitive).
  3. Name matched → `{:mention, name, stripped_text}` where `stripped_text` is
     the original text with `@<name>` removed and the result trimmed.
  4. Name NOT in list → `{:plain, text}` (route to primary agent).
  5. No `@<identifier>` pattern found → `{:plain, text}`.

  ## Return values

    * `{:mention, agent_name, rest}` — `agent_name` is the matched name;
      `rest` is the message text with the `@<name>` token removed (trimmed).
    * `{:plain, text}` — no matched mention; route to primary agent.

  ## Examples

      iex> MentionParser.parse("@alice hello", ["alice", "bob"])
      {:mention, "alice", "hello"}

      iex> MentionParser.parse("@ lone at", ["alice"])
      {:plain, "@ lone at"}

      iex> MentionParser.parse("@unknown hi", ["alice"])
      {:plain, "@unknown hi"}
  """

  @mention_pattern ~r/@([a-zA-Z0-9][a-zA-Z0-9_-]*)/

  @doc """
  Parse `text` for an `@<name>` mention.

  `agent_names` is the list of known agent names for the current session.
  Matching is case-sensitive and uses simple string equality (spec Q7=B).
  """
  @spec parse(String.t(), [String.t()]) ::
          {:mention, String.t(), String.t()} | {:plain, String.t()}
  def parse(text, agent_names) when is_binary(text) and is_list(agent_names) do
    case Regex.run(@mention_pattern, text, return: :index) do
      nil ->
        {:plain, text}

      [{match_start, match_len} | _] ->
        name = binary_part(text, match_start + 1, match_len - 1)

        if name in agent_names do
          # Remove the @<name> token from the text and trim surrounding whitespace.
          rest =
            (binary_part(text, 0, match_start) <>
               binary_part(text, match_start + match_len, byte_size(text) - match_start - match_len))
            |> String.trim()

          {:mention, name, rest}
        else
          {:plain, text}
        end
    end
  end
end
```

- [ ] **Step 4 — Run passing tests.** Confirm all assertions pass.

```bash
cd runtime && mix test test/esr/entity/agent/mention_parser_test.exs 2>&1 | tail -5
```

- [ ] **Step 5 — Commit.**

```bash
git add runtime/lib/esr/entity/agent/mention_parser.ex \
        runtime/test/esr/entity/agent/mention_parser_test.exs
git commit -m "feat(agent): add MentionParser — @<name> mention detection (Phase 4.1)"
```

---

### Task 4.2: Inbound dispatch routing

**Files:**
- Modify: `runtime/lib/esr/entity/slash_handler.ex`
- Create: `runtime/test/esr/entity/slash_handler_mention_test.exs`

**Goal:** Non-slash plain-text messages flowing through `SlashHandler.dispatch/2` are inspected by `MentionParser`. If a mention is found, the stripped text is routed to the named agent's process. If no mention, route to the primary agent of the current session. Both routing paths use `GenServer.cast` to the target agent process resolved via `InstanceRegistry`.

- [ ] **Step 1 — Write failing test.** Create `runtime/test/esr/entity/slash_handler_mention_test.exs`:

```elixir
defmodule Esr.Entity.SlashHandler.MentionTest do
  use ExUnit.Case, async: false
  alias Esr.Entity.Agent.{InstanceRegistry, MentionParser}

  @sess "a1b2c3d4-e5f6-4a7b-8c9d-e0f1a2b3c4d5"

  setup do
    case Process.whereis(InstanceRegistry) do
      nil -> start_supervised!(InstanceRegistry)
      _ -> :ok
    end

    # Add two agents; alice is primary (first added).
    InstanceRegistry.add_instance(%{session_id: @sess, type: "cc", name: "alice", config: %{}})
    InstanceRegistry.add_instance(%{session_id: @sess, type: "cc", name: "bob", config: %{}})
    :ok
  end

  test "resolve_routing/2: plain text with no mention returns {:primary, primary_name}" do
    names = InstanceRegistry.names_for_session(@sess)
    {:ok, primary} = InstanceRegistry.primary(@sess)

    result = Esr.Entity.SlashHandler.resolve_routing("just some text", @sess)
    assert result == {:primary, primary}
  end

  test "resolve_routing/2: @alice mention returns {:mention, 'alice', stripped_text}" do
    result = Esr.Entity.SlashHandler.resolve_routing("@alice please help", @sess)
    assert result == {:mention, "alice", "please help"}
  end

  test "resolve_routing/2: @unknown mention falls back to primary" do
    {:ok, primary} = InstanceRegistry.primary(@sess)
    result = Esr.Entity.SlashHandler.resolve_routing("@unknown hello", @sess)
    assert result == {:primary, primary}
  end

  test "resolve_routing/2: lone @ falls back to primary" do
    {:ok, primary} = InstanceRegistry.primary(@sess)
    result = Esr.Entity.SlashHandler.resolve_routing("@ hello", @sess)
    assert result == {:primary, primary}
  end
end
```

- [ ] **Step 2 — Run failing tests.** Confirm `resolve_routing/2` is undefined.

```bash
cd runtime && mix test test/esr/entity/slash_handler_mention_test.exs 2>&1 | tail -10
```

- [ ] **Step 3 — Add `resolve_routing/2` to `SlashHandler`.** In `runtime/lib/esr/entity/slash_handler.ex`, add the following public function after the existing `dispatch/2,3` functions:

```elixir
  @doc """
  Resolve routing for a non-slash plain-text message within a session.

  Returns:
    * `{:mention, agent_name, stripped_text}` — an `@<name>` mention was
      found and `agent_name` is registered in the session.
    * `{:primary, primary_name}` — no matched mention; route to primary agent.
    * `{:error, :no_primary}` — no primary agent set for this session.

  Callers (FAA, future adapters) use this to decide which agent process
  to dispatch the cleaned message to.
  """
  @spec resolve_routing(String.t(), String.t()) ::
          {:mention, String.t(), String.t()}
          | {:primary, String.t()}
          | {:error, :no_primary}
  def resolve_routing(text, session_id)
      when is_binary(text) and is_binary(session_id) do
    agent_names = Esr.Entity.Agent.InstanceRegistry.names_for_session(session_id)

    case Esr.Entity.Agent.MentionParser.parse(text, agent_names) do
      {:mention, name, rest} ->
        {:mention, name, rest}

      {:plain, _} ->
        case Esr.Entity.Agent.InstanceRegistry.primary(session_id) do
          {:ok, primary} -> {:primary, primary}
          :not_found -> {:error, :no_primary}
        end
    end
  end
```

- [ ] **Step 4 — Run passing tests.**

```bash
cd runtime && mix test test/esr/entity/slash_handler_mention_test.exs 2>&1 | tail -5
```

- [ ] **Step 5 — Commit.**

```bash
git add runtime/lib/esr/entity/slash_handler.ex \
        runtime/test/esr/entity/slash_handler_mention_test.exs
git commit -m "feat(slash_handler): add resolve_routing/2 — @mention + primary fallback (Phase 4.2)"
```

---

### Task 4.3: `/session:set-primary` lifecycle integration

**Files:**
- Modify: `runtime/lib/esr/commands/session/set_primary.ex` (extend from Task 3.4)
- Modify: `runtime/test/esr/commands/session/set_primary_test.exs` (extend)

**Goal:** After `SetPrimary.execute/1` changes the primary in `InstanceRegistry`, the next plain-text message via `SlashHandler.resolve_routing/2` must route to the new primary. This test verifies the end-to-end wiring: `SetPrimary` → `InstanceRegistry` update → `resolve_routing` reads updated primary.

- [ ] **Step 1 — Write failing test.** Append to `runtime/test/esr/commands/session/set_primary_test.exs`:

```elixir
  describe "lifecycle: set_primary → resolve_routing routes to new primary" do
    test "next plain text routes to newly-set primary" do
      sess = "c3d4e5f6-a7b8-4c9d-0e1f-a2b3c4d5e6f7"
      alice = "routing-alice-#{:rand.uniform(9999)}"
      bob = "routing-bob-#{:rand.uniform(9999)}"

      Esr.Commands.Session.AddAgent.execute(%{
        "args" => %{"session_id" => sess, "type" => "cc", "name" => alice, "config" => %{}}
      })
      Esr.Commands.Session.AddAgent.execute(%{
        "args" => %{"session_id" => sess, "type" => "cc", "name" => bob, "config" => %{}}
      })

      # alice is primary (first added); plain text routes to alice.
      assert {:primary, ^alice} = Esr.Entity.SlashHandler.resolve_routing("hello", sess)

      # Promote bob.
      {:ok, _} = Esr.Commands.Session.SetPrimary.execute(%{
        "args" => %{"session_id" => sess, "name" => bob}
      })

      # Now plain text routes to bob.
      assert {:primary, ^bob} = Esr.Entity.SlashHandler.resolve_routing("hello again", sess)
    end
  end
```

- [ ] **Step 2 — Run failing tests.** Confirm the new test fails because `resolve_routing` still routes to alice.

```bash
cd runtime && mix test test/esr/commands/session/set_primary_test.exs 2>&1 | tail -10
```

- [ ] **Step 3 — Verify integration is already correct.** `SetPrimary.execute/1` calls `InstanceRegistry.set_primary/3` which updates ETS immediately; `resolve_routing/2` reads from ETS on every call. No further code changes needed — this is an integration test validating the wiring. If the test fails, check that `InstanceRegistry` is in the supervision tree and started before `SlashHandler`. If needed, ensure `SetPrimary` calls `InstanceRegistry.set_primary/2` (not the GenServer by name but via the public default server API).

- [ ] **Step 4 — Run passing tests.**

```bash
cd runtime && mix test test/esr/commands/session/set_primary_test.exs 2>&1 | tail -5
```

- [ ] **Step 5 — Commit.**

```bash
git add runtime/test/esr/commands/session/set_primary_test.exs
git commit -m "test(commands): set_primary lifecycle → resolve_routing routes to new primary (Phase 4.3)"
```

---

### Phase 4 PR checklist

Before opening the PR:

- [ ] Run full test suite: `cd runtime && mix test 2>&1 | tail -20`
- [ ] Confirm `MentionParser` handles `@esr-dev` (dash in name): the regex `[a-zA-Z0-9_-]+` includes `-`.
- [ ] Verify `SlashHandler.resolve_routing/2` is reachable from FAA/adapter layer: `grep -r "resolve_routing" runtime/lib/`

```bash
git commit -m "feat: mention parser + primary-agent routing on plain text (Phase 4)"
```

---

## Phase 5: Cap UUID translation — session: scheme + UUID-only contract

**PR title:** `feat: session cap UUID-only contract + output rendering (Phase 5)`
**Branch:** `feat/phase-5-session-cap-uuid`
**Target:** `dev`
**Est LOC:** ~300
**Depends on:** Phase 3 (Session.Registry, InstanceRegistry)

**Goal:** Enforce the D2+D5 contract: `session:<x>/...` caps accept **UUID only** at input — name input is rejected with a structured error. On the output side (rendering), UUID→name translation is added so humans see `session:<name>/<verb>` in `/cap:show`, `/cap:list`, `/cap:who-can` output.

---

### Task 5.1: `UuidTranslator` session: scheme — output-only

**Files:**
- Modify: `runtime/lib/esr/resource/capability/uuid_translator.ex`
- Modify: `runtime/test/esr/resource/capability/uuid_translator_test.exs` (extend or create)

**Constraint:** Do NOT add `session_name_to_uuid/1`. Session caps reject names entirely at input. Only `session_uuid_to_name/1` (output direction) is added.

- [ ] **Step 1 — Write failing test.** Append to (or create) `runtime/test/esr/resource/capability/uuid_translator_test.exs`:

```elixir
defmodule Esr.Resource.Capability.UuidTranslatorTest do
  use ExUnit.Case, async: true
  alias Esr.Resource.Capability.UuidTranslator

  @session_uuid "a1b2c3d4-e5f6-4a7b-8c9d-e0f1a2b3c4d5"

  describe "existing workspace name↔uuid — still works" do
    test "name_to_uuid passes through non-session non-workspace cap" do
      assert {:ok, "user.manage"} = UuidTranslator.name_to_uuid("user.manage")
    end

    test "uuid_to_name passes through non-scoped cap" do
      assert "runtime.deadletter" = UuidTranslator.uuid_to_name("runtime.deadletter")
    end
  end

  describe "validate_session_cap_input/1" do
    test "session cap with UUID is accepted" do
      cap = "session:#{@session_uuid}/attach"
      assert :ok = UuidTranslator.validate_session_cap_input(cap)
    end

    test "session cap with name (not UUID) is rejected" do
      assert {:error, {:session_name_in_cap, _msg}} =
               UuidTranslator.validate_session_cap_input("session:esr-dev/attach")
    end

    test "non-session cap passes through regardless of value" do
      assert :ok = UuidTranslator.validate_session_cap_input("workspace:my-ws/read")
      assert :ok = UuidTranslator.validate_session_cap_input("user.manage")
    end

    test "session cap with partial UUID rejected" do
      assert {:error, {:session_name_in_cap, _}} =
               UuidTranslator.validate_session_cap_input("session:not-a-uuid/end")
    end
  end

  describe "session_uuid_to_name/2 (output-only)" do
    test "unknown UUID returns UNKNOWN sentinel" do
      # Session.Registry not running in this unit test; :not_found expected.
      result = UuidTranslator.session_uuid_to_name(@session_uuid, %{})
      assert {:error, :not_found} = result
    end

    test "name_to_uuid does NOT translate session: names (no session_name_to_uuid)" do
      # Session name input should be rejected by validate_session_cap_input,
      # NOT silently translated. name_to_uuid leaves session: untouched.
      assert {:ok, "session:esr-dev/attach"} =
               UuidTranslator.name_to_uuid("session:esr-dev/attach")
    end
  end
end
```

- [ ] **Step 2 — Run failing tests.** Confirm `validate_session_cap_input/1` and `session_uuid_to_name/2` are undefined.

```bash
cd runtime && mix test test/esr/resource/capability/uuid_translator_test.exs 2>&1 | tail -10
```

- [ ] **Step 3 — Extend `UuidTranslator`.** Add the following to `runtime/lib/esr/resource/capability/uuid_translator.ex`:

```elixir
  @doc """
  Validate that a cap string containing `session:<x>/...` uses a UUID v4 for
  `<x>`. Name input is explicitly rejected for session caps (spec D2, D5).

  Non-session caps pass through as `:ok`.
  """
  @spec validate_session_cap_input(String.t()) ::
          :ok | {:error, {:session_name_in_cap, String.t()}}
  def validate_session_cap_input(cap) when is_binary(cap) do
    case Regex.run(~r{^session:([^/]+)/}, cap) do
      [_, value] ->
        if uuid_shape?(value) do
          :ok
        else
          {:error,
           {:session_name_in_cap,
            "session caps require UUID; name input is not accepted (got \"#{value}\")"}}
        end

      _ ->
        :ok
    end
  end

  @doc """
  Translate a session UUID to its human-readable name for **output rendering only**.

  This function is intentionally NOT called at input time. Session caps reject
  names entirely at input (use `validate_session_cap_input/1` at every entry
  point instead).

  Returns `{:ok, name}` when the session is found, or `{:error, :not_found}`
  when the UUID is not known (orphan cap — session was deleted).
  """
  @spec session_uuid_to_name(String.t(), map()) ::
          {:ok, String.t()} | {:error, :not_found}
  def session_uuid_to_name(uuid, _context) when is_binary(uuid) do
    case Esr.Resource.Session.Registry.get_session(uuid) do
      {:ok, session} -> {:ok, session.name}
      _ -> {:error, :not_found}
    end
  rescue
    _ -> {:error, :not_found}
  end
```

Also ensure `name_to_uuid/1` does NOT translate session names. Verify the existing implementation: the `@workspace_scoped_resources` list currently contains `"session"` — this was a pre-Phase-5 design that permitted name→UUID translation for sessions. **Remove `"session"` from `@workspace_scoped_resources`** so that `name_to_uuid/1` passes `session:<name>/...` through unchanged (input validation now lives in `validate_session_cap_input/1`):

```elixir
  # Only workspace caps accept name input. Session caps: UUID-only (D2, D5).
  @workspace_scoped_resources ~w(workspace)
```

- [ ] **Step 4 — Run passing tests.**

```bash
cd runtime && mix test test/esr/resource/capability/uuid_translator_test.exs 2>&1 | tail -5
```

- [ ] **Step 5 — Commit.**

```bash
git add runtime/lib/esr/resource/capability/uuid_translator.ex \
        runtime/test/esr/resource/capability/uuid_translator_test.exs
git commit -m "feat(cap): UuidTranslator — validate_session_cap_input + session_uuid_to_name output-only (Phase 5.1)"
```

---

### Task 5.2: Cap commands reject `session:<name>/<verb>`

**Files:**
- Modify: `runtime/lib/esr/commands/cap/grant.ex`
- Modify: `runtime/lib/esr/commands/cap/revoke.ex`
- Modify: `runtime/test/esr/commands/cap/grant_test.exs` (extend or create)
- Modify: `runtime/test/esr/commands/cap/revoke_test.exs` (extend or create)

**Goal:** `Grant.execute/1` and `Revoke.execute/1` call `validate_session_cap_input/1` before any translation, so `session:my-session/attach` is rejected at the command boundary.

- [ ] **Step 1 — Write failing tests.**

Append to (or create) `runtime/test/esr/commands/cap/grant_test.exs`:

```elixir
defmodule Esr.Commands.Cap.GrantTest do
  use ExUnit.Case, async: true
  alias Esr.Commands.Cap.Grant

  @session_uuid "a1b2c3d4-e5f6-4a7b-8c9d-e0f1a2b3c4d5"
  @user_id "user_linyilun"

  describe "session cap UUID-only enforcement" do
    test "grant session:<uuid>/attach succeeds (passes validation gate)" do
      cap = "session:#{@session_uuid}/attach"
      # Result is {:ok, _} or {:error, write_failed} depending on disk state;
      # the important assertion is: no session_cap_requires_uuid error.
      result = Grant.execute(%{"args" => %{"principal_id" => @user_id, "permission" => cap}})
      assert match?({:ok, _}, result) or match?({:error, %{"type" => "write_failed"}}, result)
      refute match?({:error, %{"type" => "session_cap_requires_uuid"}}, result)
    end

    test "grant session:<name>/attach is rejected with session_cap_requires_uuid" do
      cap = "session:esr-dev/attach"
      assert {:error, %{"type" => "session_cap_requires_uuid", "message" => msg}} =
               Grant.execute(%{"args" => %{"principal_id" => @user_id, "permission" => cap}})
      assert msg =~ "esr-dev"
    end

    test "grant workspace:<name>/read passes through unchanged (not affected by session guard)" do
      cap = "workspace:my-ws/read"
      result = Grant.execute(%{"args" => %{"principal_id" => @user_id, "permission" => cap}})
      # Either succeeds or write_failed — never session_cap_requires_uuid.
      refute match?({:error, %{"type" => "session_cap_requires_uuid"}}, result)
    end
  end
end
```

Append to (or create) `runtime/test/esr/commands/cap/revoke_test.exs`:

```elixir
defmodule Esr.Commands.Cap.RevokeTest do
  use ExUnit.Case, async: true
  alias Esr.Commands.Cap.Revoke

  @session_uuid "a1b2c3d4-e5f6-4a7b-8c9d-e0f1a2b3c4d5"
  @user_id "user_linyilun"

  describe "session cap UUID-only enforcement" do
    test "revoke session:<name>/attach is rejected with session_cap_requires_uuid" do
      cap = "session:esr-dev/attach"
      assert {:error, %{"type" => "session_cap_requires_uuid"}} =
               Revoke.execute(%{"args" => %{"principal_id" => @user_id, "permission" => cap}})
    end

    test "revoke session:<uuid>/attach passes UUID gate (may return no_matching_capability)" do
      cap = "session:#{@session_uuid}/attach"
      result = Revoke.execute(%{"args" => %{"principal_id" => @user_id, "permission" => cap}})
      refute match?({:error, %{"type" => "session_cap_requires_uuid"}}, result)
    end
  end
end
```

- [ ] **Step 2 — Run failing tests.** Confirm `session_cap_requires_uuid` error is not returned yet.

```bash
cd runtime && mix test test/esr/commands/cap/grant_test.exs \
                       test/esr/commands/cap/revoke_test.exs 2>&1 | tail -10
```

- [ ] **Step 3 — Add session validation to `Grant` and `Revoke`.** In `runtime/lib/esr/commands/cap/grant.ex`, replace the `execute/1` implementation with:

```elixir
  @spec execute(map()) :: result()
  def execute(%{"args" => %{"principal_id" => pid, "permission" => perm}})
      when is_binary(pid) and pid != "" and is_binary(perm) and perm != "" do
    with :ok <- validate_session_cap(perm),
         {:ok, translated_perm} <- Esr.Resource.Capability.UuidTranslator.name_to_uuid(perm) do
      do_grant(pid, translated_perm)
    else
      {:error, {:session_name_in_cap, msg}} ->
        {:error, %{"type" => "session_cap_requires_uuid", "message" => msg}}

      {:error, :unknown_workspace} ->
        {:error,
         %{
           "type" => "unknown_workspace",
           "message" => "no workspace found in capability scope: #{perm}"
         }}
    end
  end

  def execute(_cmd) do
    {:error,
     %{
       "type" => "invalid_args",
       "message" =>
         "grant requires args.principal_id and args.permission (non-empty strings)"
     }}
  end

  defp validate_session_cap(perm) do
    Esr.Resource.Capability.UuidTranslator.validate_session_cap_input(perm)
  end
```

Apply the same `with :ok <- validate_session_cap(perm)` guard to `runtime/lib/esr/commands/cap/revoke.ex` `execute/1`:

```elixir
  @spec execute(map()) :: result()
  def execute(%{"args" => %{"principal_id" => pid, "permission" => perm}})
      when is_binary(pid) and pid != "" and is_binary(perm) and perm != "" do
    with :ok <- validate_session_cap(perm),
         {:ok, translated_perm} <- Esr.Resource.Capability.UuidTranslator.name_to_uuid(perm) do
      do_revoke(pid, translated_perm)
    else
      {:error, {:session_name_in_cap, msg}} ->
        {:error, %{"type" => "session_cap_requires_uuid", "message" => msg}}

      {:error, :unknown_workspace} ->
        {:error,
         %{
           "type" => "unknown_workspace",
           "message" => "no workspace found in capability scope: #{perm}"
         }}
    end
  end

  def execute(_cmd) do
    {:error,
     %{
       "type" => "invalid_args",
       "message" =>
         "revoke requires args.principal_id and args.permission (non-empty strings)"
     }}
  end

  defp validate_session_cap(perm) do
    Esr.Resource.Capability.UuidTranslator.validate_session_cap_input(perm)
  end
```

- [ ] **Step 4 — Run passing tests.**

```bash
cd runtime && mix test test/esr/commands/cap/grant_test.exs \
                       test/esr/commands/cap/revoke_test.exs 2>&1 | tail -5
```

- [ ] **Step 5 — Commit.**

```bash
git add runtime/lib/esr/commands/cap/grant.ex \
        runtime/lib/esr/commands/cap/revoke.ex \
        runtime/test/esr/commands/cap/grant_test.exs \
        runtime/test/esr/commands/cap/revoke_test.exs
git commit -m "feat(cap): grant/revoke reject session:<name>/... — UUID-only enforcement (Phase 5.2)"
```

---

### Task 5.3: Cap output rendering — session UUID→name

**Files:**
- Modify: `runtime/lib/esr/commands/cap/show.ex`
- Modify: `runtime/lib/esr/commands/cap/list.ex`
- Modify: `runtime/lib/esr/commands/cap/who_can.ex`
- Create: `runtime/test/esr/commands/cap/output_rendering_test.exs`

**Goal:** When a cap string contains `session:<uuid>/...`, the display output shows `session:<name>/<verb> (uuid: <uuid>)` if the session is found, or `session:<UNKNOWN-<prefix>>/<verb>` if the session is gone (orphan). This is output-only — it does NOT relax the input rejection in Task 5.2.

- [ ] **Step 1 — Write failing test.** Create `runtime/test/esr/commands/cap/output_rendering_test.exs`:

```elixir
defmodule Esr.Commands.Cap.OutputRenderingTest do
  use ExUnit.Case, async: true
  alias Esr.Resource.Capability.UuidTranslator

  @session_uuid "a1b2c3d4-e5f6-4a7b-8c9d-e0f1a2b3c4d5"

  describe "render_cap_for_display/1" do
    test "workspace cap with known UUID renders as name" do
      # Workspace name resolution is already tested in uuid_translator tests;
      # this test only ensures the function exists.
      cap = "workspace:#{@session_uuid}/read"
      result = UuidTranslator.render_cap_for_display(cap)
      assert is_binary(result)
    end

    test "session cap with unknown UUID shows UNKNOWN sentinel" do
      cap = "session:#{@session_uuid}/attach"
      result = UuidTranslator.render_cap_for_display(cap)
      # Session.Registry not running → :not_found → UNKNOWN sentinel.
      assert result =~ "UNKNOWN" or result =~ @session_uuid
    end

    test "non-scoped cap passes through unchanged" do
      cap = "user.manage"
      assert "user.manage" = UuidTranslator.render_cap_for_display(cap)
    end

    test "session cap with UUID renders with (uuid: ...) annotation or UNKNOWN" do
      cap = "session:#{@session_uuid}/end"
      result = UuidTranslator.render_cap_for_display(cap)
      # Either "session:<name>/end (uuid: <uuid>)" or "session:<UNKNOWN-...>/end"
      assert is_binary(result)
      assert result =~ "session:"
    end
  end
end
```

- [ ] **Step 2 — Run failing tests.** Confirm `render_cap_for_display/1` is undefined.

```bash
cd runtime && mix test test/esr/commands/cap/output_rendering_test.exs 2>&1 | tail -10
```

- [ ] **Step 3 — Add `render_cap_for_display/1` to `UuidTranslator` and wire into Show/List/WhoCan.**

Add to `runtime/lib/esr/resource/capability/uuid_translator.ex`:

```elixir
  @doc """
  Render a cap string for human-readable output.

  * `workspace:<uuid>/...` → `workspace:<name>/...` (via NameIndex; unchanged if not found)
  * `session:<uuid>/...` → `session:<name>/... (uuid: <uuid>)` if session found,
    else `session:<UNKNOWN-<8-char-prefix>>/...`
  * All other caps → unchanged.
  """
  @spec render_cap_for_display(String.t()) :: String.t()
  def render_cap_for_display(cap) when is_binary(cap) do
    case parse(cap) do
      {:scoped, "session", uuid, perm} ->
        if uuid_shape?(uuid) do
          case session_uuid_to_name(uuid, %{}) do
            {:ok, name} ->
              "session:#{name}/#{perm} (uuid: #{uuid})"

            {:error, :not_found} ->
              "session:<UNKNOWN-#{String.slice(uuid, 0, 8)}>/#{perm}"
          end
        else
          cap
        end

      {:scoped, "workspace", uuid, perm} ->
        if uuid_shape?(uuid) do
          case NameIndex.name_for_id(uuid) do
            {:ok, name} -> "workspace:#{name}/#{perm}"
            :not_found -> "workspace:<UNKNOWN-#{String.slice(uuid, 0, 8)}>/#{perm}"
          end
        else
          cap
        end

      _ ->
        cap
    end
  end
```

Update `runtime/lib/esr/commands/cap/show.ex` — replace `uuid_to_name/1` call with `render_cap_for_display/1` in the `render_entry/1` helper:

```elixir
  defp render_entry(entry) do
    caps =
      (entry["capabilities"] || [])
      |> Enum.map(&Esr.Resource.Capability.UuidTranslator.render_cap_for_display/1)

    base = "id: #{entry["id"]}\nkind: #{entry["kind"] || ""}"
    note = if entry["note"] in [nil, ""], do: "", else: "\nnote: #{inspect(entry["note"])}"

    cap_lines =
      caps
      |> Enum.map(&"  - #{&1}")
      |> Enum.join("\n")

    cap_block = if cap_lines == "", do: "\ncapabilities: []", else: "\ncapabilities:\n#{cap_lines}"

    base <> note <> cap_block
  end
```

Update `runtime/lib/esr/commands/cap/list.ex` and `runtime/lib/esr/commands/cap/who_can.ex` — replace any calls to `UuidTranslator.uuid_to_name/1` with `UuidTranslator.render_cap_for_display/1`:

```bash
# Verify call sites before editing:
grep -n "uuid_to_name" runtime/lib/esr/commands/cap/list.ex runtime/lib/esr/commands/cap/who_can.ex
```

- [ ] **Step 4 — Run passing tests.**

```bash
cd runtime && mix test test/esr/commands/cap/output_rendering_test.exs \
                       test/esr/commands/cap/grant_test.exs \
                       test/esr/commands/cap/ 2>&1 | tail -5
```

- [ ] **Step 5 — Commit.**

```bash
git add runtime/lib/esr/resource/capability/uuid_translator.ex \
        runtime/lib/esr/commands/cap/show.ex \
        runtime/lib/esr/commands/cap/list.ex \
        runtime/lib/esr/commands/cap/who_can.ex \
        runtime/test/esr/commands/cap/output_rendering_test.exs
git commit -m "feat(cap): render_cap_for_display — session UUID→name output rendering + UNKNOWN sentinel (Phase 5.3)"
```

---

### Phase 5 PR checklist

Before opening the PR:

- [ ] Run full test suite: `cd runtime && mix test 2>&1 | tail -20`
- [ ] Confirm no `session_name_to_uuid` function exists anywhere: `grep -r "session_name_to_uuid" runtime/lib/`
- [ ] Confirm `validate_session_cap_input` is called in both `grant.ex` and `revoke.ex`: `grep -n "validate_session_cap" runtime/lib/esr/commands/cap/grant.ex runtime/lib/esr/commands/cap/revoke.ex`
- [ ] Confirm `render_cap_for_display` is the sole rendering path in `show.ex`, `list.ex`, `who_can.ex`: `grep -n "uuid_to_name" runtime/lib/esr/commands/cap/`

```bash
git commit -m "feat: session cap UUID-only contract + output rendering (Phase 5)"
```

---

## Phase 6: Colon-namespace slash cutover

**PR title:** `feat: colon-namespace slash cutover — hard cutover, /session:* family, /pty:key (Phase 6)`
**Branch:** `feat/phase-6-colon-namespace`
**Target:** `dev`
**Est LOC:** ~1200
**Depends on:** Phase 1b (user UUID), Phase 3 (Session command modules), Phase 5 (cap UUID enforcement)

**Goal:** Rename every slash command to colon-namespace form in one hard-cutover PR. No aliases survive.
Drop `/workspace:sessions`. Rename `/key` → `/pty:key`. Add the full `/session:*`, `/pty:*`, and `/cap:*` families
(routing entries only; command modules for session:* were implemented in Phase 3). Add `/plugin:set`,
`/plugin:unset`, `/plugin:show-config`, `/plugin:list-config` routing stubs (command modules land in Phase 7).
Patch `slash_handler.ex` with a `@deprecated_slashes` hint map so operators get a clear "use X instead"
message rather than a generic "unknown command". Update `/help` grouping to colon-prefix headers.
Test sweep: update all test files that reference old slash literals.

> **Spec §4 Rule 5 (authoritative):** `/key` → `/pty:key`. The absorbed `spec/colon-namespace-grammar`
> inventory table incorrectly mapped it to `/session:key`; the main spec rev-2 §4 locks this as `/pty:key`.
> Follow the main spec.

---

### Task 6.1: Validate matcher accepts colon-form names (registry smoke test)

**Files:**
- Read: `runtime/lib/esr/resource/slash_route/registry.ex` (lines 296-317)
- Read: `runtime/lib/esr/resource/slash_route/file_loader.ex`
- Create (then delete): scratch test to confirm colon keys route correctly
- Extend: `runtime/test/esr/resource/slash_route/registry_test.exs` with colon-form key cases

**Analysis:** `slash_head/1` splits on `\s+` (whitespace), so `/session:new` is treated as a single
opaque token — the colon is transparent to the matcher. `keys_in_text/1` also splits on whitespace, so
`/session:new name=foo` produces candidates `["/session:new name=foo", "/session:new"]` — correct.
`file_loader.ex`'s `validate_slash_key/1` only checks that the key starts with `/`; colon-form passes.
**Conclusion:** zero logic changes required. This task only adds a failing-then-passing regression test.

- [ ] **Step 1 — Write failing test.** Add to `runtime/test/esr/resource/slash_route/registry_test.exs`:

```elixir
# Task 6.1 — colon-form matcher regression
describe "colon-form slash key matching" do
  test "colon-form key inserted directly resolves via lookup/1" do
    # Load a synthetic route map with a colon-form key.
    route = %{
      slash: "/session:new",
      kind: "session_new",
      permission: "session:default/create",
      command_module: "Esr.Commands.Session.New",
      requires_workspace_binding: false,
      requires_user_binding: true,
      category: "Sessions",
      description: "test",
      args: []
    }

    # Insert directly into the slash table (bypasses yaml loader).
    :ets.insert(:slash_routes, {"/session:new", route})

    assert {:ok, found} = Esr.Resource.SlashRoute.Registry.lookup("/session:new name=test")
    assert found.slash == "/session:new"
    assert found.kind == "session_new"
  end

  test "colon-form key with trailing args resolves to the colon key" do
    route = %{
      slash: "/workspace:list",
      kind: "workspace_list",
      permission: "session.list",
      command_module: "Esr.Commands.Workspace.List",
      requires_workspace_binding: false,
      requires_user_binding: true,
      category: "Workspace",
      description: "test",
      args: []
    }

    :ets.insert(:slash_routes, {"/workspace:list", route})

    assert {:ok, found} = Esr.Resource.SlashRoute.Registry.lookup("/workspace:list")
    assert found.slash == "/workspace:list"
  end

  test "old space-separated form does NOT match colon-form key" do
    # After yaml cutover the old form "/workspace list" must not match.
    # Here we verify that a lookup for "/workspace list" returns :not_found
    # when only "/workspace:list" is in the table.
    :ets.delete(:slash_routes, "/workspace list")

    assert :not_found = Esr.Resource.SlashRoute.Registry.lookup("/workspace list")
  end
end
```

- [ ] **Step 2 — Run failing test.**

```bash
cd runtime && mix test test/esr/resource/slash_route/registry_test.exs --only "colon-form" 2>&1 | tail -15
```

The third sub-test may fail because `/workspace list` might already be absent. The first two should fail
with ETS key not found — the test is inserting into ETS directly; confirm the table name matches the
registry's `@slash_table`. If the table is named differently, read `registry.ex` lines 1-30 to find
`@slash_table` value and update the test accordingly.

- [ ] **Step 3 — Verify no logic change needed.**

```bash
grep -n "@slash_table\|@kind_table\|keys_in_text\|slash_head\|validate_slash_key" \
  runtime/lib/esr/resource/slash_route/registry.ex \
  runtime/lib/esr/resource/slash_route/file_loader.ex
```

Confirm `validate_slash_key/1` only checks `String.starts_with?(key, "/")`. If it validates against a
character whitelist that excludes colons, patch it to allow `[a-z0-9:_-]` after the `/`. Otherwise no
patch needed.

- [ ] **Step 4 — Run passing tests.**

```bash
cd runtime && mix test test/esr/resource/slash_route/registry_test.exs 2>&1 | tail -10
```

- [ ] **Step 5 — Commit.**

```bash
git add runtime/test/esr/resource/slash_route/registry_test.exs
git commit -m "test(slash): colon-form matcher regression — confirm no logic change needed (Phase 6.1)"
```

---

### Task 6.2: Rewrite `slash-routes.default.yaml` — full colon-namespace inventory

**Files:**
- Modify: `runtime/priv/slash-routes.default.yaml`
- Extend: `runtime/test/esr/resource/slash_route/registry_test.exs` (full load test)

**Mapping (from spec §4, rev-2 authoritative):**

| Old key | New key |
|---|---|
| `/whoami` | `/user:whoami` |
| `/key` | `/pty:key` |
| `/new-workspace` | `/workspace:new` |
| `/workspace list` | `/workspace:list` |
| `/workspace edit` | `/workspace:edit` |
| `/workspace add-folder` | `/workspace:add-folder` |
| `/workspace remove-folder` | `/workspace:remove-folder` |
| `/workspace bind-chat` | `/workspace:bind-chat` |
| `/workspace unbind-chat` | `/workspace:unbind-chat` |
| `/workspace remove` | `/workspace:remove` |
| `/workspace rename` | `/workspace:rename` |
| `/workspace use` | `/workspace:use` |
| `/workspace import-repo` | `/workspace:import-repo` |
| `/workspace forget-repo` | `/workspace:forget-repo` |
| `/workspace info` | `/workspace:info` |
| `/workspace describe` | `/workspace:describe` |
| `/workspace sessions` | **DELETED** (Rule 6 — workspace must not depend on session) |
| `/sessions` | `/session:list` |
| `/new-session` | `/session:new` |
| `/end-session` | `/session:end` |
| `/list-agents` | `/agent:list` |
| `/actors` | `/actor:list` |
| `/attach` | `/session:attach` |
| `/plugin list` | `/plugin:list` |
| `/plugin info` | `/plugin:info` |
| `/plugin install` | `/plugin:install` |
| `/plugin enable` | `/plugin:enable` |
| `/plugin disable` | `/plugin:disable` |

**Aliases removed:** `/list-sessions`, `/session new`, `/session end`, `/list-actors` (all `aliases:` fields deleted).

**New entries added (§4.B — `/session:*` family):**

```
/session:new            kind: session_new      → Esr.Commands.Session.New
/session:attach         kind: session_attach   → Esr.Commands.Session.Attach
/session:detach         kind: session_detach   → Esr.Commands.Session.Detach
/session:end            kind: session_end      → Esr.Commands.Session.End
/session:list           kind: session_list     → Esr.Commands.Session.List
/session:add-agent      kind: session_add_agent → Esr.Commands.Session.AddAgent
/session:remove-agent   kind: session_remove_agent → Esr.Commands.Session.RemoveAgent
/session:set-primary    kind: session_set_primary → Esr.Commands.Session.SetPrimary
/session:bind-workspace kind: session_bind_workspace → Esr.Commands.Session.BindWorkspace
/session:share          kind: session_share    → Esr.Commands.Session.Share
/session:info           kind: session_info     → Esr.Commands.Session.Info
```

**New entries added (§4.C — `/pty:*` family):**

```
/pty:key    kind: pty_key    → Esr.Commands.Pty.Key
```

**New entries added (§4.D — `/plugin:*` config management, Phase 7 commands):**

```
/plugin:set         kind: plugin_set         → Esr.Commands.Plugin.Set
/plugin:unset       kind: plugin_unset       → Esr.Commands.Plugin.Unset
/plugin:show-config kind: plugin_show_config → Esr.Commands.Plugin.ShowConfig
/plugin:list-config kind: plugin_list_config → Esr.Commands.Plugin.ListConfig
```

**New entries added (§4.E — `/cap:*` family):**

```
/cap:grant   kind: cap_grant   → Esr.Commands.Cap.Grant
/cap:revoke  kind: cap_revoke  → Esr.Commands.Cap.Revoke
```

**Also update `/user:whoami`** kind from `whoami` → `user_whoami` (colon namespace alignment).

- [ ] **Step 1 — Write failing test.** Add to `runtime/test/esr/resource/slash_route/registry_test.exs`:

```elixir
describe "Phase 6 — full colon-form yaml load" do
  @colon_slashes [
    "/help", "/doctor",
    "/user:whoami",
    "/pty:key",
    "/workspace:new", "/workspace:list", "/workspace:edit",
    "/workspace:add-folder", "/workspace:remove-folder",
    "/workspace:bind-chat", "/workspace:unbind-chat",
    "/workspace:remove", "/workspace:rename", "/workspace:use",
    "/workspace:import-repo", "/workspace:forget-repo",
    "/workspace:info", "/workspace:describe",
    "/session:new", "/session:attach", "/session:detach",
    "/session:end", "/session:list", "/session:add-agent",
    "/session:remove-agent", "/session:set-primary",
    "/session:bind-workspace", "/session:share", "/session:info",
    "/agent:list", "/actor:list",
    "/plugin:list", "/plugin:info", "/plugin:install",
    "/plugin:enable", "/plugin:disable",
    "/plugin:set", "/plugin:unset", "/plugin:show-config",
    "/plugin:list-config",
    "/cap:grant", "/cap:revoke"
  ]

  @old_slashes [
    "/whoami", "/key", "/new-workspace", "/workspace list",
    "/workspace info", "/sessions", "/new-session", "/end-session",
    "/list-agents", "/actors", "/attach", "/plugin list",
    "/workspace sessions"
  ]

  test "all colon-form slash keys resolve" do
    Enum.each(@colon_slashes, fn slash ->
      assert {:ok, route} = Esr.Resource.SlashRoute.Registry.lookup(slash),
             "expected #{slash} to resolve, got :not_found"
      assert is_binary(route.kind), "route.kind must be a string for #{slash}"
    end)
  end

  test "old-form slash keys do not resolve" do
    Enum.each(@old_slashes, fn slash ->
      assert :not_found = Esr.Resource.SlashRoute.Registry.lookup(slash),
             "expected #{slash} to return :not_found after cutover"
    end)
  end

  test "/workspace:sessions is absent (Rule 6)" do
    assert :not_found = Esr.Resource.SlashRoute.Registry.lookup("/workspace:sessions")
  end

  test "every command_module in slash entries is loadable" do
    slashes = Esr.Resource.SlashRoute.Registry.list_slashes()

    Enum.each(slashes, fn route ->
      mod_str = route[:command_module] || route.command_module
      mod = Module.concat([mod_str])

      assert Code.ensure_loaded?(mod),
             "command_module #{mod_str} for #{route.slash} is not loadable"
    end)
  end
end
```

- [ ] **Step 2 — Run failing test.**

```bash
cd runtime && mix test test/esr/resource/slash_route/registry_test.exs --only "Phase 6" 2>&1 | tail -20
```

Expect failures on the colon-form keys (not yet in yaml) and old-form keys still present.

- [ ] **Step 3 — Rewrite the yaml.** Replace the content of `runtime/priv/slash-routes.default.yaml`
with the full colon-namespace inventory. Key structural changes:

  1. Remove ALL `aliases:` fields from every entry.
  2. Rename every `slashes:` key per the mapping table above.
  3. Delete the `/workspace sessions` entry entirely.
  4. Rename `/key` → `/pty:key`; update `kind: key` → `kind: pty_key`.
  5. Rename `/whoami` → `/user:whoami`; update `kind: whoami` → `kind: user_whoami`.
  6. Rename `/sessions` → `/session:list`; update kind to `session_list`.
  7. Rename `/new-session` → `/session:new`; update kind to `session_new`; update `command_module` to
     `"Esr.Commands.Session.New"` (Phase 3 module).
  8. Rename `/end-session` → `/session:end`; update kind to `session_end`; update `command_module` to
     `"Esr.Commands.Session.End"`.
  9. Rename `/attach` → `/session:attach`; update kind to `session_attach`; update `command_module` to
     `"Esr.Commands.Session.Attach"`.
  10. Rename `/list-agents` → `/agent:list`; update kind to `agent_list`.
  11. Rename `/actors` → `/actor:list`; update kind to `actor_list`.
  12. Rename `/plugin list|info|install|enable|disable` → `/plugin:list|info|install|enable|disable`.
  13. Add all new `/session:*` entries (detach, add-agent, remove-agent, set-primary, bind-workspace,
      share, info) referencing Phase 3 command modules.
  14. Add `/pty:key` entry (replaces `/key` entirely).
  15. Add `/plugin:set`, `/plugin:unset`, `/plugin:show-config`, `/plugin:list-config` entries
      (command modules implemented in Phase 7; declare here so routing is complete before Phase 7 lands).
  16. Add `/cap:grant` and `/cap:revoke` as slash entries (previously internal_kinds only; Phase 6
      adds the slash-callable form while keeping the `cap_grant`/`cap_revoke` internal_kinds untouched
      for the escript path).

  Full yaml for new `/session:*` entries (reference for implementor):

  ```yaml
  "/session:new":
    kind: session_new
    permission: "session:default/create"
    command_module: "Esr.Commands.Session.New"
    requires_workspace_binding: false
    requires_user_binding: true
    category: "Sessions"
    description: "创建 session + 自动 transient workspace；auto-attach 到当前 chat；设 attached-current"
    args:
      - { name: name, required: false }
      - { name: worktree, required: false }
      - { name: workspace, required: false }

  "/session:attach":
    kind: session_attach
    permission: "session:default/attach"
    command_module: "Esr.Commands.Session.Attach"
    requires_workspace_binding: false
    requires_user_binding: true
    category: "Sessions"
    description: "加入已有 session（仅 UUID）；设 attached-current。跨用户需 session:<uuid>/attach cap"
    args:
      - { name: session, required: true }

  "/session:detach":
    kind: session_detach
    permission: null
    command_module: "Esr.Commands.Session.Detach"
    requires_workspace_binding: false
    requires_user_binding: false
    category: "Sessions"
    description: "离开当前 chat 的 attached session；不结束 session"
    args: []

  "/session:end":
    kind: session_end
    permission: "session:default/end"
    command_module: "Esr.Commands.Session.End"
    requires_workspace_binding: false
    requires_user_binding: true
    category: "Sessions"
    description: "结束 session；worktree 干净则自动 prune transient workspace"
    args:
      - { name: session, required: false }

  "/session:list":
    kind: session_list
    permission: "session.list"
    command_module: "Esr.Commands.Session.List"
    requires_workspace_binding: false
    requires_user_binding: true
    category: "Sessions"
    description: "列当前 chat 的 sessions：name/UUID/agent 数/attached-current 状态/workspace"
    args: []

  "/session:add-agent":
    kind: session_add_agent
    permission: "session:default/add-agent"
    command_module: "Esr.Commands.Session.AddAgent"
    requires_workspace_binding: false
    requires_user_binding: true
    category: "Sessions"
    description: "向当前 session 添加 agent 实例；name 须全局唯一"
    args:
      - { name: type, required: true }
      - { name: name, required: true }

  "/session:remove-agent":
    kind: session_remove_agent
    permission: "session:default/add-agent"
    command_module: "Esr.Commands.Session.RemoveAgent"
    requires_workspace_binding: false
    requires_user_binding: true
    category: "Sessions"
    description: "从当前 session 删除 agent；不能删 primary（需先 set-primary 到其他 agent）"
    args:
      - { name: name, required: true }

  "/session:set-primary":
    kind: session_set_primary
    permission: "session:default/add-agent"
    command_module: "Esr.Commands.Session.SetPrimary"
    requires_workspace_binding: false
    requires_user_binding: true
    category: "Sessions"
    description: "设当前 session 的 primary agent（接收无 @ 前缀的纯文本）"
    args:
      - { name: name, required: true }

  "/session:bind-workspace":
    kind: session_bind_workspace
    permission: "session:default/end"
    command_module: "Esr.Commands.Session.BindWorkspace"
    requires_workspace_binding: false
    requires_user_binding: true
    category: "Sessions"
    description: "把 session 的 workspace 从 auto-transient 改绑到已命名 workspace"
    args:
      - { name: name, required: true }

  "/session:share":
    kind: session_share
    permission: "session:default/share"
    command_module: "Esr.Commands.Session.Share"
    requires_workspace_binding: false
    requires_user_binding: true
    category: "Sessions"
    description: "授权指定用户访问 session；仅 UUID 识别；perm=attach|admin（默认 attach）"
    args:
      - { name: session, required: true }
      - { name: user, required: true }
      - { name: perm, required: false, default: "attach" }

  "/session:info":
    kind: session_info
    permission: "session.list"
    command_module: "Esr.Commands.Session.Info"
    requires_workspace_binding: false
    requires_user_binding: true
    category: "Sessions"
    description: "显示 session 详情：id/name/owner/workspace/agents/primary/attached chats/创建时间/transient"
    args:
      - { name: session, required: false }

  "/pty:key":
    kind: pty_key
    permission: null
    command_module: "Esr.Commands.Pty.Key"
    requires_workspace_binding: false
    requires_user_binding: false
    category: "PTY"
    description: "把特殊键盘输入（up/down/enter/esc/tab/c-X 等）发到 chat-current session 的 PTY"
    args:
      - { name: keys, required: true }

  "/plugin:set":
    kind: plugin_set
    permission: "plugin/manage"
    command_module: "Esr.Commands.Plugin.Set"
    requires_workspace_binding: false
    requires_user_binding: false
    category: "Plugins"
    description: "设置 plugin 配置项（须在 manifest config_schema 中声明）；layer=global|user|workspace（默认 global）"
    args:
      - { name: plugin, required: true }
      - { name: key, required: true }
      - { name: value, required: true }
      - { name: layer, required: false, default: "global" }

  "/plugin:unset":
    kind: plugin_unset
    permission: "plugin/manage"
    command_module: "Esr.Commands.Plugin.Unset"
    requires_workspace_binding: false
    requires_user_binding: false
    category: "Plugins"
    description: "删除 plugin 某层的配置项（幂等）；layer=global|user|workspace（默认 global）"
    args:
      - { name: plugin, required: true }
      - { name: key, required: true }
      - { name: layer, required: false, default: "global" }

  "/plugin:show-config":
    kind: plugin_show_config
    permission: "plugin/manage"
    command_module: "Esr.Commands.Plugin.ShowConfig"
    requires_workspace_binding: false
    requires_user_binding: false
    category: "Plugins"
    description: "显示 plugin 配置；layer=effective|global|user|workspace（默认 effective）"
    args:
      - { name: plugin, required: true }
      - { name: layer, required: false, default: "effective" }

  "/plugin:list-config":
    kind: plugin_list_config
    permission: "plugin/manage"
    command_module: "Esr.Commands.Plugin.ListConfig"
    requires_workspace_binding: false
    requires_user_binding: false
    category: "Plugins"
    description: "显示所有已启用 plugin 的 effective 配置"
    args: []

  "/cap:grant":
    kind: cap_grant
    permission: "cap.manage"
    command_module: "Esr.Commands.Cap.Grant"
    requires_workspace_binding: false
    requires_user_binding: false
    category: "Capabilities"
    description: "授权 cap 给用户；session cap 仅接受 UUID 形式"
    args:
      - { name: cap, required: true }
      - { name: user, required: true }

  "/cap:revoke":
    kind: cap_revoke
    permission: "cap.manage"
    command_module: "Esr.Commands.Cap.Revoke"
    requires_workspace_binding: false
    requires_user_binding: false
    category: "Capabilities"
    description: "撤销用户的 cap；session cap 仅接受 UUID 形式"
    args:
      - { name: cap, required: true }
      - { name: user, required: true }
  ```

  Also add `"Capabilities"` to `category_order/1` in `help.ex` (Task 6.4).

  **Also update `internal_kinds:`**: The `cap_grant` and `cap_revoke` internal kinds remain (escript path
  still uses them). No removal needed — the same kind name is shared by both the slash entry and the
  internal_kind entry; the Registry handles this correctly (slash table and kind table are separate ETS
  tables). If there is a duplicate-kind conflict, add a comment explaining the dual registration.

- [ ] **Step 4 — Run passing tests.**

```bash
cd runtime && mix test test/esr/resource/slash_route/registry_test.exs 2>&1 | tail -10
```

The `command_module loadable` test will fail for Phase-7-only command modules
(`Esr.Commands.Plugin.Set`, `Esr.Commands.Plugin.Unset`, etc.) that don't exist yet.
**Handle this** by marking those yaml entries with a `# phase: 7` comment and wrapping the
loadability assertion in the test to skip modules in a `@phase_7_modules` list:

```elixir
@phase_7_modules [
  "Esr.Commands.Plugin.Set",
  "Esr.Commands.Plugin.Unset",
  "Esr.Commands.Plugin.ShowConfig",
  "Esr.Commands.Plugin.ListConfig"
]

test "every command_module in slash entries is loadable" do
  slashes = Esr.Resource.SlashRoute.Registry.list_slashes()

  Enum.each(slashes, fn route ->
    mod_str = route[:command_module] || route.command_module

    unless mod_str in @phase_7_modules do
      mod = Module.concat([mod_str])

      assert Code.ensure_loaded?(mod),
             "command_module #{mod_str} for #{route.slash} is not loadable"
    end
  end)
end
```

- [ ] **Step 5 — Commit.**

```bash
git add runtime/priv/slash-routes.default.yaml \
        runtime/test/esr/resource/slash_route/registry_test.exs
git commit -m "feat(slash): hard-cutover to colon-namespace — yaml rewrite + new session/pty/cap/plugin entries (Phase 6.2)"
```

---

### Task 6.3: `slash_handler.ex` — deprecated-slash hint map + `pty_key` routing

**Files:**
- Modify: `runtime/lib/esr/entity/slash_handler.ex`
- Extend: `runtime/test/esr/entity/slash_handler_test.exs` (or equivalent integration test)

**Analysis:** The dispatcher already works for colon-form keys — the ETS lookup is key-based and the
`slash_head/1` function treats `/session:new` as a single token. Two changes are needed:

1. The `:not_found` branch currently emits `"unknown command: /old-form"`. Spec §4 Rule 1 says hard
   cutover with no aliases, but operators will type old forms. Add a `@deprecated_slashes` hint map that
   returns a structured "renamed to X" message for known old forms. This is NOT routing — it is an error
   message enhancement.

2. The `merge_chat_context/2` clause for `"key"` must be updated to `"pty_key"` (kind changed in yaml).

- [ ] **Step 1 — Write failing test.**

```elixir
# In slash_handler integration test:
test "old-form /new-session returns deprecated hint, not unknown command" do
  envelope = %{
    "principal_id" => "ou_test",
    "payload" => %{"text" => "/new-session name=foo"}
  }

  ref = make_ref()
  # Dispatch and capture the reply.
  SlashHandler.dispatch(envelope, self(), ref)

  assert_receive {:reply, result, ^ref}, 1000

  text = case result do
    {:text, t} -> t
    {:ok, %{"text" => t}} -> t
    other -> inspect(other)
  end

  assert String.contains?(text, "/session:new") or String.contains?(text, "renamed"),
         "expected deprecated hint mentioning /session:new, got: #{text}"
end

test "old-form /workspace info returns deprecated hint" do
  envelope = %{
    "principal_id" => "ou_test",
    "payload" => %{"text" => "/workspace info"}
  }

  ref = make_ref()
  SlashHandler.dispatch(envelope, self(), ref)

  assert_receive {:reply, result, ^ref}, 1000

  text = case result do
    {:text, t} -> t
    {:ok, %{"text" => t}} -> t
    other -> inspect(other)
  end

  assert String.contains?(text, "/workspace:info"),
         "expected hint /workspace:info, got: #{text}"
end
```

- [ ] **Step 2 — Run failing test.**

```bash
cd runtime && mix test test/esr/entity/slash_handler_test.exs 2>&1 | tail -15
```

- [ ] **Step 3 — Implement.** In `slash_handler.ex`:

  **3a.** Add module attribute `@deprecated_slashes` immediately before `handle_cast/2`:

  ```elixir
  # Phase 6 — hard-cutover hint map. Fires only when the registry lookup
  # returns :not_found for a text whose head (or two-token head) matches a
  # known old-form name. Returns a structured "renamed" error so operators
  # get a clear message. This map is NOT routing — old forms are dead.
  # Removal: separate PR after operators have migrated.
  @deprecated_slashes %{
    "/new-session"              => "/session:new",
    "/end-session"              => "/session:end",
    "/sessions"                 => "/session:list",
    "/list-sessions"            => "/session:list",
    "/attach"                   => "/session:attach",
    "/whoami"                   => "/user:whoami",
    "/key"                      => "/pty:key",
    "/new-workspace"            => "/workspace:new",
    "/list-agents"              => "/agent:list",
    "/actors"                   => "/actor:list",
    "/list-actors"              => "/actor:list",
    "/workspace list"           => "/workspace:list",
    "/workspace edit"           => "/workspace:edit",
    "/workspace add-folder"     => "/workspace:add-folder",
    "/workspace remove-folder"  => "/workspace:remove-folder",
    "/workspace bind-chat"      => "/workspace:bind-chat",
    "/workspace unbind-chat"    => "/workspace:unbind-chat",
    "/workspace remove"         => "/workspace:remove",
    "/workspace rename"         => "/workspace:rename",
    "/workspace use"            => "/workspace:use",
    "/workspace import-repo"    => "/workspace:import-repo",
    "/workspace forget-repo"    => "/workspace:forget-repo",
    "/workspace info"           => "/workspace:info",
    "/workspace describe"       => "/workspace:describe",
    "/workspace sessions"       => nil,
    "/plugin list"              => "/plugin:list",
    "/plugin info"              => "/plugin:info",
    "/plugin install"           => "/plugin:install",
    "/plugin enable"            => "/plugin:enable",
    "/plugin disable"           => "/plugin:disable"
  }
  ```

  **3b.** Replace the `:not_found` branch in `handle_cast({:dispatch, ...})`:

  ```elixir
  :not_found ->
    head1 = slash_head(text)
    head2 = two_token_head(text)

    case Map.get(@deprecated_slashes, head2) || Map.get(@deprecated_slashes, head1) do
      nil ->
        Esr.Slash.ReplyTarget.dispatch(target, {:text, "unknown command: #{head1}"}, ref)

      new_name when is_binary(new_name) ->
        Esr.Slash.ReplyTarget.dispatch(
          target,
          {:text, "slash command renamed; use #{new_name} instead of #{head1}"},
          ref
        )

      nil_value when is_nil(nil_value) ->
        # /workspace:sessions dropped (workspace must not depend on session).
        Esr.Slash.ReplyTarget.dispatch(
          target,
          {:text, "#{head1} has been removed; use /session:list to list sessions"},
          ref
        )
    end

    {:noreply, state}
  ```

  **3c.** Add `two_token_head/1` private function after `slash_head/1`:

  ```elixir
  defp two_token_head(text) do
    text
    |> String.trim()
    |> String.split(~r/\s+/, parts: 3, trim: true)
    |> Enum.take(2)
    |> Enum.join(" ")
  end
  ```

  **3d.** Update the `merge_chat_context/2` clause for the old `"key"` kind to `"pty_key"`:

  ```elixir
  # Was: defp merge_chat_context(args, "key", envelope) do
  defp merge_chat_context(args, "pty_key", envelope) do
    text = (get_in(envelope, ["payload", "text"]) || "") |> to_string()
    remainder = strip_slash_prefix(text, "/pty:key") |> String.trim()
    maybe_put(args, "keys", remainder)
  end
  ```

- [ ] **Step 4 — Run passing tests.**

```bash
cd runtime && mix test test/esr/entity/slash_handler_test.exs 2>&1 | tail -10
```

- [ ] **Step 5 — Commit.**

```bash
git add runtime/lib/esr/entity/slash_handler.ex \
        runtime/test/esr/entity/slash_handler_test.exs
git commit -m "feat(slash): deprecated-slash hint map + pty_key kind routing (Phase 6.3)"
```

---

### Task 6.4: `/help` — colon-prefix grouping headers

**Files:**
- Modify: `runtime/lib/esr/commands/help.ex`
- Extend: `runtime/test/esr/commands/help_test.exs`

**Analysis:** `render/0` calls `list_slashes()` and groups by `route[:category]`. After the yaml rewrite,
the categories on the entries are already the right Chinese/English labels. The `category_order/1`
function needs additions for the new categories: `"PTY"`, `"Capabilities"`. The bare `/help` and `/doctor`
remain in `"诊断"`. No logic change needed for colon rendering — `route.slash` is emitted verbatim.

- [ ] **Step 1 — Write failing test.**

```elixir
defmodule Esr.Commands.HelpTest do
  use ExUnit.Case, async: true

  # Requires the registry to have loaded the yaml.
  # Tag: @moduletag :integration (requires running registry)

  describe "render/0 with colon-namespace yaml" do
    test "help output contains colon-form slash names" do
      output = Esr.Commands.Help.render()
      assert String.contains?(output, "/session:new")
      assert String.contains?(output, "/workspace:list")
      assert String.contains?(output, "/pty:key")
      assert String.contains?(output, "/plugin:list")
      assert String.contains?(output, "/user:whoami")
    end

    test "help output does NOT contain old-form slash names" do
      output = Esr.Commands.Help.render()
      refute String.contains?(output, "/new-session")
      refute String.contains?(output, "/workspace list")
      refute String.contains?(output, "/workspace sessions")
      refute String.contains?(output, "/key\n")
      refute String.contains?(output, "/sessions\n")
    end

    test "help output contains bare /help and /doctor" do
      output = Esr.Commands.Help.render()
      assert String.contains?(output, "/help")
      assert String.contains?(output, "/doctor")
    end

    test "Sessions group header appears before Agents group" do
      output = Esr.Commands.Help.render()
      sessions_pos = :binary.match(output, "Sessions") |> elem(0)
      agents_pos = :binary.match(output, "Agents") |> elem(0)
      assert sessions_pos < agents_pos
    end

    test "PTY group appears in output" do
      output = Esr.Commands.Help.render()
      assert String.contains?(output, "PTY")
    end

    test "Capabilities group appears in output" do
      output = Esr.Commands.Help.render()
      assert String.contains?(output, "Capabilities")
    end
  end
end
```

- [ ] **Step 2 — Run failing test.**

```bash
cd runtime && mix test test/esr/commands/help_test.exs 2>&1 | tail -15
```

- [ ] **Step 3 — Implement.** In `runtime/lib/esr/commands/help.ex`, update `category_order/1`:

```elixir
defp category_order("诊断"), do: 0
defp category_order("Workspace"), do: 1
defp category_order("Sessions"), do: 2
defp category_order("Agents"), do: 3
defp category_order("PTY"), do: 4
defp category_order("Plugins"), do: 5
defp category_order("Capabilities"), do: 6
defp category_order("其他"), do: 99
defp category_order(_), do: 50
```

No other changes needed — the render loop uses `route.slash` verbatim.

- [ ] **Step 4 — Run passing tests.**

```bash
cd runtime && mix test test/esr/commands/help_test.exs 2>&1 | tail -10
```

- [ ] **Step 5 — Commit.**

```bash
git add runtime/lib/esr/commands/help.ex \
        runtime/test/esr/commands/help_test.exs
git commit -m "feat(help): add PTY + Capabilities to category_order for colon-namespace grouping (Phase 6.4)"
```

---

### Task 6.5: `/admin/slash_schema.json` controller — colon-name smoke test

**Files:**
- Read: `runtime/lib/esr_web/slash_schema_controller.ex`
- Extend: `runtime/test/esr_web/slash_schema_controller_test.exs`

**Analysis:** The controller renders slash names directly from `Registry.list_slashes/0`. After the yaml
rewrite, it will automatically return colon-form names. No logic patch needed. This task adds a smoke
test that verifies colon names appear in the JSON response.

- [ ] **Step 1 — Write failing test.**

```elixir
describe "GET /admin/slash_schema.json — colon-namespace" do
  test "response contains colon-form slash names", %{conn: conn} do
    conn = get(conn, "/admin/slash_schema.json")
    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    slashes = get_in(body, ["slashes"]) || Map.keys(body)

    slash_names =
      case slashes do
        list when is_list(list) -> Enum.map(list, &(Map.get(&1, "slash") || Map.get(&1, :slash) || &1))
        map when is_map(map) -> Map.keys(map)
      end

    assert Enum.any?(slash_names, &String.contains?(&1, ":")),
           "expected at least one colon-form slash name in response, got: #{inspect(slash_names)}"

    assert Enum.any?(slash_names, &String.starts_with?(&1, "/session:")),
           "expected /session:* entries in response"
  end

  test "response does NOT contain old-form slash names", %{conn: conn} do
    conn = get(conn, "/admin/slash_schema.json")
    body = Jason.decode!(conn.resp_body)
    slashes = get_in(body, ["slashes"]) || Map.keys(body)

    slash_names =
      case slashes do
        list when is_list(list) -> Enum.map(list, &(Map.get(&1, "slash") || &1))
        map when is_map(map) -> Map.keys(map)
      end

    refute Enum.any?(slash_names, &(&1 == "/new-session")),
           "old-form /new-session should not appear in schema endpoint"

    refute Enum.any?(slash_names, &(&1 == "/workspace sessions")),
           "/workspace sessions should be absent (Rule 6)"
  end
end
```

- [ ] **Step 2 — Run failing test.**

```bash
cd runtime && mix test test/esr_web/slash_schema_controller_test.exs 2>&1 | tail -15
```

- [ ] **Step 3 — Verify no logic change needed.**

```bash
cat runtime/lib/esr_web/slash_schema_controller.ex
```

If the controller serializes `route.slash` fields directly, no patch is needed. If it constructs its own
list from a different source, update it to call `Registry.list_slashes/0`.

- [ ] **Step 4 — Run passing tests.**

```bash
cd runtime && mix test test/esr_web/slash_schema_controller_test.exs 2>&1 | tail -10
```

- [ ] **Step 5 — Commit.**

```bash
git add runtime/test/esr_web/slash_schema_controller_test.exs
git commit -m "test(web): slash_schema_controller smoke test — colon names in JSON response (Phase 6.5)"
```

---

### Task 6.6: Escript subcommand routing — `esr session new` → `/session:new`

**Files:**
- Read: `runtime/lib/esr/cli/main.ex`
- Modify if needed: `runtime/lib/esr/cli/main.ex`
- Extend: `runtime/test/esr/cli/main_test.exs`

**Analysis:** Read `main.ex` to understand how `esr session new --name=foo` maps to a slash string.
The escript uses sub-action concatenation to produce kind names (e.g. `esr cap grant` → kind `cap_grant`).
If the escript sends a kind directly (bypassing slash routing), no change is needed for the routing
itself. But if the escript constructs a `/session new` slash string and sends it to SlashHandler, it
must be updated to construct `/session:new`.

- [ ] **Step 1 — Read and assess.**

```bash
grep -n "session\|slash\|dispatch\|colon\|/session\|new_session" runtime/lib/esr/cli/main.ex | head -40
```

- [ ] **Step 2 — Write failing test.** After reading, write a test that asserts the escript mapping
produces a colon-form slash string (if it produces slash strings) or the correct kind (if kind-based):

```elixir
describe "escript → colon-slash mapping (Phase 6.6)" do
  test "esr session new produces kind session_new" do
    # Parse without executing — call the arg-parse path only.
    result = Esr.CLI.Main.parse_args(["session", "new", "--name=foo"])

    # Depending on implementation:
    # If parse_args returns {kind, args}: assert kind == "session_new"
    # If it constructs a slash string: assert slash == "/session:new"
    assert match?({:ok, "session_new", _} , result) or
           match?({:ok, %{"kind" => "session_new"}}, result) or
           match?({kind, _} when kind == "session_new", result),
           "Expected session_new kind from 'esr session new', got: #{inspect(result)}"
  end

  test "esr session list produces kind session_list" do
    result = Esr.CLI.Main.parse_args(["session", "list"])
    assert inspect(result) =~ "session_list",
           "Expected session_list, got: #{inspect(result)}"
  end
end
```

- [ ] **Step 3 — Implement (if needed).** If the escript uses a sub-action concatenation like
`"#{group}_#{verb}"` to produce kind names, the colon-form yaml change is transparent (kind names
haven't changed). Only patch if the escript literally builds slash strings like `"/session new"`.

  If `main.ex` constructs slash strings for a `session` sub-group, update the builder to emit
  `"/session:new"` instead of `"/session new"`.

- [ ] **Step 4 — Run passing tests.**

```bash
cd runtime && mix test test/esr/cli/main_test.exs 2>&1 | tail -10
```

- [ ] **Step 5 — Commit.**

```bash
git add runtime/lib/esr/cli/main.ex \
        runtime/test/esr/cli/main_test.exs
git commit -m "feat(cli): escript session subcommands route to colon-form kinds (Phase 6.6)"
```

---

### Task 6.7: Test sweep — update all slash literals in `runtime/test/`

**Files:**
- Search and update: all files under `runtime/test/` containing old slash literals

- [ ] **Step 1 — Enumerate old-form literals.**

```bash
grep -rn '"/new-session\|"/end-session\|"/sessions\|"/list-sessions\|"/list-agents\|"/actors\|"/attach\|"/workspace list\|"/workspace info\|"/workspace sessions\|"/plugin list\|"/plugin info\|"/plugin install\|"/plugin enable\|"/plugin disable\|"/whoami\|"/new-workspace\|"/key"' \
  runtime/test/ 2>/dev/null | grep -v "_test.exs:.*#"
```

- [ ] **Step 2 — Run failing test sweep.** Before editing, confirm which tests fail:

```bash
cd runtime && mix test 2>&1 | grep -E "FAILED|failed|error" | head -20
```

- [ ] **Step 3 — Apply replacements.** For each file found in Step 1, apply the mapping:

| Old literal | New literal |
|---|---|
| `"/new-session"` | `"/session:new"` |
| `"/end-session"` | `"/session:end"` |
| `"/sessions"` | `"/session:list"` |
| `"/list-sessions"` | `"/session:list"` |
| `"/attach"` (slash literal only) | `"/session:attach"` |
| `"/list-agents"` | `"/agent:list"` |
| `"/actors"` | `"/actor:list"` |
| `"/list-actors"` | `"/actor:list"` |
| `"/workspace list"` | `"/workspace:list"` |
| `"/workspace info"` | `"/workspace:info"` |
| `"/workspace sessions"` | Remove test or replace with `/session:list` |
| `"/workspace edit"` | `"/workspace:edit"` |
| `"/workspace add-folder"` | `"/workspace:add-folder"` |
| `"/workspace remove-folder"` | `"/workspace:remove-folder"` |
| `"/workspace bind-chat"` | `"/workspace:bind-chat"` |
| `"/workspace unbind-chat"` | `"/workspace:unbind-chat"` |
| `"/workspace remove"` | `"/workspace:remove"` |
| `"/workspace rename"` | `"/workspace:rename"` |
| `"/workspace use"` | `"/workspace:use"` |
| `"/workspace import-repo"` | `"/workspace:import-repo"` |
| `"/workspace forget-repo"` | `"/workspace:forget-repo"` |
| `"/workspace describe"` | `"/workspace:describe"` |
| `"/new-workspace"` | `"/workspace:new"` |
| `"/plugin list"` | `"/plugin:list"` |
| `"/plugin info"` | `"/plugin:info"` |
| `"/plugin install"` | `"/plugin:install"` |
| `"/plugin enable"` | `"/plugin:enable"` |
| `"/plugin disable"` | `"/plugin:disable"` |
| `"/whoami"` | `"/user:whoami"` |
| `"/key"` (slash command) | `"/pty:key"` |

For tests that specifically **validate the deprecated hint path** (e.g. "dispatch `/new-session` returns
unknown command"), update them to assert the hint text contains `/session:new`.

- [ ] **Step 4 — Run full test suite.**

```bash
cd runtime && mix test 2>&1 | tail -20
```

All previously-passing tests must continue to pass.

- [ ] **Step 5 — Commit.**

```bash
git add runtime/test/
git commit -m "test: update all slash literals to colon-namespace form (Phase 6.7)"
```

---

### Task 6.8: Docs preview sweep (advisory docs only)

**Files:**
- Search: `docs/` (excluding `docs/superpowers/specs/` historical and `docs/futures/` deferred items)
- Update advisory docs that reference old slash forms

- [ ] **Step 1 — Enumerate old-form references in advisory docs.**

```bash
grep -rn '/new-session\|/end-session\|/sessions\b\|/list-agents\|/workspace list\|/workspace info\|/workspace sessions\|/plugin list\|/plugin install\|/whoami\|/new-workspace\|/key\b' \
  docs/ --include="*.md" \
  | grep -v "specs/2026-05-07-metamodel-aligned-esr\|specs/2026-05-07-colon-namespace\|futures/\|migration\|before-cutover\|historical" \
  | head -50
```

- [ ] **Step 2 — Update advisory docs.** For each match in `docs/dev-guide.md`, `docs/cookbook.md`,
`docs/runbook.md`, or similar operator-facing documents: replace old slash literals with colon forms.
Leave untouched:
  - Historical migration notes that explicitly describe "before Phase 6" state
  - `docs/superpowers/specs/` files (these are the specs themselves, not advisory docs)
  - `docs/futures/` items

- [ ] **Step 3 — Verify no spec files modified.**

```bash
git diff --name-only | grep "docs/superpowers/specs" && echo "ERROR: spec file modified" || echo "OK"
```

- [ ] **Step 4 — Run test suite (docs change only, no test failures expected).**

```bash
cd runtime && mix test 2>&1 | tail -5
```

- [ ] **Step 5 — Commit.**

```bash
git add docs/
git commit -m "docs: preview sweep — advisory docs updated to colon-namespace slash forms (Phase 6.8)"
```

---

### Phase 6 PR checklist

Before opening the PR:

- [ ] `cd runtime && mix test 2>&1 | tail -20` — all pass
- [ ] `grep -rn '"/new-session\|"/workspace list\|"/workspace info"' runtime/test/` — zero hits
- [ ] `grep -rn 'aliases:' runtime/priv/slash-routes.default.yaml` — zero hits
- [ ] `grep -n '"/workspace sessions"' runtime/priv/slash-routes.default.yaml` — zero hits
- [ ] `grep -n '"/pty:key"' runtime/priv/slash-routes.default.yaml` — one hit
- [ ] `grep -n '"/key"' runtime/priv/slash-routes.default.yaml` — zero hits

```bash
git commit -m "feat: colon-namespace slash cutover — hard cutover + session/pty/cap families (Phase 6)"
```

---

## Phase 7: Plugin-config 3-layer + manifest config_schema + depends_on.core SemVer

**PR title:** `feat: plugin-config 3-layer + manifest config_schema + depends_on.core SemVer (Phase 7)`
**Branch:** `feat/phase-7-plugin-config`
**Target:** `dev`
**Est LOC:** ~700
**Depends on:** Phase 6 (slash routing for /plugin:set etc.), Phase 1b (user UUID for user-layer config path)

**Goal:** Implement the 3-layer plugin config resolution stack (global → user → workspace, per-key merge,
most-specific wins). Add `config_schema:` field to `Esr.Plugin.Manifest`. Add `Esr.Plugin.Version`
for `depends_on.core` SemVer enforcement at plugin load time. Implement `/plugin:set`, `/plugin:unset`,
`/plugin:show-config` command modules. Migrate feishu and claude_code manifests to include `config_schema:`.
Phase 7 ends with the config mechanism in place; Phase 8 removes the env-var fallback in `feishu_app_adapter.ex`.

---

### Task 7.1: Manifest `config_schema:` parsing

**Files:**
- Modify: `runtime/lib/esr/plugin/manifest.ex`
- Extend: `runtime/test/esr/plugin/manifest_test.exs`

**Goal:** Parse a `config_schema:` YAML block into a map of `%{type, description, default}` entries.
Validate required fields (`type`, `description`, `default`) at parse time. Support types: `string`, `boolean`.

- [ ] **Step 1 — Write failing test.**

```elixir
describe "config_schema: parsing (Phase 7.1)" do
  @manifest_with_schema """
  name: test-plugin
  version: 0.1.0
  description: test
  depends_on:
    core: ">= 0.1.0"
    plugins: []
  declares: {}
  config_schema:
    http_proxy:
      type: string
      description: "HTTP proxy URL."
      default: ""
    verbose:
      type: boolean
      description: "Enable verbose logging."
      default: false
  """

  @manifest_missing_description """
  name: test-plugin
  version: 0.1.0
  description: test
  depends_on:
    core: ">= 0.1.0"
    plugins: []
  declares: {}
  config_schema:
    bad_key:
      type: string
      default: ""
  """

  @manifest_missing_default """
  name: test-plugin
  version: 0.1.0
  description: test
  depends_on:
    core: ">= 0.1.0"
    plugins: []
  declares: {}
  config_schema:
    bad_key:
      type: string
      description: "Missing default."
  """

  @manifest_unknown_type """
  name: test-plugin
  version: 0.1.0
  description: test
  depends_on:
    core: ">= 0.1.0"
    plugins: []
  declares: {}
  config_schema:
    bad_key:
      type: fancy_type
      description: "Unknown type."
      default: ""
  """

  defp parse_yaml_string(content) do
    path = System.tmp_dir!() |> Path.join("test_manifest_#{:rand.uniform(9999)}.yaml")
    File.write!(path, content)
    result = Esr.Plugin.Manifest.parse(path)
    File.rm(path)
    result
  end

  test "valid config_schema parses into declares.config_schema map" do
    {:ok, manifest} = parse_yaml_string(@manifest_with_schema)
    schema = manifest.declares[:config_schema]
    assert is_map(schema)
    assert schema["http_proxy"]["type"] == "string"
    assert schema["http_proxy"]["default"] == ""
    assert schema["verbose"]["type"] == "boolean"
    assert schema["verbose"]["default"] == false
  end

  test "missing description field returns config_schema_missing_field error" do
    assert {:error, {:config_schema_missing_field, "bad_key", "description"}} =
             parse_yaml_string(@manifest_missing_description)
  end

  test "missing default field returns config_schema_missing_field error" do
    assert {:error, {:config_schema_missing_field, "bad_key", "default"}} =
             parse_yaml_string(@manifest_missing_default)
  end

  test "unknown type returns config_schema_unknown_type error" do
    assert {:error, {:config_schema_unknown_type, "bad_key", "fancy_type"}} =
             parse_yaml_string(@manifest_unknown_type)
  end

  test "manifest without config_schema: has empty declares.config_schema" do
    yaml = """
    name: test-plugin
    version: 0.1.0
    description: test
    depends_on:
      core: ">= 0.1.0"
      plugins: []
    declares: {}
    """

    {:ok, manifest} = parse_yaml_string(yaml)
    assert manifest.declares[:config_schema] == %{} or is_nil(manifest.declares[:config_schema])
  end
end
```

- [ ] **Step 2 — Run failing test.**

```bash
cd runtime && mix test test/esr/plugin/manifest_test.exs --only "config_schema" 2>&1 | tail -20
```

- [ ] **Step 3 — Implement.** In `runtime/lib/esr/plugin/manifest.ex`:

  **3a.** In `parse/1`, after `atomize_declares`, call a new `parse_config_schema/1`:

  ```elixir
  # In parse/1, add after declares assignment:
  with {:ok, config_schema} <- parse_config_schema(parsed["config_schema"] || %{}) do
    declares_with_schema = Map.put(declares, :config_schema, config_schema)

    {:ok,
     %__MODULE__{
       name: name,
       version: version,
       description: parsed["description"] || "",
       depends_on: depends_on,
       declares: declares_with_schema,
       path: path
     }}
  end
  ```

  Replace the existing `{:ok, %__MODULE__{...}}` return at the end of `parse/1` with the `with` form above.

  **3b.** Add `parse_config_schema/1`:

  ```elixir
  @supported_types ~w(string boolean)

  defp parse_config_schema(schema_map) when is_map(schema_map) do
    Enum.reduce_while(schema_map, {:ok, %{}}, fn {key, entry}, {:ok, acc} ->
      with {:ok, type} <- fetch_schema_field(key, entry, "type"),
           :ok <- validate_schema_type(key, type),
           {:ok, description} <- fetch_schema_field(key, entry, "description"),
           {:ok, default} <- fetch_schema_field(key, entry, "default") do
        {:cont, {:ok, Map.put(acc, key, %{"type" => type, "description" => description, "default" => default})}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp parse_config_schema(_), do: {:ok, %{}}

  defp fetch_schema_field(key, entry, field) when is_map(entry) do
    case Map.fetch(entry, field) do
      {:ok, value} when not is_nil(value) -> {:ok, value}
      _ -> {:error, {:config_schema_missing_field, key, field}}
    end
  end

  defp fetch_schema_field(key, _entry, field), do: {:error, {:config_schema_missing_field, key, field}}

  defp validate_schema_type(key, type) when is_binary(type) do
    if type in @supported_types do
      :ok
    else
      {:error, {:config_schema_unknown_type, key, type}}
    end
  end

  defp validate_schema_type(key, type), do: {:error, {:config_schema_unknown_type, key, inspect(type)}}
  ```

- [ ] **Step 4 — Run passing tests.**

```bash
cd runtime && mix test test/esr/plugin/manifest_test.exs 2>&1 | tail -10
```

- [ ] **Step 5 — Commit.**

```bash
git add runtime/lib/esr/plugin/manifest.ex \
        runtime/test/esr/plugin/manifest_test.exs
git commit -m "feat(plugin): manifest config_schema: field — parse + validate type/description/default (Phase 7.1)"
```

---

### Task 7.2: `Esr.Plugin.Version` — SemVer constraint wrapper

**Files:**
- Create: `runtime/lib/esr/plugin/version.ex`
- Create: `runtime/test/esr/plugin/version_test.exs`

**Goal:** Thin wrapper over Elixir stdlib `Version` module for `depends_on.core` constraint checks.
Exposes `satisfies?/2` and `esrd_version/0`.

- [ ] **Step 1 — Write failing test.** Create `runtime/test/esr/plugin/version_test.exs`:

```elixir
defmodule Esr.Plugin.VersionTest do
  use ExUnit.Case, async: true

  alias Esr.Plugin.Version, as: V

  describe "satisfies?/2" do
    test ">= constraint passes when version is equal" do
      assert V.satisfies?(">= 0.1.0", "0.1.0") == true
    end

    test ">= constraint passes when version is higher" do
      assert V.satisfies?(">= 0.1.0", "0.2.0") == true
    end

    test ">= constraint fails when version is lower" do
      assert V.satisfies?(">= 0.2.0", "0.1.0") == false
    end

    test "~> pessimistic constraint passes patch bump" do
      assert V.satisfies?("~> 0.1.0", "0.1.5") == true
    end

    test "~> pessimistic constraint fails minor bump" do
      assert V.satisfies?("~> 0.1.0", "0.2.0") == false
    end

    test "exact == constraint passes on exact match" do
      assert V.satisfies?("== 0.1.0", "0.1.0") == true
    end

    test "exact == constraint fails on mismatch" do
      assert V.satisfies?("== 0.1.0", "0.2.0") == false
    end

    test "invalid constraint string returns {:error, :invalid_constraint}" do
      assert {:error, :invalid_constraint} = V.satisfies?("not_a_constraint", "0.1.0")
    end

    test "invalid version string returns {:error, :invalid_constraint}" do
      assert {:error, :invalid_constraint} = V.satisfies?(">= 0.1.0", "not_a_version")
    end

    test ">= 0.1.0 passes 0.1.0 (exact boundary)" do
      assert V.satisfies?(">= 0.1.0", "0.1.0") == true
    end

    test ">= 99.0.0 fails on current esrd version" do
      vsn = V.esrd_version()
      assert V.satisfies?(">= 99.0.0", vsn) == false
    end
  end

  describe "esrd_version/0" do
    test "returns a valid SemVer string" do
      vsn = V.esrd_version()
      assert is_binary(vsn)
      assert {:ok, _} = Version.parse(vsn)
    end
  end
end
```

- [ ] **Step 2 — Run failing test.**

```bash
cd runtime && mix test test/esr/plugin/version_test.exs 2>&1 | tail -15
```

- [ ] **Step 3 — Implement.** Create `runtime/lib/esr/plugin/version.ex`:

```elixir
defmodule Esr.Plugin.Version do
  @moduledoc """
  SemVer constraint check for `depends_on.core`.

  Wraps Elixir stdlib `Version` module. Thin — the only reason for this
  module is to centralize the error handling shape and provide
  `esrd_version/0` in one place.

  Spec: docs/superpowers/specs/2026-05-07-metamodel-aligned-esr.md §6 (D8).
  """

  @doc """
  Check whether `version` satisfies `constraint`.

  Returns `true | false` on success, or `{:error, :invalid_constraint}`
  when either string is not valid SemVer / not a valid constraint.

  Uses Elixir stdlib `Version.match?/2` under the hood.
  """
  @spec satisfies?(constraint :: String.t(), version :: String.t()) ::
          boolean() | {:error, :invalid_constraint}
  def satisfies?(constraint, version) when is_binary(constraint) and is_binary(version) do
    try do
      Version.match?(version, constraint)
    rescue
      _ -> {:error, :invalid_constraint}
    end
  end

  def satisfies?(_constraint, _version), do: {:error, :invalid_constraint}

  @doc """
  Return the running ESR version as a SemVer string.

  Reads from the `:esr` application spec at runtime (populated by
  `mix.exs`'s `@version`). Falls back to `"0.0.0"` if the app spec
  is unavailable (e.g. in unit tests that don't start the application).
  """
  @spec esrd_version() :: String.t()
  def esrd_version do
    case Application.spec(:esr, :vsn) do
      nil -> "0.0.0"
      vsn -> to_string(vsn)
    end
  end
end
```

- [ ] **Step 4 — Run passing tests.**

```bash
cd runtime && mix test test/esr/plugin/version_test.exs 2>&1 | tail -10
```

- [ ] **Step 5 — Commit.**

```bash
git add runtime/lib/esr/plugin/version.ex \
        runtime/test/esr/plugin/version_test.exs
git commit -m "feat(plugin): Esr.Plugin.Version — SemVer constraint check for depends_on.core (Phase 7.2)"
```

---

### Task 7.3: `depends_on.core` enforcement at plugin load

**Files:**
- Modify: `runtime/lib/esr/plugin/loader.ex`
- Extend: `runtime/test/esr/plugin/loader_test.exs`

**Goal:** Call `Esr.Plugin.Version.satisfies?/2` at `start_plugin/2` before `Manifest.validate/1`.
If the constraint is unmet, return `{:error, {:core_version_mismatch, constraint, actual}}` and let it
crash (no silent skip).

- [ ] **Step 1 — Write failing test.**

```elixir
describe "depends_on.core enforcement (Phase 7.3)" do
  defp make_manifest(core_constraint) do
    path = System.tmp_dir!() |> Path.join("test_manifest_#{:rand.uniform(99999)}.yaml")

    content = """
    name: test-plugin
    version: 0.1.0
    description: test
    depends_on:
      core: "#{core_constraint}"
      plugins: []
    declares: {}
    """

    File.write!(path, content)
    {:ok, manifest} = Esr.Plugin.Manifest.parse(path)
    File.rm(path)
    manifest
  end

  test "plugin with satisfied core constraint starts successfully" do
    manifest = make_manifest(">= 0.1.0")
    # ESR version is >= 0.1.0 in any real build.
    result = Esr.Plugin.Loader.start_plugin("test-plugin", manifest)
    # May fail on validate/1 for missing modules, but must NOT fail on
    # core_version_mismatch.
    refute match?({:error, {:core_version_mismatch, _, _}}, result)
  end

  test "plugin requiring future core version is rejected" do
    manifest = make_manifest(">= 99.0.0")
    assert {:error, {:core_version_mismatch, ">= 99.0.0", actual_vsn}} =
             Esr.Plugin.Loader.start_plugin("test-plugin", manifest)
    assert is_binary(actual_vsn)
  end

  test "plugin without core constraint starts successfully (no constraint = unrestricted)" do
    path = System.tmp_dir!() |> Path.join("test_manifest_nocore.yaml")

    content = """
    name: test-plugin-nocore
    version: 0.1.0
    description: test
    depends_on:
      plugins: []
    declares: {}
    """

    File.write!(path, content)
    {:ok, manifest} = Esr.Plugin.Manifest.parse(path)
    File.rm(path)

    result = Esr.Plugin.Loader.start_plugin("test-plugin-nocore", manifest)
    refute match?({:error, {:core_version_mismatch, _, _}}, result)
  end
end
```

- [ ] **Step 2 — Run failing test.**

```bash
cd runtime && mix test test/esr/plugin/loader_test.exs --only "core enforcement" 2>&1 | tail -15
```

- [ ] **Step 3 — Implement.** In `runtime/lib/esr/plugin/loader.ex`:

  **3a.** Add alias at top of module:

  ```elixir
  alias Esr.Plugin.Version, as: PluginVersion
  ```

  **3b.** Add private `check_core_version/1`:

  ```elixir
  defp check_core_version(%Manifest{depends_on: depends_on}) do
    constraint = depends_on[:core]

    if is_binary(constraint) and constraint != "" do
      esrd_vsn = PluginVersion.esrd_version()

      case PluginVersion.satisfies?(constraint, esrd_vsn) do
        true ->
          :ok

        false ->
          {:error, {:core_version_mismatch, constraint, esrd_vsn}}

        {:error, :invalid_constraint} ->
          {:error, {:invalid_core_constraint, constraint}}
      end
    else
      :ok
    end
  end
  ```

  **3c.** Prepend `check_core_version/1` to the `with` chain in `start_plugin/2`:

  ```elixir
  def start_plugin(name, %Manifest{} = manifest) do
    with :ok <- check_core_version(manifest),
         :ok <- Manifest.validate(manifest),
         :ok <- register_capabilities(name, manifest),
         :ok <- register_python_sidecars(manifest),
         :ok <- register_entities(manifest),
         :ok <- register_startup(name, manifest) do
      Logger.info("plugin loader: started #{name} v#{manifest.version}")
      {:ok, :registered}
    end
  end
  ```

- [ ] **Step 4 — Run passing tests.**

```bash
cd runtime && mix test test/esr/plugin/loader_test.exs 2>&1 | tail -10
```

- [ ] **Step 5 — Commit.**

```bash
git add runtime/lib/esr/plugin/loader.ex \
        runtime/test/esr/plugin/loader_test.exs
git commit -m "feat(plugin): depends_on.core SemVer enforcement at start_plugin/2 (Phase 7.3)"
```

---

### Task 7.4: `Esr.Plugin.Config` — 3-layer resolver

**Files:**
- Create: `runtime/lib/esr/plugin/config.ex`
- Create: `runtime/test/esr/plugin/config_test.exs`

**Goal:** Implement the 3-layer plugin config resolution stack:
- **global** layer: `$ESRD_HOME/<inst>/plugins.yaml` → `config.<plugin>` section
- **user** layer: `$ESRD_HOME/<inst>/users/<user_uuid>/.esr/plugins.yaml` → `config.<plugin>` section
- **workspace** layer: `<workspace_dir>/.esr/plugins.yaml` → `config.<plugin>` section

Resolution: workspace > user > global (per-key merge). Schema defaults fill in any remaining gaps.
Write operations (`store_layer/4`) write atomically to the correct layer file.

- [ ] **Step 1 — Write failing test.** Create `runtime/test/esr/plugin/config_test.exs`:

```elixir
defmodule Esr.Plugin.ConfigTest do
  use ExUnit.Case, async: true

  alias Esr.Plugin.Config

  # We use temp dirs to simulate the layer files.
  setup do
    tmp = System.tmp_dir!() |> Path.join("esr_config_test_#{:rand.uniform(999_999)}")
    File.mkdir_p!(tmp)

    global_dir = Path.join(tmp, "instance")
    user_uuid = "aabbccdd-1234-5678-abcd-ef0123456789"
    user_dir = Path.join([tmp, "instance", "users", user_uuid, ".esr"])
    workspace_dir = Path.join([tmp, "workspace1", ".esr"])

    File.mkdir_p!(global_dir)
    File.mkdir_p!(user_dir)
    File.mkdir_p!(workspace_dir)

    on_exit(fn -> File.rm_rf!(tmp) end)

    %{
      tmp: tmp,
      global_plugins_yaml: Path.join(global_dir, "plugins.yaml"),
      user_plugins_yaml: Path.join(user_dir, "plugins.yaml"),
      workspace_plugins_yaml: Path.join(workspace_dir, "plugins.yaml"),
      user_uuid: user_uuid
    }
  end

  defp write_yaml(path, content), do: File.write!(path, content)

  describe "resolve/2 — 3-layer merge" do
    test "empty all layers returns empty map", ctx do
      result = Config.resolve("my-plugin", global_path: ctx.global_plugins_yaml)
      assert result == %{}
    end

    test "global-only: returns global config", ctx do
      write_yaml(ctx.global_plugins_yaml, """
      enabled:
        - my-plugin
      config:
        my-plugin:
          api_key: "global-key"
          log_level: "info"
      """)

      result = Config.resolve("my-plugin", global_path: ctx.global_plugins_yaml)
      assert result["api_key"] == "global-key"
      assert result["log_level"] == "info"
    end

    test "user overrides global per-key", ctx do
      write_yaml(ctx.global_plugins_yaml, """
      config:
        my-plugin:
          api_key: "global-key"
          log_level: "info"
      """)

      write_yaml(ctx.user_plugins_yaml, """
      config:
        my-plugin:
          log_level: "debug"
      """)

      result = Config.resolve("my-plugin",
        global_path: ctx.global_plugins_yaml,
        user_path: ctx.user_plugins_yaml
      )

      assert result["api_key"] == "global-key"
      assert result["log_level"] == "debug"
    end

    test "workspace overrides user and global per-key", ctx do
      write_yaml(ctx.global_plugins_yaml, """
      config:
        my-plugin:
          http_proxy: "http://global-proxy:8080"
          log_level: "info"
      """)

      write_yaml(ctx.user_plugins_yaml, """
      config:
        my-plugin:
          log_level: "debug"
      """)

      write_yaml(ctx.workspace_plugins_yaml, """
      config:
        my-plugin:
          http_proxy: ""
      """)

      result = Config.resolve("my-plugin",
        global_path: ctx.global_plugins_yaml,
        user_path: ctx.user_plugins_yaml,
        workspace_path: ctx.workspace_plugins_yaml
      )

      assert result["http_proxy"] == ""
      assert result["log_level"] == "debug"
    end

    test "explicit empty string in workspace layer wins (disables proxy)", ctx do
      write_yaml(ctx.global_plugins_yaml, """
      config:
        my-plugin:
          http_proxy: "http://proxy:8080"
      """)

      write_yaml(ctx.workspace_plugins_yaml, """
      config:
        my-plugin:
          http_proxy: ""
      """)

      result = Config.resolve("my-plugin",
        global_path: ctx.global_plugins_yaml,
        workspace_path: ctx.workspace_plugins_yaml
      )

      assert result["http_proxy"] == ""
    end

    test "absent key in all layers returns nil for get/3", ctx do
      write_yaml(ctx.global_plugins_yaml, """
      config:
        my-plugin:
          log_level: "info"
      """)

      assert nil == Config.get("my-plugin", "nonexistent_key",
               global_path: ctx.global_plugins_yaml)
    end

    test "get/3 returns most-specific value", ctx do
      write_yaml(ctx.global_plugins_yaml, """
      config:
        my-plugin:
          log_level: "info"
      """)

      write_yaml(ctx.user_plugins_yaml, """
      config:
        my-plugin:
          log_level: "debug"
      """)

      assert "debug" == Config.get("my-plugin", "log_level",
               global_path: ctx.global_plugins_yaml,
               user_path: ctx.user_plugins_yaml)
    end

    test "other plugin's config in same yaml is not returned", ctx do
      write_yaml(ctx.global_plugins_yaml, """
      config:
        my-plugin:
          log_level: "info"
        other-plugin:
          log_level: "warn"
      """)

      result = Config.resolve("my-plugin", global_path: ctx.global_plugins_yaml)
      refute Map.has_key?(result, "other-plugin")
    end
  end

  describe "store_layer/4 — atomic write" do
    test "writes key to global layer", ctx do
      Config.store_layer("my-plugin", "log_level", "debug",
        layer: :global,
        global_path: ctx.global_plugins_yaml
      )

      result = Config.resolve("my-plugin", global_path: ctx.global_plugins_yaml)
      assert result["log_level"] == "debug"
    end

    test "write-then-read round-trip at workspace layer", ctx do
      Config.store_layer("my-plugin", "http_proxy", "http://test:8080",
        layer: :workspace,
        workspace_path: ctx.workspace_plugins_yaml
      )

      result = Config.resolve("my-plugin", workspace_path: ctx.workspace_plugins_yaml)
      assert result["http_proxy"] == "http://test:8080"
    end

    test "store is idempotent (overwrite same key)" , ctx do
      Config.store_layer("my-plugin", "k", "v1", layer: :global, global_path: ctx.global_plugins_yaml)
      Config.store_layer("my-plugin", "k", "v2", layer: :global, global_path: ctx.global_plugins_yaml)

      result = Config.resolve("my-plugin", global_path: ctx.global_plugins_yaml)
      assert result["k"] == "v2"
    end
  end

  describe "delete_layer/3 — remove key from layer" do
    test "deletes a key from the global layer", ctx do
      write_yaml(ctx.global_plugins_yaml, """
      config:
        my-plugin:
          log_level: "info"
          api_key: "key"
      """)

      Config.delete_layer("my-plugin", "log_level",
        layer: :global,
        global_path: ctx.global_plugins_yaml
      )

      result = Config.resolve("my-plugin", global_path: ctx.global_plugins_yaml)
      refute Map.has_key?(result, "log_level")
      assert result["api_key"] == "key"
    end

    test "deleting nonexistent key is idempotent", ctx do
      write_yaml(ctx.global_plugins_yaml, """
      config:
        my-plugin:
          log_level: "info"
      """)

      assert :ok = Config.delete_layer("my-plugin", "nonexistent",
               layer: :global,
               global_path: ctx.global_plugins_yaml)
    end
  end
end
```

- [ ] **Step 2 — Run failing test.**

```bash
cd runtime && mix test test/esr/plugin/config_test.exs 2>&1 | tail -20
```

- [ ] **Step 3 — Implement.** Create `runtime/lib/esr/plugin/config.ex`:

```elixir
defmodule Esr.Plugin.Config do
  @moduledoc """
  3-layer plugin config resolution: global / user / workspace.

  Precedence: workspace > user > global (per-key merge, most-specific wins).
  An explicit empty string `""` at a more-specific layer wins over a
  non-empty value at a less-specific layer (e.g. "disable proxy for this
  workspace").

  ## Layer file locations (production defaults)

    * global:    `$ESRD_HOME/<inst>/plugins.yaml`         (`:enabled` + `:config`)
    * user:      `$ESRD_HOME/<inst>/users/<uuid>/.esr/plugins.yaml`  (`:config` only)
    * workspace: `<workspace_root>/.esr/plugins.yaml`     (`:config` only)

  ## Public API

    * `resolve/2` — merge all layers, return a flat config map.
    * `get/3`     — convenience: resolve + fetch one key.
    * `store_layer/4` — write one key to a specific layer file (atomic).
    * `delete_layer/3` — remove one key from a specific layer file.

  Spec: docs/superpowers/specs/2026-05-07-metamodel-aligned-esr.md §6.
  """

  require Logger

  @doc """
  Resolve effective config for `plugin_name`. All layers are optional;
  pass paths via opts.

  Opts:
    * `:global_path`    — path to global plugins.yaml
    * `:user_path`      — path to user-layer plugins.yaml
    * `:workspace_path` — path to workspace-layer plugins.yaml

  Returns a flat `%{key => value}` map. Missing files are treated as
  empty layers (not errors).
  """
  @spec resolve(plugin_name :: String.t(), opts :: keyword()) :: map()
  def resolve(plugin_name, opts \\ []) do
    global    = read_layer(opts[:global_path], plugin_name)
    user      = read_layer(opts[:user_path], plugin_name)
    workspace = read_layer(opts[:workspace_path], plugin_name)

    global
    |> merge_layer(user)
    |> merge_layer(workspace)
  end

  @doc """
  Resolve and return a single config key for `plugin_name`, or `nil`
  if absent in all layers.
  """
  @spec get(plugin_name :: String.t(), key :: String.t(), opts :: keyword()) :: term() | nil
  def get(plugin_name, key, opts \\ []) do
    resolve(plugin_name, opts) |> Map.get(key)
  end

  @doc """
  Write a single key-value pair to the specified layer file.

  Opts (required for the target layer):
    * `:layer`          — `:global | :user | :workspace`
    * `:global_path`    — required when `layer: :global`
    * `:user_path`      — required when `layer: :user`
    * `:workspace_path` — required when `layer: :workspace`

  Atomic: reads the file, merges the key, writes to a temp path, then
  renames. Returns `:ok` on success; raises on file-system error.
  """
  @spec store_layer(plugin_name :: String.t(), key :: String.t(), value :: term(), opts :: keyword()) :: :ok
  def store_layer(plugin_name, key, value, opts) do
    path = layer_path!(opts)
    update_layer_file(path, plugin_name, fn cfg -> Map.put(cfg, key, value) end)
  end

  @doc """
  Remove a single key from the specified layer file. Idempotent.
  Returns `:ok` even if the key was absent.
  """
  @spec delete_layer(plugin_name :: String.t(), key :: String.t(), opts :: keyword()) :: :ok
  def delete_layer(plugin_name, key, opts) do
    path = layer_path!(opts)
    update_layer_file(path, plugin_name, fn cfg -> Map.delete(cfg, key) end)
  end

  # ------------------------------------------------------------------
  # Private helpers
  # ------------------------------------------------------------------

  defp read_layer(nil, _plugin_name), do: %{}
  defp read_layer(path, plugin_name) do
    case File.read(path) do
      {:error, :enoent} ->
        %{}

      {:error, reason} ->
        Logger.warning("plugin_config: cannot read #{path}: #{inspect(reason)}")
        %{}

      {:ok, content} ->
        case YamlElixir.read_from_string(content) do
          {:ok, parsed} ->
            get_in(parsed, ["config", plugin_name]) || %{}

          {:error, reason} ->
            Logger.warning("plugin_config: yaml parse error #{path}: #{inspect(reason)}")
            %{}
        end
    end
  end

  # Layer merge: base keys survive unless explicitly set in overlay.
  # Explicit empty string in overlay wins (e.g. http_proxy: "" disables proxy).
  # Only absent keys (not present in overlay) fall back to base.
  defp merge_layer(base, overlay) when is_map(overlay) do
    Map.merge(base, overlay)
  end

  defp merge_layer(base, _), do: base

  defp layer_path!(opts) do
    case opts[:layer] do
      :global    -> opts[:global_path]    || raise ArgumentError, "global_path required for layer: :global"
      :user      -> opts[:user_path]      || raise ArgumentError, "user_path required for layer: :user"
      :workspace -> opts[:workspace_path] || raise ArgumentError, "workspace_path required for layer: :workspace"
      other      -> raise ArgumentError, "unknown layer #{inspect(other)}; must be :global | :user | :workspace"
    end
  end

  defp update_layer_file(path, plugin_name, updater_fn) do
    # Read existing content (may not exist yet).
    existing =
      case File.read(path) do
        {:ok, content} ->
          case YamlElixir.read_from_string(content) do
            {:ok, parsed} -> parsed
            _ -> %{}
          end

        _ -> %{}
      end

    # Merge updated plugin config into existing content.
    current_cfg = get_in(existing, ["config", plugin_name]) || %{}
    updated_cfg = updater_fn.(current_cfg)

    # Rebuild the full file map.
    updated_file =
      existing
      |> Map.put("config", Map.put(existing["config"] || %{}, plugin_name, updated_cfg))

    # Serialize and write atomically.
    yaml_content = yaml_encode(updated_file)
    tmp_path = path <> ".tmp.#{:rand.uniform(999_999)}"
    dir = Path.dirname(path)
    File.mkdir_p!(dir)
    File.write!(tmp_path, yaml_content)
    File.rename!(tmp_path, path)
    :ok
  end

  # Minimal YAML encoder for plugin config maps.
  # Only handles string/boolean/integer scalar values + string keys.
  defp yaml_encode(map, indent \\ 0) when is_map(map) do
    prefix = String.duplicate("  ", indent)

    map
    |> Enum.map(fn {k, v} ->
      key = "#{prefix}#{k}:"

      case v do
        v when is_map(v) ->
          "#{key}\n#{yaml_encode(v, indent + 1)}"

        v when is_binary(v) ->
          ~s(#{key} "#{String.replace(v, "\"", "\\\"")}")

        v ->
          "#{key} #{v}"
      end
    end)
    |> Enum.join("\n")
    |> Kernel.<>("\n")
  end
end
```

> **Note on YAML serialization:** If the project already has a YAML encoder dependency (check `mix.exs`
> for `:yaml_elixir` and `:yamerl`), prefer it over the custom `yaml_encode/2`. `YamlElixir` is a
> read-only library; for writing, the custom encoder or `Yamerl.encode/1` may be needed. Check
> `mix.exs` and adjust the `yaml_encode` call accordingly.

- [ ] **Step 4 — Run passing tests.**

```bash
cd runtime && mix test test/esr/plugin/config_test.exs 2>&1 | tail -10
```

- [ ] **Step 5 — Commit.**

```bash
git add runtime/lib/esr/plugin/config.ex \
        runtime/test/esr/plugin/config_test.exs
git commit -m "feat(plugin): Esr.Plugin.Config — 3-layer resolver + store/delete per layer (Phase 7.4)"
```

---

### Task 7.5: `/plugin:set` + `/plugin:unset` + `/plugin:show-config` command modules

**Files:**
- Create: `runtime/lib/esr/commands/plugin/set.ex`
- Create: `runtime/lib/esr/commands/plugin/unset.ex`
- Create: `runtime/lib/esr/commands/plugin/show_config.ex`
- Create: `runtime/lib/esr/commands/plugin/list_config.ex` (stub for `/plugin:list-config`)
- Create: `runtime/test/esr/commands/plugin/set_test.exs`
- Create: `runtime/test/esr/commands/plugin/unset_test.exs`
- Create: `runtime/test/esr/commands/plugin/show_config_test.exs`

**Analysis:** The yaml routing entries for these commands were added in Task 6.2 with a `@phase_7_modules`
skip guard. When these modules are created in this task, the guard can be removed from the registry test.

- [ ] **Step 1 — Write failing tests.**

```elixir
# runtime/test/esr/commands/plugin/set_test.exs
defmodule Esr.Commands.Plugin.SetTest do
  use ExUnit.Case, async: true

  alias Esr.Commands.Plugin.Set

  @tmp_dir System.tmp_dir!()

  setup do
    dir = Path.join(@tmp_dir, "plugin_set_test_#{:rand.uniform(999_999)}")
    File.mkdir_p!(dir)
    global_yaml = Path.join(dir, "plugins.yaml")
    on_exit(fn -> File.rm_rf!(dir) end)
    %{global_yaml: global_yaml, dir: dir}
  end

  test "returns error for unknown plugin name" do
    cmd = %{
      "kind" => "plugin_set",
      "args" => %{
        "plugin" => "nonexistent-plugin-xyz",
        "key" => "log_level",
        "value" => "debug",
        "layer" => "global"
      }
    }

    assert {:error, %{"type" => "unknown_plugin"}} = Set.execute(cmd)
  end

  test "returns restart hint on successful write" do
    # Use a manifest known to exist: feishu or claude_code.
    # Resolve path dynamically via Esr.Plugin.Loader.discover/0.
    {:ok, manifests} = Esr.Plugin.Loader.discover()
    {plugin_name, manifest} = List.first(manifests)
    schema = manifest.declares[:config_schema] || %{}

    if map_size(schema) == 0 do
      # Skip if manifest has no schema (pre-7.6 state).
      :ok
    else
      {key, _entry} = Enum.at(schema, 0)
      tmp_global = System.tmp_dir!() |> Path.join("plugin_set_test_global_#{:rand.uniform(999)}.yaml")
      on_exit(fn -> File.rm(tmp_global) end)

      cmd = %{
        "kind" => "plugin_set",
        "args" => %{
          "plugin" => plugin_name,
          "key" => key,
          "value" => "test-value",
          "layer" => "global",
          "_global_path_override" => tmp_global
        }
      }

      assert {:ok, %{"text" => text}} = Set.execute(cmd)
      assert String.contains?(text, "restart") or String.contains?(text, "config written")
    end
  end

  test "rejects key not in manifest config_schema" do
    # Works after Task 7.6 adds config_schema to feishu/claude_code.
    # Before 7.6: plugin has no schema and all keys are rejected.
    {:ok, manifests} = Esr.Plugin.Loader.discover()

    case List.first(manifests) do
      nil ->
        :ok

      {plugin_name, _manifest} ->
        tmp_global = System.tmp_dir!() |> Path.join("plugin_set_reject_#{:rand.uniform(999)}.yaml")
        on_exit(fn -> File.rm(tmp_global) end)

        cmd = %{
          "kind" => "plugin_set",
          "args" => %{
            "plugin" => plugin_name,
            "key" => "nonexistent_schema_key_xyz",
            "value" => "test",
            "layer" => "global",
            "_global_path_override" => tmp_global
          }
        }

        result = Set.execute(cmd)
        assert match?({:error, %{"type" => "unknown_config_key"}}, result) or
               match?({:error, %{"type" => "no_config_schema"}}, result),
               "Expected config key rejection, got: #{inspect(result)}"
    end
  end
end
```

- [ ] **Step 2 — Run failing tests.**

```bash
cd runtime && mix test test/esr/commands/plugin/set_test.exs 2>&1 | tail -15
```

- [ ] **Step 3 — Implement all four command modules.**

  **`runtime/lib/esr/commands/plugin/set.ex`:**

  ```elixir
  defmodule Esr.Commands.Plugin.Set do
    @moduledoc """
    `/plugin:set <plugin> key=<k> value=<v> [layer=global|user|workspace]`

    Writes a config key to the specified layer's plugins.yaml.
    Key must be declared in the plugin's manifest config_schema:.
    Default layer: global.

    Returns restart-required hint on success.

    Spec: docs/superpowers/specs/2026-05-07-metamodel-aligned-esr.md §6.
    """

    @behaviour Esr.Role.Control

    alias Esr.Plugin.Config
    alias Esr.Plugin.Loader

    @valid_layers ~w(global user workspace)

    @impl Esr.Role.Control
    def execute(%{"args" => args} = _cmd) do
      plugin_name = args["plugin"]
      key         = args["key"]
      value       = args["value"]
      layer_str   = args["layer"] || "global"

      with {:ok, manifest}  <- resolve_manifest(plugin_name),
           :ok              <- validate_config_key(manifest, key),
           {:ok, layer}     <- parse_layer(layer_str),
           {:ok, path_opts} <- resolve_path_opts(layer, args) do
        store_opts = [{:layer, layer} | path_opts]
        :ok = Config.store_layer(plugin_name, key, value, store_opts)

        {:ok, %{"text" => "config written: #{plugin_name}.#{key} = #{inspect(value)} [#{layer_str}]; restart esrd to apply"}}
      end
    end

    defp resolve_manifest(plugin_name) do
      case Loader.discover() do
        {:ok, manifests} ->
          case Enum.find(manifests, fn {name, _} -> name == plugin_name end) do
            nil -> {:error, %{"type" => "unknown_plugin", "plugin" => plugin_name}}
            {_, manifest} -> {:ok, manifest}
          end

        {:error, reason} ->
          {:error, %{"type" => "discovery_failed", "reason" => inspect(reason)}}
      end
    end

    defp validate_config_key(manifest, key) do
      schema = manifest.declares[:config_schema] || %{}

      cond do
        map_size(schema) == 0 ->
          {:error, %{"type" => "no_config_schema", "plugin" => manifest.name}}

        not Map.has_key?(schema, key) ->
          {:error, %{
            "type" => "unknown_config_key",
            "key" => key,
            "valid_keys" => Map.keys(schema)
          }}

        true ->
          :ok
      end
    end

    defp parse_layer(layer_str) when layer_str in @valid_layers do
      {:ok, String.to_atom(layer_str)}
    end

    defp parse_layer(layer_str) do
      {:error, %{"type" => "invalid_layer", "layer" => layer_str, "valid" => @valid_layers}}
    end

    defp resolve_path_opts(:global, args) do
      path = args["_global_path_override"] || Esr.Paths.global_plugins_yaml()
      {:ok, [global_path: path]}
    end

    defp resolve_path_opts(:user, args) do
      user_uuid = args["user_uuid"]

      if is_binary(user_uuid) and user_uuid != "" do
        path = args["_user_path_override"] || Esr.Paths.user_plugins_yaml(user_uuid)
        {:ok, [user_path: path]}
      else
        {:error, %{"type" => "user_uuid_required", "message" => "layer=user requires user_uuid"}}
      end
    end

    defp resolve_path_opts(:workspace, args) do
      workspace_id = args["workspace_id"]

      if is_binary(workspace_id) and workspace_id != "" do
        path = args["_workspace_path_override"] || workspace_plugins_yaml(workspace_id)
        {:ok, [workspace_path: path]}
      else
        {:error, %{"type" => "workspace_id_required", "message" => "layer=workspace requires workspace_id"}}
      end
    end

    defp workspace_plugins_yaml(workspace_id) do
      case Esr.Resource.Workspace.Registry.lookup(workspace_id) do
        {:ok, ws} -> Path.join([ws.folders |> List.first(""), ".esr", "plugins.yaml"])
        _ -> raise "workspace not found: #{workspace_id}"
      end
    end
  end
  ```

  **`runtime/lib/esr/commands/plugin/unset.ex`:**

  ```elixir
  defmodule Esr.Commands.Plugin.Unset do
    @moduledoc """
    `/plugin:unset <plugin> key [layer=global|user|workspace]`

    Removes a config key from the specified layer's plugins.yaml.
    Idempotent. Default layer: global.

    Spec: docs/superpowers/specs/2026-05-07-metamodel-aligned-esr.md §6.
    """

    @behaviour Esr.Role.Control

    alias Esr.Plugin.Config
    alias Esr.Plugin.Loader

    @valid_layers ~w(global user workspace)

    @impl Esr.Role.Control
    def execute(%{"args" => args} = _cmd) do
      plugin_name = args["plugin"]
      key         = args["key"]
      layer_str   = args["layer"] || "global"

      with {:ok, _manifest} <- resolve_manifest(plugin_name),
           {:ok, layer}     <- parse_layer(layer_str),
           {:ok, path_opts} <- resolve_path_opts(layer, args) do
        delete_opts = [{:layer, layer} | path_opts]
        :ok = Config.delete_layer(plugin_name, key, delete_opts)

        {:ok, %{"text" => "config key #{key} removed from #{plugin_name} [#{layer_str}]; restart esrd to apply"}}
      end
    end

    defp resolve_manifest(plugin_name) do
      case Loader.discover() do
        {:ok, manifests} ->
          case Enum.find(manifests, fn {name, _} -> name == plugin_name end) do
            nil -> {:error, %{"type" => "unknown_plugin", "plugin" => plugin_name}}
            {_, manifest} -> {:ok, manifest}
          end

        {:error, reason} ->
          {:error, %{"type" => "discovery_failed", "reason" => inspect(reason)}}
      end
    end

    defp parse_layer(layer_str) when layer_str in @valid_layers, do: {:ok, String.to_atom(layer_str)}
    defp parse_layer(layer_str) do
      {:error, %{"type" => "invalid_layer", "layer" => layer_str, "valid" => @valid_layers}}
    end

    defp resolve_path_opts(:global, args) do
      path = args["_global_path_override"] || Esr.Paths.global_plugins_yaml()
      {:ok, [global_path: path]}
    end

    defp resolve_path_opts(:user, args) do
      user_uuid = args["user_uuid"]
      if is_binary(user_uuid) and user_uuid != "" do
        path = args["_user_path_override"] || Esr.Paths.user_plugins_yaml(user_uuid)
        {:ok, [user_path: path]}
      else
        {:error, %{"type" => "user_uuid_required"}}
      end
    end

    defp resolve_path_opts(:workspace, args) do
      workspace_id = args["workspace_id"]
      if is_binary(workspace_id) and workspace_id != "" do
        path = args["_workspace_path_override"] || workspace_plugins_yaml(workspace_id)
        {:ok, [workspace_path: path]}
      else
        {:error, %{"type" => "workspace_id_required"}}
      end
    end

    defp workspace_plugins_yaml(workspace_id) do
      case Esr.Resource.Workspace.Registry.lookup(workspace_id) do
        {:ok, ws} -> Path.join([ws.folders |> List.first(""), ".esr", "plugins.yaml"])
        _ -> raise "workspace not found: #{workspace_id}"
      end
    end
  end
  ```

  **`runtime/lib/esr/commands/plugin/show_config.ex`:**

  ```elixir
  defmodule Esr.Commands.Plugin.ShowConfig do
    @moduledoc """
    `/plugin:show-config <plugin> [layer=effective|global|user|workspace]`

    Show plugin config at the specified layer (default: effective = merged result).

    Spec: docs/superpowers/specs/2026-05-07-metamodel-aligned-esr.md §6.
    """

    @behaviour Esr.Role.Control

    alias Esr.Plugin.Config

    @impl Esr.Role.Control
    def execute(%{"args" => args} = _cmd) do
      plugin_name = args["plugin"]
      layer_str   = args["layer"] || "effective"

      path_opts = build_path_opts(args)

      config =
        case layer_str do
          "effective" ->
            Config.resolve(plugin_name, path_opts)

          layer when layer in ~w(global user workspace) ->
            layer_opt_key = :"#{layer}_path"
            path = Keyword.get(path_opts, layer_opt_key)
            if path, do: Config.resolve(plugin_name, [{layer_opt_key, path}]), else: %{}

          _ ->
            %{}
        end

      text = render_config(plugin_name, layer_str, config)
      {:ok, %{"text" => text}}
    end

    defp build_path_opts(args) do
      [
        global_path:    args["_global_path_override"]    || Esr.Paths.global_plugins_yaml(),
        user_path:      args["_user_path_override"],
        workspace_path: args["_workspace_path_override"]
      ]
      |> Enum.reject(fn {_, v} -> is_nil(v) end)
    end

    defp render_config(plugin_name, layer, config) when map_size(config) == 0 do
      "#{plugin_name} config [#{layer}]: (empty)"
    end

    defp render_config(plugin_name, layer, config) do
      rows =
        config
        |> Enum.sort_by(fn {k, _} -> k end)
        |> Enum.map_join("\n", fn {k, v} -> "  #{k} = #{inspect(v)}" end)

      "#{plugin_name} config [#{layer}]:\n#{rows}"
    end
  end
  ```

  **`runtime/lib/esr/commands/plugin/list_config.ex`:**

  ```elixir
  defmodule Esr.Commands.Plugin.ListConfig do
    @moduledoc """
    `/plugin:list-config`

    Show effective config for all enabled plugins.

    Spec: docs/superpowers/specs/2026-05-07-metamodel-aligned-esr.md §6.
    """

    @behaviour Esr.Role.Control

    alias Esr.Plugin.Config
    alias Esr.Plugin.EnabledList

    @impl Esr.Role.Control
    def execute(_cmd) do
      enabled = EnabledList.list() || []

      global_path = Esr.Paths.global_plugins_yaml()

      text =
        enabled
        |> Enum.map(fn plugin_name ->
          config = Config.resolve(plugin_name, global_path: global_path)

          if map_size(config) == 0 do
            "#{plugin_name}: (no config)"
          else
            rows =
              config
              |> Enum.sort_by(fn {k, _} -> k end)
              |> Enum.map_join("\n", fn {k, v} -> "    #{k} = #{inspect(v)}" end)

            "#{plugin_name}:\n#{rows}"
          end
        end)
        |> Enum.join("\n\n")

      {:ok, %{"text" => "Plugin effective config:\n\n#{text}"}}
    end
  end
  ```

  **Also:** remove `@phase_7_modules` guard in `registry_test.exs` (Task 6.2) now that these modules exist.

- [ ] **Step 4 — Run passing tests.**

```bash
cd runtime && mix test test/esr/commands/plugin/ 2>&1 | tail -15
```

- [ ] **Step 5 — Commit.**

```bash
git add runtime/lib/esr/commands/plugin/set.ex \
        runtime/lib/esr/commands/plugin/unset.ex \
        runtime/lib/esr/commands/plugin/show_config.ex \
        runtime/lib/esr/commands/plugin/list_config.ex \
        runtime/test/esr/commands/plugin/set_test.exs \
        runtime/test/esr/commands/plugin/unset_test.exs \
        runtime/test/esr/commands/plugin/show_config_test.exs \
        runtime/test/esr/resource/slash_route/registry_test.exs
git commit -m "feat(plugin): /plugin:set + /plugin:unset + /plugin:show-config + /plugin:list-config command modules (Phase 7.5)"
```

---

### Task 7.6: Feishu + claude_code manifest `config_schema:` migration

**Files:**
- Modify: `runtime/lib/esr/plugins/feishu/manifest.yaml`
- Modify: `runtime/lib/esr/plugins/claude_code/manifest.yaml`
- Modify: `runtime/lib/esr/entity/feishu_app_adapter.ex` (or wherever `FEISHU_APP_ID` is read)
- Create: `runtime/test/esr/plugins/feishu/config_migration_test.exs`

**Goal:** Add `config_schema:` to both manifests. Update `feishu_app_adapter.ex` to read `app_id`
and `app_secret` from `Esr.Plugin.Config.get/3` with a fallback to `System.get_env/1` for backward
compatibility. Phase 8 removes the env-var fallback; Phase 7 merely adds the config-based path.

- [ ] **Step 1 — Write failing test.** Create `runtime/test/esr/plugins/feishu/config_migration_test.exs`:

```elixir
defmodule Esr.Plugins.Feishu.ConfigMigrationTest do
  use ExUnit.Case, async: true

  alias Esr.Plugin.Manifest

  @feishu_manifest_path Path.expand(
    "../../../../lib/esr/plugins/feishu/manifest.yaml",
    __DIR__
  )

  @cc_manifest_path Path.expand(
    "../../../../lib/esr/plugins/claude_code/manifest.yaml",
    __DIR__
  )

  describe "feishu manifest config_schema" do
    test "feishu manifest has config_schema with app_id" do
      {:ok, manifest} = Manifest.parse(@feishu_manifest_path)
      schema = manifest.declares[:config_schema] || %{}
      assert Map.has_key?(schema, "app_id"),
             "feishu manifest missing app_id in config_schema"
    end

    test "feishu manifest has config_schema with app_secret" do
      {:ok, manifest} = Manifest.parse(@feishu_manifest_path)
      schema = manifest.declares[:config_schema] || %{}
      assert Map.has_key?(schema, "app_secret"),
             "feishu manifest missing app_secret in config_schema"
    end

    test "feishu manifest has config_schema with log_level" do
      {:ok, manifest} = Manifest.parse(@feishu_manifest_path)
      schema = manifest.declares[:config_schema] || %{}
      assert Map.has_key?(schema, "log_level"),
             "feishu manifest missing log_level in config_schema"
    end

    test "feishu config_schema entries have required fields" do
      {:ok, manifest} = Manifest.parse(@feishu_manifest_path)
      schema = manifest.declares[:config_schema] || %{}

      Enum.each(schema, fn {key, entry} ->
        assert Map.has_key?(entry, "type"),        "feishu config_schema.#{key} missing type"
        assert Map.has_key?(entry, "description"), "feishu config_schema.#{key} missing description"
        assert Map.has_key?(entry, "default"),     "feishu config_schema.#{key} missing default"
      end)
    end
  end

  describe "claude_code manifest config_schema" do
    test "claude_code manifest has config_schema with http_proxy" do
      {:ok, manifest} = Manifest.parse(@cc_manifest_path)
      schema = manifest.declares[:config_schema] || %{}
      assert Map.has_key?(schema, "http_proxy"),
             "claude_code manifest missing http_proxy in config_schema"
    end

    test "claude_code manifest has config_schema with anthropic_api_key_ref" do
      {:ok, manifest} = Manifest.parse(@cc_manifest_path)
      schema = manifest.declares[:config_schema] || %{}
      assert Map.has_key?(schema, "anthropic_api_key_ref"),
             "claude_code manifest missing anthropic_api_key_ref"
    end

    test "claude_code manifest has config_schema with esrd_url" do
      {:ok, manifest} = Manifest.parse(@cc_manifest_path)
      schema = manifest.declares[:config_schema] || %{}
      assert Map.has_key?(schema, "esrd_url"),
             "claude_code manifest missing esrd_url in config_schema"
    end
  end

  describe "feishu plugin boots with config from layered yaml" do
    test "FeishuAppAdapter.get_app_id/1 reads from Plugin.Config before env var" do
      # Confirm the read function exists and is exported.
      assert function_exported?(Esr.Entity.FeishuAppAdapter, :get_app_id, 1) or
             function_exported?(Esr.Entity.FeishuAppAdapter, :get_app_id, 0),
             "FeishuAppAdapter must export get_app_id/0 or get_app_id/1 after Phase 7.6"
    end
  end
end
```

- [ ] **Step 2 — Run failing test.**

```bash
cd runtime && mix test test/esr/plugins/feishu/config_migration_test.exs 2>&1 | tail -20
```

- [ ] **Step 3 — Update feishu manifest.** Add `config_schema:` to
`runtime/lib/esr/plugins/feishu/manifest.yaml`:

```yaml
config_schema:
  app_id:
    type: string
    description: "Feishu app ID (cli_xxx). Required for Feishu API calls."
    default: ""

  app_secret:
    type: string
    description: "Feishu app secret. Required for Feishu API calls. Do not commit to repo — set via /plugin:set feishu key=app_secret value=... or in global plugins.yaml."
    default: ""

  log_level:
    type: string
    description: "Log verbosity for the feishu adapter (debug|info|warning|error)."
    default: "info"
```

- [ ] **Step 4 — Update claude_code manifest.** Add `config_schema:` to
`runtime/lib/esr/plugins/claude_code/manifest.yaml`:

```yaml
config_schema:
  http_proxy:
    type: string
    description: "HTTP proxy URL for outbound Anthropic API requests. Empty string = no proxy."
    default: ""

  https_proxy:
    type: string
    description: "HTTPS proxy URL. Usually same as http_proxy."
    default: ""

  no_proxy:
    type: string
    description: "Comma-separated host/suffix list that bypasses the proxy."
    default: ""

  anthropic_api_key_ref:
    type: string
    description: "Env-var reference for the Anthropic API key, e.g. ${ANTHROPIC_API_KEY}. Resolved via System.get_env/1 at session-start."
    default: "${ANTHROPIC_API_KEY}"

  esrd_url:
    type: string
    description: "WebSocket URL of the esrd host. Controls the HTTP MCP endpoint."
    default: "ws://127.0.0.1:4001"
```

- [ ] **Step 5 — Add `get_app_id/0` accessor to `feishu_app_adapter.ex`.** Find the call sites for
`System.get_env("FEISHU_APP_ID")` and `System.get_env("FEISHU_APP_SECRET")`:

```bash
grep -rn 'FEISHU_APP_ID\|FEISHU_APP_SECRET\|FEISHU_VERIFICATION_TOKEN' \
  runtime/lib/esr/entity/ runtime/lib/esr/plugins/feishu/ 2>/dev/null
```

For each call site, wrap with a config-first lookup and env-var fallback:

```elixir
# Phase 7.6: read app_id from plugin config first; env var as fallback.
# Phase 8 removes the env-var fallback.
defp get_app_id(opts \\ []) do
  config_val = Esr.Plugin.Config.get("feishu", "app_id",
    [global_path: Esr.Paths.global_plugins_yaml()] ++ opts)

  if is_binary(config_val) and config_val != "" do
    config_val
  else
    System.get_env("FEISHU_APP_ID", "")
  end
end

defp get_app_secret(opts \\ []) do
  config_val = Esr.Plugin.Config.get("feishu", "app_secret",
    [global_path: Esr.Paths.global_plugins_yaml()] ++ opts)

  if is_binary(config_val) and config_val != "" do
    config_val
  else
    System.get_env("FEISHU_APP_SECRET", "")
  end
end
```

Replace `System.get_env("FEISHU_APP_ID")` with `get_app_id()` and
`System.get_env("FEISHU_APP_SECRET")` with `get_app_secret()` at each call site.

- [ ] **Step 6 — Run passing tests.**

```bash
cd runtime && mix test test/esr/plugins/feishu/config_migration_test.exs 2>&1 | tail -10
cd runtime && mix test 2>&1 | tail -20
```

- [ ] **Step 7 — Commit.**

```bash
git add runtime/lib/esr/plugins/feishu/manifest.yaml \
        runtime/lib/esr/plugins/claude_code/manifest.yaml \
        runtime/lib/esr/entity/feishu_app_adapter.ex \
        runtime/test/esr/plugins/feishu/config_migration_test.exs
git commit -m "feat(feishu+cc): manifest config_schema + Plugin.Config-first app_id/secret reads (Phase 7.6)"
```

---

### Phase 7 PR checklist

Before opening the PR:

- [ ] `cd runtime && mix test 2>&1 | tail -20` — all pass
- [ ] `grep -n "config_schema" runtime/lib/esr/plugins/feishu/manifest.yaml` — present
- [ ] `grep -n "config_schema" runtime/lib/esr/plugins/claude_code/manifest.yaml` — present
- [ ] `grep -n "check_core_version" runtime/lib/esr/plugin/loader.ex` — present in `start_plugin/2`
- [ ] `grep -n "satisfies?" runtime/lib/esr/plugin/version.ex` — present
- [ ] `cat runtime/lib/esr/plugin/config.ex | grep "def resolve"` — `resolve/2` exported
- [ ] Confirm `/plugin:set` + `/plugin:unset` + `/plugin:show-config` + `/plugin:list-config` are
  loadable: `grep -n "Esr.Commands.Plugin" runtime/priv/slash-routes.default.yaml | head -10`

```bash
git commit -m "feat: plugin-config 3-layer + manifest config_schema + depends_on.core SemVer (Phase 7)"
```

---

## Phase 8: Delete esr-cc.sh + e2e migration + post-deploy cleanup

**PR title:** `chore: delete esr-cc.sh + esr-cc.local.sh; elixir-native PTY launcher; e2e migration to plugin config (Phase 8)`
**Branch:** `feat/phase-8-delete-esr-cc-sh`
**Target:** `dev`
**Est LOC:** ~300 deleted + ~400 added
**Depends on:** Phase 7

**Spec ref:** `docs/superpowers/specs/2026-05-07-metamodel-aligned-esr.md` §6 (shell-script deletion map), §7 (Phase 8 row), §11 (post-deploy migration steps), §14 (Phase 8 invariant).

**Invariant gate (spec §14):**
```bash
# Both of these must be true before PR opens:
[[ ! -f scripts/esr-cc.sh ]] && echo "PASS: esr-cc.sh deleted"
[[ ! -f scripts/esr-cc.local.sh ]] && echo "PASS: esr-cc.local.sh deleted"
make e2e 2>&1 | tail -5   # all scenarios 01-13 pass
```

---

### Task 8.1: Delete `scripts/esr-cc.sh` + `scripts/esr-cc.local.sh` + `scripts/esr-cc.local.sh.example`

**Files deleted:**
- `scripts/esr-cc.sh`
- `scripts/esr-cc.local.sh`
- `scripts/esr-cc.local.sh.example`

**Files to audit for references (from spec §6 shell-script deletion map):**
- `runtime/lib/esr/entity/pty_process.ex` — line ~350
- `runtime/lib/esr/entity/unbound_chat_guard.ex` — line ~104
- `runtime/test/esr/commands/workspace/info_test.exs` — line ~22
- `runtime/test/esr/resource/workspace_registry_test.exs` — line ~20
- `scripts/final_gate.sh` — line ~342
- `tests/e2e/scenarios/07_pty_bidir.sh` — line ~48
- `docs/dev-guide.md` — lines ~37, ~212
- `docs/cookbook.md` — line ~74

- [ ] **Step 1 — Write failing test.** Create `runtime/test/esr/entity/pty_process_launcher_test.exs` — assert `Esr.Entity.PtyProcess.launcher_script_path/0` does NOT return a path ending in `esr-cc.sh`:

```elixir
defmodule Esr.Entity.PtyProcessLauncherTest do
  use ExUnit.Case, async: true

  test "launcher does not reference deleted esr-cc.sh" do
    # PtyProcess must use Esr.Plugins.ClaudeCode.Launcher, not a shell script.
    # This test fails until Task 8.2 replaces the shell-script reference.
    refute function_exported?(Esr.Entity.PtyProcess, :launcher_script_path, 0),
           "launcher_script_path/0 must be removed; use ClaudeCode.Launcher instead"
  end
end
```

- [ ] **Step 2 — Run failing test.** Confirm it fails (or is currently green because the function doesn't exist — in which case skip to step 3).

```bash
cd runtime && mix test test/esr/entity/pty_process_launcher_test.exs 2>&1 | tail -10
```

- [ ] **Step 3 — Delete the three files.**

```bash
git rm scripts/esr-cc.sh scripts/esr-cc.local.sh scripts/esr-cc.local.sh.example
```

- [ ] **Step 4 — Grep and patch reference sites.** For each file referencing `esr-cc.sh`, replace the script path with a placeholder comment `# esr-cc.sh deleted (Phase 8) — see Esr.Plugins.ClaudeCode.Launcher` so CI does not hard-fail before Task 8.2 lands the full replacement. Do NOT add fallback defaults.

```bash
grep -rn "esr-cc" runtime/ scripts/ tests/ docs/ 2>/dev/null | grep -v ".git"
```

- [ ] **Step 5 — Run test + commit.**

```bash
cd runtime && mix test test/esr/entity/pty_process_launcher_test.exs 2>&1 | tail -10
git add -p
git commit -m "chore: delete esr-cc shell scripts (Phase 8.1) — superseded by plugin config (Phase 7)"
```

---

### Task 8.2: `Esr.Plugins.ClaudeCode.Launcher` — Elixir-native PTY launcher

**Files:**
- Create: `runtime/lib/esr/plugins/claude_code/launcher.ex`
- Create: `runtime/test/esr/plugins/claude_code/launcher_test.exs`
- Modify: `runtime/lib/esr/entity/pty_process.ex` — call `ClaudeCode.Launcher.build_env/1` instead of sourcing `esr-cc.sh`

**Responsibility migration (spec §6 shell-script deletion map):**

| Was in `esr-cc.sh` | Moves to |
|---|---|
| `http_proxy`, `https_proxy`, `no_proxy` exports | `Esr.Plugin.Config.resolve("claude_code", ...)["http_proxy"]` etc. |
| `ANTHROPIC_API_KEY` / `.mcp.env` source | Launchd plist; `claude_code.config.anthropic_api_key_ref` |
| `ESR_ESRD_URL` | `Esr.Plugin.Config.resolve("claude_code", ...)["esrd_url"]` |
| `exec claude` + `CLAUDE_FLAGS` construction | `ClaudeCode.Launcher.spawn_cmd/1` |
| `session-ids.yaml` resume lookup | Elixir lookup before PTY spawn |
| `.mcp.json` write | `ClaudeCode.Launcher.write_mcp_json/1` |
| Workspace trust pre-write to `~/.claude.json` | Elixir `File.write/2` before spawn |
| `mkdir -p "$cwd"` | `File.mkdir_p!/1` before spawn |
| `ESR_WORKSPACE`, `ESR_SESSION_ID` | PtyProcess spawn env (already set by BEAM) |

- [ ] **Step 1 — Write failing tests.** Create `runtime/test/esr/plugins/claude_code/launcher_test.exs`:

```elixir
defmodule Esr.Plugins.ClaudeCode.LauncherTest do
  use ExUnit.Case, async: true
  alias Esr.Plugins.ClaudeCode.Launcher

  @session_id "a1b2c3d4-e5f6-4a7b-8c9d-e0f1a2b3c4d5"

  describe "build_env/1" do
    test "includes http_proxy from plugin config" do
      # Stub Plugin.Config so test does not need a running daemon
      opts = [
        plugin_config: %{
          "http_proxy"  => "http://test-proxy:3128",
          "https_proxy" => "http://test-proxy:3128",
          "no_proxy"    => "localhost,127.0.0.1",
          "esrd_url"    => "ws://127.0.0.1:4001"
        },
        session_id: @session_id
      ]
      env = Launcher.build_env(opts)
      assert Keyword.get(env, :http_proxy)  == "http://test-proxy:3128"
      assert Keyword.get(env, :https_proxy) == "http://test-proxy:3128"
      assert Keyword.get(env, :no_proxy)    == "localhost,127.0.0.1"
    end

    test "empty http_proxy does not inject env var" do
      opts = [
        plugin_config: %{
          "http_proxy"  => "",
          "https_proxy" => "",
          "no_proxy"    => "",
          "esrd_url"    => "ws://127.0.0.1:4001"
        },
        session_id: @session_id
      ]
      env = Launcher.build_env(opts)
      refute Keyword.has_key?(env, :http_proxy),
             "empty http_proxy must not be injected"
    end

    test "includes ESR_ESRD_URL from plugin config esrd_url" do
      opts = [
        plugin_config: %{"http_proxy" => "", "https_proxy" => "", "no_proxy" => "",
                         "esrd_url" => "ws://10.0.0.1:4001"},
        session_id: @session_id
      ]
      env = Launcher.build_env(opts)
      assert Keyword.get(env, :ESR_ESRD_URL) == "ws://10.0.0.1:4001"
    end
  end

  describe "write_mcp_json/1" do
    test "writes .mcp.json to workspace cwd" do
      tmp = System.tmp_dir!() |> Path.join("launcher-test-#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp)
      on_exit(fn -> File.rm_rf!(tmp) end)

      :ok = Launcher.write_mcp_json(cwd: tmp, esrd_url: "ws://127.0.0.1:4001", session_id: @session_id)
      mcp_path = Path.join(tmp, ".mcp.json")
      assert File.exists?(mcp_path)
      {:ok, body} = File.read(mcp_path)
      decoded = Jason.decode!(body)
      assert is_map(decoded["mcpServers"])
    end
  end
end
```

- [ ] **Step 2 — Run failing test.** Confirm `Esr.Plugins.ClaudeCode.Launcher is not available`.

```bash
cd runtime && mix test test/esr/plugins/claude_code/launcher_test.exs 2>&1 | tail -10
```

- [ ] **Step 3 — Implement `Launcher`.** Create `runtime/lib/esr/plugins/claude_code/launcher.ex`:

```elixir
defmodule Esr.Plugins.ClaudeCode.Launcher do
  @moduledoc """
  Elixir-native launcher for the Claude Code agent process.

  Replaces `scripts/esr-cc.sh` (deleted Phase 8). All env-var construction and
  pre-spawn filesystem operations are performed here in Elixir before PtyProcess
  is asked to exec the `claude` binary.

  Spec: docs/superpowers/specs/2026-05-07-metamodel-aligned-esr.md §6 (shell-script deletion map).
  """

  alias Esr.Plugin.Config

  @claude_binary System.find_executable("claude") || "claude"

  @doc """
  Build the OS environment keyword list to pass to PtyProcess.
  Only injects env vars for non-empty plugin config values (let-it-crash: no fallback defaults).

  Options:
    * `:plugin_config` — pre-resolved config map (from `Plugin.Config.resolve/2`). Required.
    * `:session_id`    — session UUID string. Required.
  """
  @spec build_env(keyword()) :: keyword()
  def build_env(opts) do
    config     = Keyword.fetch!(opts, :plugin_config)
    session_id = Keyword.fetch!(opts, :session_id)

    base = [ESR_SESSION_ID: session_id]

    base
    |> maybe_put(:http_proxy,  config["http_proxy"])
    |> maybe_put(:HTTP_PROXY,  config["http_proxy"])
    |> maybe_put(:https_proxy, config["https_proxy"])
    |> maybe_put(:HTTPS_PROXY, config["https_proxy"])
    |> maybe_put(:no_proxy,    config["no_proxy"])
    |> maybe_put(:NO_PROXY,    config["no_proxy"])
    |> maybe_put(:ESR_ESRD_URL, config["esrd_url"])
  end

  @doc """
  Write `.mcp.json` into `cwd` before spawning the PTY.

  Options:
    * `:cwd`        — workspace directory. Required.
    * `:esrd_url`   — WebSocket URL of the ESRD host. Required.
    * `:session_id` — session UUID string. Required.
  """
  @spec write_mcp_json(keyword()) :: :ok | {:error, term()}
  def write_mcp_json(opts) do
    cwd        = Keyword.fetch!(opts, :cwd)
    esrd_url   = Keyword.fetch!(opts, :esrd_url)
    session_id = Keyword.fetch!(opts, :session_id)

    content = Jason.encode!(%{
      "mcpServers" => %{
        "esr" => %{
          "type"    => "sse",
          "url"     => "#{esrd_url}/mcp/sse?session_id=#{session_id}",
          "headers" => %{}
        }
      }
    }, pretty: true)

    mcp_path = Path.join(cwd, ".mcp.json")
    File.write(mcp_path, content)
  end

  @doc """
  Return the resolved claude binary command and flag list.
  Does NOT exec — just builds the argv. PtyProcess calls exec.
  """
  @spec spawn_cmd(keyword()) :: [String.t()]
  def spawn_cmd(_opts) do
    [@claude_binary]
  end

  @doc """
  Full pre-spawn sequence:
    1. mkdir_p workspace cwd
    2. write .mcp.json
    3. return {cmd, env} tuple for PtyProcess
  """
  @spec prepare_spawn(keyword()) :: {:ok, {[String.t()], keyword()}} | {:error, term()}
  def prepare_spawn(opts) do
    cwd        = Keyword.fetch!(opts, :cwd)
    session_id = Keyword.fetch!(opts, :session_id)
    config     = resolve_plugin_config(opts)

    with :ok <- File.mkdir_p(cwd),
         :ok <- write_mcp_json(cwd: cwd, esrd_url: config["esrd_url"] || "", session_id: session_id) do
      env = build_env(plugin_config: config, session_id: session_id)
      cmd = spawn_cmd(opts)
      {:ok, {cmd, env}}
    end
  end

  # -------------------------------------------------------------------
  # Private helpers
  # -------------------------------------------------------------------

  defp maybe_put(env, _key, value) when is_nil(value), do: env
  defp maybe_put(env, _key, ""),    do: env
  defp maybe_put(env, key, value),  do: Keyword.put(env, key, value)

  defp resolve_plugin_config(opts) do
    case Keyword.fetch(opts, :plugin_config) do
      {:ok, cfg} -> cfg
      :error     -> Config.resolve("claude_code", Keyword.take(opts, [:user_uuid, :workspace_id]))
    end
  end
end
```

- [ ] **Step 4 — Update `pty_process.ex`.** Remove the `esr-cc.sh` invocation; call `ClaudeCode.Launcher.prepare_spawn/1` instead. Find the call site:

```bash
grep -n "esr-cc\|launcher_script" runtime/lib/esr/entity/pty_process.ex | head -10
```

Replace the shell-script exec block with:

```elixir
# Phase 8: esr-cc.sh deleted. Use Elixir-native launcher.
alias Esr.Plugins.ClaudeCode.Launcher
{:ok, {cmd, extra_env}} = Launcher.prepare_spawn(
  cwd: workspace_path,
  session_id: session_id,
  user_uuid: user_uuid
)
# Merge extra_env into the existing spawn env list
spawn_env = Keyword.merge(spawn_env, extra_env)
# cmd is ["/path/to/claude"]
```

- [ ] **Step 5 — Run tests + commit.**

```bash
cd runtime && mix test test/esr/plugins/claude_code/launcher_test.exs \
                       test/esr/entity/pty_process_launcher_test.exs 2>&1 | tail -20
git add runtime/lib/esr/plugins/claude_code/launcher.ex \
        runtime/test/esr/plugins/claude_code/launcher_test.exs \
        runtime/lib/esr/entity/pty_process.ex
git commit -m "feat(cc): Esr.Plugins.ClaudeCode.Launcher — elixir-native PTY launcher (Phase 8.2)"
```

---

### Task 8.3: e2e `common.sh` migration — replace `esr-cc.sh` sourcing with `seed_plugin_config`

**Files:**
- Modify: `tests/e2e/scenarios/common.sh`
- Modify: `tests/e2e/scenarios/07_pty_bidir.sh` (primary reference site, per spec §6)
- Modify: any other scenario referencing `esr-cc` (check with grep)

- [ ] **Step 1 — Write failing test.** Add a self-test assertion to `tests/e2e/scenarios/_common_selftest.sh` (or inline at top of `common.sh`) that `seed_plugin_config` function exists:

```bash
# In _common_selftest.sh or common.sh self-check block:
if ! declare -f seed_plugin_config > /dev/null 2>&1; then
  echo "FAIL: seed_plugin_config not defined in common.sh" >&2
  exit 1
fi
```

- [ ] **Step 2 — Run failing test.**

```bash
bash tests/e2e/scenarios/_common_selftest.sh 2>&1 | tail -5
```

- [ ] **Step 3 — Add `seed_plugin_config` to `common.sh`.** After the existing `seed_capabilities` / `seed_workspaces` functions, add:

```bash
# seed_plugin_config — write test plugin config to the 3-layer paths
# used by Esr.Plugin.Config so e2e scenarios do not source esr-cc.sh.
# Arg 1: optional extra YAML block to append to global plugins.yaml.
# Usage: seed_plugin_config  (no args → writes minimal config)
#        seed_plugin_config "$(cat <<'EOF'
# config:
#   claude_code:
#     http_proxy: "http://proxy.test:3128"
# EOF
# )"
seed_plugin_config() {
  local extra_yaml="${1:-}"
  local global_cfg="${ESRD_HOME}/${ESRD_INSTANCE}/plugins.yaml"

  mkdir -p "$(dirname "$global_cfg")"

  cat > "$global_cfg" <<YAML
enabled:
  - claude_code
  - feishu
config:
  claude_code:
    esrd_url: "ws://127.0.0.1:${ESRD_PORT:-4001}"
    http_proxy: ""
    https_proxy: ""
    no_proxy: ""
    anthropic_api_key_ref: "\${ANTHROPIC_API_KEY}"
  feishu:
    app_id: "${FEISHU_APP_ID:-cli_test}"
    app_secret: "${FEISHU_APP_SECRET:-test_secret}"
    log_level: "debug"
${extra_yaml}
YAML

  echo "[seed_plugin_config] wrote ${global_cfg}"
}
```

- [ ] **Step 4 — Remove `source scripts/esr-cc.sh` (and `esr-cc.local.sh`) calls.** Search and replace:

```bash
grep -n "esr-cc" tests/e2e/scenarios/common.sh tests/e2e/scenarios/*.sh 2>/dev/null
```

For each hit: delete the `source` line; add `seed_plugin_config` call in the setup block of that scenario (after `start_esrd`, before `wait_for_sidecar_ready`).

In `07_pty_bidir.sh` specifically (spec line ~48): replace the `esr-cc.sh` reference with:

```bash
# Phase 8: esr-cc.sh deleted. Plugin config is seeded via seed_plugin_config.
seed_plugin_config
```

- [ ] **Step 5 — Run tests + commit.**

```bash
bash tests/e2e/scenarios/_common_selftest.sh 2>&1 | tail -5
# Smoke-run scenario 07 (or lowest available) to confirm load-without-error:
bash tests/e2e/scenarios/07_pty_bidir.sh 2>&1 | tail -20
git add tests/e2e/scenarios/common.sh \
        tests/e2e/scenarios/07_pty_bidir.sh
git commit -m "e2e/common: replace esr-cc.sh sourcing with seed_plugin_config helper (Phase 8.3)"
```

---

### Task 8.4: Post-deploy cleanup script `tools/wipe-esrd-home.sh`

**Files:**
- Create: `tools/wipe-esrd-home.sh`
- Create: `tools/wipe-esrd-home_test.sh`

**Spec ref:** §11 — required wipe procedure (D7).

- [ ] **Step 1 — Write failing test.** Create `tools/wipe-esrd-home_test.sh`:

```bash
#!/usr/bin/env bash
# Smoke test for tools/wipe-esrd-home.sh — verifies dry-run exits 0 + prints target.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WIPE_SCRIPT="${SCRIPT_DIR}/wipe-esrd-home.sh"

[[ -f "$WIPE_SCRIPT" ]] || { echo "FAIL: wipe-esrd-home.sh not found"; exit 1; }
[[ -x "$WIPE_SCRIPT" ]] || { echo "FAIL: wipe-esrd-home.sh not executable"; exit 1; }

# Dry-run should print the target path and exit 0 without deleting anything.
TMP_HOME="$(mktemp -d /tmp/wipe-esrd-test-XXXXXX)"
touch "${TMP_HOME}/sentinel"

OUTPUT=$(ESRD_HOME="$TMP_HOME" bash "$WIPE_SCRIPT" --dry-run --dev 2>&1)
echo "$OUTPUT"

[[ -f "${TMP_HOME}/sentinel" ]] || { echo "FAIL: dry-run deleted files"; exit 1; }
echo "$OUTPUT" | grep -q "$TMP_HOME" || { echo "FAIL: dry-run did not print target path"; exit 1; }

rm -rf "$TMP_HOME"
echo "PASS: wipe-esrd-home_test.sh"
```

- [ ] **Step 2 — Run failing test.** Confirm it fails with `wipe-esrd-home.sh not found`.

```bash
bash tools/wipe-esrd-home_test.sh 2>&1
```

- [ ] **Step 3 — Implement `wipe-esrd-home.sh`.** Create `tools/wipe-esrd-home.sh`:

```bash
#!/usr/bin/env bash
# tools/wipe-esrd-home.sh
#
# PURPOSE: Run before first boot of metamodel-aligned ESR.
# Old ESRD_HOME state (workspaces.yaml, single-agent session state,
# username-keyed dirs) is incompatible with the new UUID-based layout.
# Bootstrap rebuilds all required directories from scratch on first boot.
#
# USAGE:
#   ./tools/wipe-esrd-home.sh [--dev | --prod] [--dry-run]
#
# OPTIONS:
#   --dev      Target $ESRD_HOME (defaults to ~/.esrd-dev if ESRD_HOME unset)
#   --prod     Target $ESRD_HOME (defaults to ~/.esrd if ESRD_HOME unset)
#   --dry-run  Print what would be deleted; do NOT delete.
#
# SPEC: docs/superpowers/specs/2026-05-07-metamodel-aligned-esr.md §11
set -euo pipefail

MODE="--dev"
DRY_RUN=false

for arg in "$@"; do
  case "$arg" in
    --dev)     MODE="--dev"  ;;
    --prod)    MODE="--prod" ;;
    --dry-run) DRY_RUN=true  ;;
    *)
      echo "Usage: $0 [--dev | --prod] [--dry-run]" >&2
      exit 1
      ;;
  esac
done

if [[ "$MODE" == "--dev" ]]; then
  TARGET="${ESRD_HOME:-${HOME}/.esrd-dev}"
elif [[ "$MODE" == "--prod" ]]; then
  TARGET="${ESRD_HOME:-${HOME}/.esrd}"
fi

echo "Target: ${TARGET}"
echo "Mode:   ${MODE#--}"

if [[ "$DRY_RUN" == "true" ]]; then
  echo "[dry-run] Would delete all contents of: ${TARGET}"
  echo "[dry-run] The directory itself is preserved. ESR bootstrap rebuilds on first boot."
  exit 0
fi

echo ""
echo "WARNING: This will destroy all sessions, workspaces, and plugin configs in:"
echo "  ${TARGET}"
echo "Ensure any needed data (workspace folders, plugin keys) is noted elsewhere first."
echo ""
read -rp "Type 'yes' to confirm wipe: " confirm
if [[ "$confirm" != "yes" ]]; then
  echo "Aborted."
  exit 1
fi

if [[ ! -d "$TARGET" ]]; then
  echo "Directory does not exist; nothing to wipe: ${TARGET}"
  exit 0
fi

# Remove contents but preserve the directory itself.
# Bootstrap expects the directory to exist; it creates subdirs on first boot.
find "$TARGET" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
echo "Wiped: ${TARGET}"
echo "Start esrd to rebuild from Bootstrap."
```

```bash
chmod +x tools/wipe-esrd-home.sh
```

- [ ] **Step 4 — Run test.**

```bash
bash tools/wipe-esrd-home_test.sh 2>&1 | tail -5
```

- [ ] **Step 5 — Run `make e2e` baseline (invariant gate).**

```bash
make e2e 2>&1 | tail -20
# Expected: all scenarios 01-13 pass (or document any pre-existing failures unrelated to Phase 8).
```

```bash
git add tools/wipe-esrd-home.sh tools/wipe-esrd-home_test.sh
git commit -m "tools: wipe-esrd-home.sh for post-deploy migration (Phase 8.4)"
```

---

### Phase 8 PR checklist

Before opening the PR:

- [ ] `[[ ! -f scripts/esr-cc.sh ]]` — deleted
- [ ] `[[ ! -f scripts/esr-cc.local.sh ]]` — deleted
- [ ] `[[ ! -f scripts/esr-cc.local.sh.example ]]` — deleted
- [ ] `grep -rn "esr-cc.sh" runtime/ tests/ scripts/ docs/ 2>/dev/null | grep -v ".git" | grep -v "PLAN_END"` — zero hits outside historical docs
- [ ] `cd runtime && mix test 2>&1 | tail -20` — all pass
- [ ] `bash tests/e2e/scenarios/_common_selftest.sh` — PASS
- [ ] `bash tools/wipe-esrd-home_test.sh` — PASS
- [ ] `make e2e 2>&1 | tail -5` — scenarios 01-13 pass

```bash
git commit -m "chore: delete esr-cc.sh + esr-cc.local.sh; elixir-native PTY launcher; e2e migration to plugin config (Phase 8)"
```

---

## Phase 9: Docs sweep + e2e scenarios 14, 15, 16

**PR title:** `docs+test: e2e scenarios 14-16 + docs sweep colon-namespace + session-first surface (Phase 9)`
**Branch:** `feat/phase-9-docs-e2e`
**Target:** `dev`
**Est LOC:** ~400
**Depends on:** Phase 8

**Spec ref:** §4 (slash surface), §7 (Phase 9 row), §9 (e2e 14/15/16), §14 (Phase 9 invariant).

**Invariant gate (spec §14):**
```bash
# Scenarios 14 and 15 must pass:
bash tests/e2e/scenarios/14_session_multiagent.sh 2>&1 | tail -5
bash tests/e2e/scenarios/15_session_share.sh 2>&1 | tail -5
```

---

### Task 9.1: Docs sweep — colon-namespace + session-first surface

**Scope:** Update advisory docs to reflect hard-cutover slash names and session-first surface. Leave historical migration notes untouched.

- [ ] **Step 1 — Inventory references.**

```bash
grep -rln '"/new-session\|/list-agents\|/workspace info\|/plugin install\|/end-session' docs/ README*.md 2>/dev/null
grep -rln 'workspaces\.yaml' docs/ 2>/dev/null
grep -rln 'workspace\.root' docs/ 2>/dev/null
grep -rln 'esr-cc\.sh' docs/ 2>/dev/null
```

- [ ] **Step 2 — Update `docs/dev-guide.md`.** Replace:
  - `/new-session` → `/session:new`
  - `/end-session` → `/session:end`
  - `/list-agents` → `/session:list`
  - `workspaces.yaml` references → note it is superseded by `sessions/<uuid>/session.json`
  - `workspace.root` references → `session workspace at sessions/<uuid>/`
  - `esr-cc.sh` references → "deleted in Phase 8; see `tools/wipe-esrd-home.sh` and `Esr.Plugins.ClaudeCode.Launcher`"
  - Any `/plugin install` reference → `/plugin:set` / `/plugin:show-config`

- [ ] **Step 3 — Update `docs/cookbook.md`.** Same substitutions (spec identifies line ~74 as an `esr-cc.sh` reference).

- [ ] **Step 4 — Update `docs/manual-checks/` entries.** Check for any stale slash names.

- [ ] **Step 5 — Update `docs/futures/todo.md`.** Remove any tasks that are now complete (e.g., "implement colon-namespace", "3-layer plugin config").

- [ ] **Step 6 — Verify sweep is complete.**

```bash
grep -rn '/new-session\|/end-session\|/list-agents\|esr-cc\.sh' docs/ README*.md 2>/dev/null \
  | grep -v "historical\|migration\|PLAN_END\|2026-04\|2026-03\|PR-7\|PR-8\|PR-9\|PR-21\|PR-22\|PR-23\|PR-24\|PR-230" \
  | grep -v ".git"
# Expected: zero hits (or only in clearly-labelled historical sections)
```

- [ ] **Step 7 — Commit.**

```bash
git add docs/
git commit -m "docs: sweep — colon-namespace + session-first surface (Phase 9.1)"
```

---

### Task 9.2: e2e scenario 14 — multi-agent session

**File:** `tests/e2e/scenarios/14_session_multiagent.sh`

**Spec ref:** §9 e2e Scenario 14.

**Scenario steps:**
1. Init test ESRD_HOME; seed plugin config; seed capabilities; start mock Feishu + esrd.
2. Create session: `esr admin submit session_new name=multi-test` → capture `$SID`.
3. Add agent alice: `esr admin submit session_add_agent session_id=$SID type=cc name=alice`.
4. Add agent bob: `esr admin submit session_add_agent session_id=$SID type=cc name=bob`.
5. Verify session info: `session_info session_id=$SID` → assert `primary_agent=alice` (first added).
6. Send `@alice ping` via Feishu → assert reply routed to alice (contains "alice").
7. Send `@bob hello` → assert reply routed to bob.
8. Send plain text (no `@`) → assert routed to primary (alice).
9. Set primary: `esr admin submit session_set_primary session_id=$SID name=bob`.
10. Send plain text again → assert routed to bob (new primary).
11. Cleanup: end session + stop processes.

- [ ] **Step 1 — Write failing test.** Create `tests/e2e/scenarios/14_session_multiagent.sh`:

```bash
#!/usr/bin/env bash
# e2e scenario 14 — multi-agent session: @<name> routing + primary fallback.
# Spec: docs/superpowers/specs/2026-05-07-metamodel-aligned-esr.md §9 Scenario 14.
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./common.sh
source "${SCRIPT_DIR}/common.sh"

# --- setup ------------------------------------------------------------
seed_plugin_config
seed_capabilities
seed_workspaces
seed_adapters
start_mock_feishu
start_esrd
wait_for_sidecar_ready 30

# --- step 1: create session -------------------------------------------
SID=$(esr_cli admin submit session_new \
  --arg name=multi-test \
  --arg submitter="${ESR_OPERATOR_PRINCIPAL_ID}" \
  --wait --timeout 30 \
  | awk -F': ' '/^session_id:/ {print $2; exit}')
[[ -n "$SID" ]] || _fail_with_context "14: no session_id from session_new"
echo "14: session created: $SID"

# --- step 2: add alice ------------------------------------------------
esr_cli admin submit session_add_agent \
  --arg session_id="$SID" --arg type=cc --arg name=alice \
  --arg submitter="${ESR_OPERATOR_PRINCIPAL_ID}" \
  --wait --timeout 20 > /dev/null
echo "14: added agent alice"

# --- step 3: add bob --------------------------------------------------
esr_cli admin submit session_add_agent \
  --arg session_id="$SID" --arg type=cc --arg name=bob \
  --arg submitter="${ESR_OPERATOR_PRINCIPAL_ID}" \
  --wait --timeout 20 > /dev/null
echo "14: added agent bob"

# --- step 4: verify primary = alice (first added) ---------------------
INFO=$(esr_cli admin submit session_info \
  --arg session_id="$SID" \
  --arg submitter="${ESR_OPERATOR_PRINCIPAL_ID}" \
  --wait --timeout 15)
assert_contains "$INFO" '"primary_agent":"alice"' \
  "14: primary_agent should be alice (first added)"
assert_contains "$INFO" '"name":"bob"' \
  "14: bob should appear in agents list"
echo "14: primary_agent=alice confirmed"

# --- step 5: @alice routing -------------------------------------------
REPLY=$(push_inbound_feishu "@alice ping" "${ESR_OPERATOR_PRINCIPAL_ID}" 30)
assert_contains "$REPLY" "alice" \
  "14: @alice message should route to alice"
echo "14: @alice routing confirmed"

# --- step 6: @bob routing ---------------------------------------------
REPLY=$(push_inbound_feishu "@bob hello" "${ESR_OPERATOR_PRINCIPAL_ID}" 30)
assert_contains "$REPLY" "bob" \
  "14: @bob message should route to bob"
echo "14: @bob routing confirmed"

# --- step 7: plain text → primary (alice) ----------------------------
REPLY=$(push_inbound_feishu "plain message no mention" "${ESR_OPERATOR_PRINCIPAL_ID}" 30)
assert_contains "$REPLY" "alice" \
  "14: plain text should route to primary (alice)"
echo "14: plain→primary routing confirmed"

# --- step 8: set primary to bob --------------------------------------
esr_cli admin submit session_set_primary \
  --arg session_id="$SID" --arg name=bob \
  --arg submitter="${ESR_OPERATOR_PRINCIPAL_ID}" \
  --wait --timeout 15 > /dev/null
echo "14: set_primary=bob"

# --- step 9: plain text now → bob ------------------------------------
REPLY=$(push_inbound_feishu "another plain message" "${ESR_OPERATOR_PRINCIPAL_ID}" 30)
assert_contains "$REPLY" "bob" \
  "14: after set_primary=bob, plain text should route to bob"
echo "14: new-primary routing confirmed"

# --- cleanup ----------------------------------------------------------
esr_cli admin submit session_end \
  --arg session_id="$SID" \
  --arg submitter="${ESR_OPERATOR_PRINCIPAL_ID}" \
  --wait --timeout 20 > /dev/null || true
stop_esrd
stop_mock_feishu

echo "PASS: 14_session_multiagent"
```

- [ ] **Step 2 — Run failing test.** Confirm it fails (missing admin submit verbs or missing routing implementation from Phase 3/4). Document which step it fails at.

```bash
bash tests/e2e/scenarios/14_session_multiagent.sh 2>&1 | tail -20
```

- [ ] **Step 3 — Implement missing submit verbs.** If `session_add_agent`, `session_set_primary`, or `session_info` are not yet wired as `esr admin submit` targets, add them to the escript dispatch table. Reference Phase 3/6 command modules.

```bash
grep -n "session_add_agent\|session_set_primary\|session_info" scripts/esrd.sh \
  runtime/lib/esr/ -r 2>/dev/null | head -20
```

- [ ] **Step 4 — Run passing test.**

```bash
bash tests/e2e/scenarios/14_session_multiagent.sh 2>&1 | tail -10
# Expected: "PASS: 14_session_multiagent"
```

- [ ] **Step 5 — Commit.**

```bash
git add tests/e2e/scenarios/14_session_multiagent.sh
git commit -m "e2e/14: multi-agent session — @name routing + primary fallback (Phase 9.2)"
```

---

### Task 9.3: e2e scenario 15 — cross-user session attach (UUID-only)

**File:** `tests/e2e/scenarios/15_session_share.sh`

**Spec ref:** §9 e2e Scenario 15.

**Scenario steps:**
1. Init test ESRD_HOME; seed plugin config; seed 2 users (alice + bob) with admin caps.
2. As alice: create session `shared-session` → capture `$SID`.
3. As alice: `/session:share $SID bob perm=attach` (grant bob `session:$SID/attach` cap).
4. As bob: attach to `$SID` from a different chat (`oc_bob_chat`).
5. Bob sends message → routed via shared session's primary agent.
6. Verify both alice's chat and bob's chat can see session (session info shows both attached chats).
7. As bob: detach (bob's chat leaves; alice's chat remains attached).
8. Verify session still active (not ended) with alice's chat in attached set.
9. Verify that attaching by SESSION NAME (not UUID) is rejected.
10. Cleanup.

- [ ] **Step 1 — Write failing test.** Create `tests/e2e/scenarios/15_session_share.sh`:

```bash
#!/usr/bin/env bash
# e2e scenario 15 — cross-user session attach: UUID-only + cap-gated permission.
# Spec: docs/superpowers/specs/2026-05-07-metamodel-aligned-esr.md §9 Scenario 15.
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./common.sh
source "${SCRIPT_DIR}/common.sh"

ALICE_CHAT="oc_alice_e2e_15"
BOB_CHAT="oc_bob_e2e_15"
CAROL_CHAT="oc_carol_e2e_15"

# --- setup ------------------------------------------------------------
seed_plugin_config
seed_capabilities
seed_workspaces
seed_adapters
start_mock_feishu
start_esrd
wait_for_sidecar_ready 30

# Seed alice + bob as users with their own caps.
esr_cli admin submit user_add --arg username=alice_15 --arg chat_id="$ALICE_CHAT" \
  --wait --timeout 15 > /dev/null || true
esr_cli admin submit user_add --arg username=bob_15 --arg chat_id="$BOB_CHAT" \
  --wait --timeout 15 > /dev/null || true

# --- step 1: alice creates session ------------------------------------
SID=$(esr_cli admin submit session_new \
  --arg name=shared-session \
  --arg submitter=alice_15 \
  --wait --timeout 30 \
  | awk -F': ' '/^session_id:/ {print $2; exit}')
[[ -n "$SID" ]] || _fail_with_context "15: no session_id from session_new"
echo "15: alice created session: $SID"

# Verify SID looks like a UUID (D2: UUID-only at input for session caps).
[[ "$SID" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] \
  || _fail_with_context "15: session_id is not a UUID v4: $SID"
echo "15: SID is valid UUID v4"

# --- step 2: alice shares with bob -----------------------------------
SHARE_OUT=$(esr_cli admin submit session_share \
  --arg session_id="$SID" --arg target_user=bob_15 --arg perm=attach \
  --arg submitter=alice_15 \
  --wait --timeout 15)
assert_contains "$SHARE_OUT" "ok" "15: session_share should succeed"
echo "15: alice shared session with bob"

# --- step 3: bob attaches (UUID, different chat) ---------------------
ATTACH_OUT=$(esr_cli admin submit session_attach \
  --arg session_id="$SID" --arg chat_id="$BOB_CHAT" \
  --arg submitter=bob_15 \
  --wait --timeout 15)
assert_contains "$ATTACH_OUT" "ok" "15: bob session_attach should succeed"
echo "15: bob attached to session"

# --- step 4: unauthorized user (carol) cannot attach ----------------
CAROL_OUT=$(esr_cli admin submit session_attach \
  --arg session_id="$SID" --arg chat_id="$CAROL_CHAT" \
  --arg submitter=carol_unknown \
  --wait --timeout 15 2>&1 || true)
assert_contains "$CAROL_OUT" "cap_check_failed" \
  "15: unauthorized user should get cap_check_failed"
echo "15: unauthorized attach rejected"

# --- step 5: name-based attach is REJECTED (D2, D5) -----------------
NAME_ATTACH_OUT=$(esr_cli admin submit session_attach \
  --arg session_id=shared-session --arg chat_id="$BOB_CHAT" \
  --arg submitter=bob_15 \
  --wait --timeout 15 2>&1 || true)
assert_contains "$NAME_ATTACH_OUT" "session caps require UUID" \
  "15: name-based session attach must be rejected"
echo "15: name-based attach rejected (UUID-only enforced)"

# --- step 6: both chats show in session info -------------------------
INFO=$(esr_cli admin submit session_info \
  --arg session_id="$SID" \
  --arg submitter=alice_15 \
  --wait --timeout 15)
assert_contains "$INFO" "$ALICE_CHAT" "15: alice's chat should be in session"
assert_contains "$INFO" "$BOB_CHAT"   "15: bob's chat should be in session"
echo "15: cross-user observability confirmed"

# --- step 7: bob detaches -------------------------------------------
DETACH_OUT=$(esr_cli admin submit session_detach \
  --arg session_id="$SID" --arg chat_id="$BOB_CHAT" \
  --arg submitter=bob_15 \
  --wait --timeout 15)
assert_contains "$DETACH_OUT" "ok" "15: bob detach should succeed"
echo "15: bob detached"

# --- step 8: session still active with alice's chat -----------------
INFO2=$(esr_cli admin submit session_info \
  --arg session_id="$SID" \
  --arg submitter=alice_15 \
  --wait --timeout 15)
assert_contains "$INFO2" "$ALICE_CHAT" "15: alice's chat should remain after bob detach"
# Bob's chat should no longer be in the attached set.
if echo "$INFO2" | grep -q "$BOB_CHAT"; then
  _fail_with_context "15: bob's chat should NOT appear in session info after detach"
fi
echo "15: session still active with alice only"

# --- cleanup ----------------------------------------------------------
esr_cli admin submit session_end \
  --arg session_id="$SID" --arg submitter=alice_15 \
  --wait --timeout 20 > /dev/null || true
stop_esrd
stop_mock_feishu

echo "PASS: 15_session_share"
```

- [ ] **Step 2 — Run failing test.** Confirm it fails (missing session_share / session_attach dispatch, or Phase 5 UUID enforcement not yet wired). Document failure step.

```bash
bash tests/e2e/scenarios/15_session_share.sh 2>&1 | tail -20
```

- [ ] **Step 3 — Wire any missing admin submit verbs.** Add `session_share`, `session_attach`, `session_detach` to escript dispatch if absent (these should have been added in Phase 6).

```bash
grep -n "session_share\|session_attach\|session_detach" scripts/esrd.sh \
  runtime/lib/esr/ -r 2>/dev/null | head -20
```

- [ ] **Step 4 — Run passing test.**

```bash
bash tests/e2e/scenarios/15_session_share.sh 2>&1 | tail -10
# Expected: "PASS: 15_session_share"
```

- [ ] **Step 5 — Commit.**

```bash
git add tests/e2e/scenarios/15_session_share.sh
git commit -m "e2e/15: cross-user session attach with cap-gated permission + UUID-only enforcement (Phase 9.3)"
```

---

### Task 9.4: e2e scenario 16 — plugin config 3-layer resolution

**File:** `tests/e2e/scenarios/16_plugin_config_layers.sh`

**Spec ref:** §9 e2e Scenario 16.

**Scenario steps:**
1. Init fresh ESRD_HOME; seed minimal plugin config; start esrd.
2. Set global: `esr plugin set claude_code http_proxy=http://global:8080 layer=global`.
3. Verify effective: `/plugin:show claude_code layer=effective` → `http_proxy = "http://global:8080"`.
4. Set user layer (alice): `esr plugin set claude_code http_proxy=http://user:8081 layer=user --user=alice`.
5. As alice: verify effective → `http_proxy = "http://user:8081"` (user wins over global).
6. Set workspace layer (in alice's session): `/plugin:set claude_code http_proxy="" layer=workspace`.
7. Verify effective → `http_proxy = ""` (empty string from workspace wins — explicit override).
8. Unset workspace: `/plugin:unset claude_code http_proxy layer=workspace`.
9. Verify effective → back to `http_proxy = "http://user:8081"` (user layer resumes).
10. Unset user: `/plugin:unset claude_code http_proxy layer=user`.
11. Verify effective → back to `http_proxy = "http://global:8080"` (global resumes).
12. As bob (no user override): effective → `http_proxy = "http://global:8080"`.
13. Cleanup.

- [ ] **Step 1 — Write failing test.** Create `tests/e2e/scenarios/16_plugin_config_layers.sh`:

```bash
#!/usr/bin/env bash
# e2e scenario 16 — plugin config 3-layer per-key merge.
# Spec: docs/superpowers/specs/2026-05-07-metamodel-aligned-esr.md §9 Scenario 16.
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./common.sh
source "${SCRIPT_DIR}/common.sh"

# --- setup ------------------------------------------------------------
seed_plugin_config
seed_capabilities
start_esrd
wait_for_sidecar_ready 30

# Seed alice + bob.
esr_cli admin submit user_add --arg username=alice_16 --wait --timeout 15 > /dev/null || true
esr_cli admin submit user_add --arg username=bob_16   --wait --timeout 15 > /dev/null || true

# --- step 1: set global http_proxy -----------------------------------
esr_cli admin submit plugin_set_config \
  --arg plugin=claude_code --arg key=http_proxy \
  --arg value="http://global:8080" --arg layer=global \
  --arg submitter="${ESR_OPERATOR_PRINCIPAL_ID}" \
  --wait --timeout 15 > /dev/null
echo "16: global http_proxy set"

# --- step 2: verify effective (no user/workspace) --------------------
EFF=$(esr_cli admin submit plugin_show_config \
  --arg plugin=claude_code --arg layer=effective \
  --arg user=alice_16 \
  --arg submitter="${ESR_OPERATOR_PRINCIPAL_ID}" \
  --wait --timeout 15)
assert_contains "$EFF" 'http://global:8080' \
  "16: effective should show global http_proxy"
echo "16: step 2 passed — global visible as effective"

# --- step 3: set user (alice) http_proxy -----------------------------
esr_cli admin submit plugin_set_config \
  --arg plugin=claude_code --arg key=http_proxy \
  --arg value="http://user:8081" --arg layer=user \
  --arg submitter=alice_16 \
  --wait --timeout 15 > /dev/null
echo "16: alice user http_proxy set"

# --- step 4: alice effective shows user value ------------------------
EFF=$(esr_cli admin submit plugin_show_config \
  --arg plugin=claude_code --arg layer=effective \
  --arg user=alice_16 \
  --arg submitter=alice_16 \
  --wait --timeout 15)
assert_contains "$EFF" 'http://user:8081' \
  "16: alice effective should show user http_proxy (user > global)"
echo "16: step 4 passed — user wins over global"

# --- step 5: alice creates session; set workspace override ----------
SID=$(esr_cli admin submit session_new \
  --arg name=config-test-16 --arg submitter=alice_16 \
  --wait --timeout 20 \
  | awk -F': ' '/^session_id:/ {print $2; exit}')
[[ -n "$SID" ]] || _fail_with_context "16: no session_id"

esr_cli admin submit plugin_set_config \
  --arg plugin=claude_code --arg key=http_proxy \
  --arg value="" --arg layer=workspace \
  --arg session_id="$SID" --arg submitter=alice_16 \
  --wait --timeout 15 > /dev/null
echo "16: workspace http_proxy set to empty string"

# --- step 6: workspace empty string wins (explicit override) ---------
EFF=$(esr_cli admin submit plugin_show_config \
  --arg plugin=claude_code --arg layer=effective \
  --arg user=alice_16 --arg session_id="$SID" \
  --arg submitter=alice_16 \
  --wait --timeout 15)
assert_contains "$EFF" 'http_proxy = ""' \
  "16: empty string from workspace must win over user/global"
echo "16: step 6 passed — empty string workspace override wins"

# --- step 7: unset workspace; user resumes ---------------------------
esr_cli admin submit plugin_unset_config \
  --arg plugin=claude_code --arg key=http_proxy --arg layer=workspace \
  --arg session_id="$SID" --arg submitter=alice_16 \
  --wait --timeout 15 > /dev/null

EFF=$(esr_cli admin submit plugin_show_config \
  --arg plugin=claude_code --arg layer=effective \
  --arg user=alice_16 --arg session_id="$SID" \
  --arg submitter=alice_16 \
  --wait --timeout 15)
assert_contains "$EFF" 'http://user:8081' \
  "16: after workspace unset, user layer should resume"
echo "16: step 7 passed — user resumes after workspace unset"

# --- step 8: unset user; global resumes ----------------------------
esr_cli admin submit plugin_unset_config \
  --arg plugin=claude_code --arg key=http_proxy --arg layer=user \
  --arg submitter=alice_16 \
  --wait --timeout 15 > /dev/null

EFF=$(esr_cli admin submit plugin_show_config \
  --arg plugin=claude_code --arg layer=effective \
  --arg user=alice_16 \
  --arg submitter=alice_16 \
  --wait --timeout 15)
assert_contains "$EFF" 'http://global:8080' \
  "16: after user unset, global should resume"
echo "16: step 8 passed — global resumes after user unset"

# --- step 9: bob sees only global ------------------------------------
EFF=$(esr_cli admin submit plugin_show_config \
  --arg plugin=claude_code --arg layer=effective \
  --arg user=bob_16 \
  --arg submitter=bob_16 \
  --wait --timeout 15)
assert_contains "$EFF" 'http://global:8080' \
  "16: bob (no user override) should see global http_proxy"
echo "16: step 9 passed — bob sees global only"

# --- cleanup ----------------------------------------------------------
esr_cli admin submit session_end --arg session_id="$SID" \
  --arg submitter=alice_16 --wait --timeout 20 > /dev/null || true
stop_esrd

echo "PASS: 16_plugin_config_layers"
```

- [ ] **Step 2 — Run failing test.** Confirm it fails (missing `plugin_set_config` / `plugin_show_config` admin submit verbs, or Phase 7 config not yet live). Document failure step.

```bash
bash tests/e2e/scenarios/16_plugin_config_layers.sh 2>&1 | tail -20
```

- [ ] **Step 3 — Wire admin submit verbs.** Add `plugin_set_config`, `plugin_show_config`, `plugin_unset_config` to the admin submit dispatch (these correspond to `Esr.Commands.Plugin.Set`, `.ShowConfig`, `.Unset` from Phase 7).

```bash
grep -n "plugin_set_config\|plugin_show_config\|plugin_unset_config" scripts/esrd.sh \
  runtime/lib/esr/ -r 2>/dev/null | head -20
```

- [ ] **Step 4 — Run passing test.**

```bash
bash tests/e2e/scenarios/16_plugin_config_layers.sh 2>&1 | tail -10
# Expected: "PASS: 16_plugin_config_layers"
```

- [ ] **Step 5 — Commit.**

```bash
git add tests/e2e/scenarios/16_plugin_config_layers.sh
git commit -m "e2e/16: plugin config 3-layer per-key merge (Phase 9.4)"
```

---

### Phase 9 PR checklist

Before opening the PR:

- [ ] `grep -rn '/new-session\|/end-session\|/list-agents\|esr-cc\.sh' docs/ README*.md 2>/dev/null | grep -v "historical\|migration\|PR-7\|PR-8\|2026-04\|2026-03"` — zero hits in advisory docs
- [ ] `bash tests/e2e/scenarios/14_session_multiagent.sh 2>&1 | tail -3` — PASS
- [ ] `bash tests/e2e/scenarios/15_session_share.sh 2>&1 | tail -3` — PASS
- [ ] `bash tests/e2e/scenarios/16_plugin_config_layers.sh 2>&1 | tail -3` — PASS
- [ ] `make e2e 2>&1 | tail -5` — all scenarios pass

```bash
git commit -m "docs+test: e2e scenarios 14-16 + docs sweep colon-namespace + session-first surface (Phase 9)"
```

---

## Plan Complete

**Summary:** 11 phases (1, 1b, 2, 3, 4, 5, 6, 7, 8, 9 = 10 phase headers), ~50 tasks, ~5300–6350 LOC estimate (per spec §7). Each phase ships as one PR to `dev`. Implementation order: `1 → 1b → 2; 1 → 3 → 4; 1 → 5; 1b + 3 → 6 → 7 → 8 → 9`.

**Next step:** Use `superpowers:subagent-driven-development` to execute phase by phase. Start with Phase 1 + 1b in parallel (both depend only on Phase 0 spec; Phase 1b depends on Phase 1 for Paths conventions, so do Phase 1 first then 1b).

<!-- PLAN_COMPLETE — all 11 phases planned -->
