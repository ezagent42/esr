# Workspace VS-Code-style redesign — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace single `workspaces.yaml` with hybrid per-workspace directories (`<repo>/.esr/workspace.json` repo-bound or `$ESRD_HOME/<inst>/workspaces/<name>/workspace.json` ESR-bound), introduce UUID-based identity so capability rewrites become unnecessary, and ship 11 new slash commands for full lifecycle CLI management.

**Architecture:** workspace stays a Resource (metamodel role unchanged). Two file-loader paths feed one in-memory `Esr.Resource.Workspace.Registry`. UUIDs in `workspace.json.id` are canonical; capabilities.yaml stores caps by UUID; CLI translates name↔UUID at edges. Session→workspace binding is by UUID and immutable after spawn. No filesystem watcher — all mutations go through CLI which invalidates the registry inline.

**Tech Stack:** Elixir/OTP (`Esr.Resource.Workspace.*` GenServer + ETS), Jason for JSON, YamlElixir for yaml, ExUnit for tests, JSON Schema for editor validation.

**Spec:** `docs/superpowers/specs/2026-05-06-workspace-vs-code-redesign.md` (rev 3, user-approved 2026-05-06).

**Estimated:** ~1300-1700 LOC across 8 phases. Each phase shipped as one commit (or sequence of commits within phase). Plan targets a single PR with ~25 commits.

---

## Phase 0 — Scaffolding

### Task 0.1: Branch + JSON Schema file

**Files:**
- Create: `runtime/priv/schemas/workspace.v1.json`

- [ ] **Step 1: Branch off dev**

```bash
git checkout dev
git pull origin dev
git checkout -b feature/workspace-vs-code-redesign-impl
```

- [ ] **Step 2: Write JSON Schema for workspace.json v1**

Create `runtime/priv/schemas/workspace.v1.json`:

```json
{
  "$schema": "http://json-schema.org/draft-07/schema#",
  "$id": "https://esr.local/schema/workspace.v1.json",
  "title": "ESR workspace.json (v1)",
  "type": "object",
  "required": ["schema_version", "id", "name", "owner"],
  "additionalProperties": false,
  "properties": {
    "$schema": { "type": "string" },
    "schema_version": { "const": 1 },
    "id": { "type": "string", "pattern": "^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$" },
    "name": { "type": "string", "minLength": 1, "maxLength": 64, "pattern": "^[A-Za-z0-9][A-Za-z0-9_-]*$" },
    "owner": { "type": "string", "minLength": 1 },
    "folders": {
      "type": "array",
      "items": {
        "type": "object",
        "required": ["path"],
        "properties": {
          "path": { "type": "string" },
          "name": { "type": "string" }
        },
        "additionalProperties": false
      }
    },
    "agent": { "type": "string", "default": "cc" },
    "settings": {
      "type": "object",
      "additionalProperties": { "type": ["string", "number", "boolean", "array"] }
    },
    "env": {
      "type": "object",
      "additionalProperties": { "type": "string" }
    },
    "chats": {
      "type": "array",
      "items": {
        "type": "object",
        "required": ["chat_id", "app_id"],
        "properties": {
          "chat_id": { "type": "string" },
          "app_id": { "type": "string" },
          "kind": { "enum": ["dm", "group"] }
        },
        "additionalProperties": false
      }
    },
    "transient": { "type": "boolean", "default": false }
  }
}
```

- [ ] **Step 3: Commit**

```bash
git add runtime/priv/schemas/workspace.v1.json
git commit -m "schema: add workspace.json v1 JSON Schema (workspace VS-Code redesign Phase 0)"
```

### Task 0.2: Add new path helpers

**Files:**
- Modify: `runtime/lib/esr/paths.ex`
- Test: `runtime/test/esr/paths_test.exs`

- [ ] **Step 1: Read current `Esr.Paths` to understand existing helpers**

```bash
cat runtime/lib/esr/paths.ex | head -40
```

- [ ] **Step 2: Add path helpers for new layout**

Append to `runtime/lib/esr/paths.ex` after existing helpers:

```elixir
@doc "Top-level dir for ESR-bound workspaces. Per-instance."
def workspaces_dir, do: Path.join(runtime_home(), "workspaces")

@doc "Per-workspace dir for ESR-bound workspaces."
def workspace_dir(name) when is_binary(name),
  do: Path.join(workspaces_dir(), name)

@doc "Path to a workspace.json under the ESR-bound layout."
def workspace_json_esr(name) when is_binary(name),
  do: Path.join(workspace_dir(name), "workspace.json")

@doc "Path to workspace.json inside a user repo (repo-bound layout)."
def workspace_json_repo(repo_path) when is_binary(repo_path),
  do: Path.join([repo_path, ".esr", "workspace.json"])

@doc "Path to topology.yaml inside a user repo (project-shareable metadata)."
def topology_yaml_repo(repo_path) when is_binary(repo_path),
  do: Path.join([repo_path, ".esr", "topology.yaml"])

@doc "Per-instance registered repos list."
def registered_repos_yaml,
  do: Path.join(runtime_home(), "registered_repos.yaml")

@doc "Top-level sessions dir (per-instance, NOT per-workspace)."
def sessions_dir, do: Path.join(runtime_home(), "sessions")

@doc "Per-session state dir."
def session_dir(sid) when is_binary(sid),
  do: Path.join(sessions_dir(), sid)

@doc "JSON Schema file shipped in priv."
def workspace_schema_v1, do: Application.app_dir(:esr, "priv/schemas/workspace.v1.json")
```

- [ ] **Step 3: Add basic test**

Append to `runtime/test/esr/paths_test.exs` (create if missing):

```elixir
defmodule Esr.PathsTest do
  use ExUnit.Case, async: true
  alias Esr.Paths

  test "workspace_json_esr/1 builds correct path under ESRD_HOME" do
    home = System.tmp_dir!()
    System.put_env("ESRD_HOME", home)
    System.put_env("ESR_INSTANCE", "default")

    assert Paths.workspace_json_esr("esr-dev") ==
             Path.join([home, "default", "workspaces", "esr-dev", "workspace.json"])
  end

  test "workspace_json_repo/1 puts .esr/workspace.json in the repo" do
    assert Paths.workspace_json_repo("/tmp/myrepo") ==
             "/tmp/myrepo/.esr/workspace.json"
  end

  test "registered_repos_yaml lives at runtime_home root" do
    home = System.tmp_dir!()
    System.put_env("ESRD_HOME", home)
    System.put_env("ESR_INSTANCE", "default")

    assert Paths.registered_repos_yaml() == Path.join([home, "default", "registered_repos.yaml"])
  end
end
```

- [ ] **Step 4: Run tests**

```bash
cd runtime && mix test test/esr/paths_test.exs
```

Expected: 3 passing.

- [ ] **Step 5: Commit**

```bash
git add runtime/lib/esr/paths.ex runtime/test/esr/paths_test.exs
git commit -m "paths: add workspace + repo registry + session helpers (workspace redesign Phase 0)"
```

---

## Phase 1 — UUID identity + workspace.json shape (no UI)

### Task 1.1: Workspace struct module

**Files:**
- Create: `runtime/lib/esr/resource/workspace/struct.ex`

- [ ] **Step 1: Define struct + types**

Create `runtime/lib/esr/resource/workspace/struct.ex`:

```elixir
defmodule Esr.Resource.Workspace.Struct do
  @moduledoc """
  In-memory representation of a workspace, parsed from workspace.json.

  Fields:
    * `id` — UUID v4, canonical identity (never changes during a workspace's life).
    * `name` — display name (operator-visible). May change via `/workspace rename`.
    * `owner` — esr-username; must be in `users.yaml`.
    * `folders` — list of `{path, name?}` entries. Repo-bound workspaces always
      have at least one (the repo itself); ESR-bound may have zero.
    * `agent` — agent_def name (default `"cc"`).
    * `settings` — flat dot-namespaced map (e.g. `cc.model: "claude-opus-4-7"`).
    * `env` — string→string map merged into spawned sessions' env.
    * `chats` — list of `{chat_id, app_id, kind?}` this workspace default-routes for.
    * `transient` — bool; if true, last-session-end auto-removes ESR-bound storage.
    * `location` — internal field, set at load time. One of:
        * `{:esr_bound, dir}` — workspace.json read from `<dir>/workspace.json`
        * `{:repo_bound, repo_path}` — workspace.json read from `<repo_path>/.esr/workspace.json`
  """

  defstruct [
    :id,
    :name,
    :owner,
    folders: [],
    agent: "cc",
    settings: %{},
    env: %{},
    chats: [],
    transient: false,
    location: nil
  ]

  @type folder :: %{required(:path) => String.t(), optional(:name) => String.t()}
  @type chat :: %{required(:chat_id) => String.t(), required(:app_id) => String.t(), optional(:kind) => String.t()}
  @type location :: {:esr_bound, String.t()} | {:repo_bound, String.t()}

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          owner: String.t(),
          folders: [folder()],
          agent: String.t(),
          settings: %{String.t() => any()},
          env: %{String.t() => String.t()},
          chats: [chat()],
          transient: boolean(),
          location: location() | nil
        }
end
```

- [ ] **Step 2: Commit**

```bash
git add runtime/lib/esr/resource/workspace/struct.ex
git commit -m "workspace.struct: in-memory workspace shape (workspace redesign Phase 1)"
```

### Task 1.2: workspace.json file_loader

**Files:**
- Rewrite: `runtime/lib/esr/resource/workspace/file_loader.ex`
- Test: `runtime/test/esr/resource/workspace/file_loader_test.exs`

- [ ] **Step 1: Write failing tests**

Create `runtime/test/esr/resource/workspace/file_loader_test.exs`:

```elixir
defmodule Esr.Resource.Workspace.FileLoaderTest do
  use ExUnit.Case, async: true
  alias Esr.Resource.Workspace.{FileLoader, Struct}

  @valid %{
    "$schema" => "ignored",
    "schema_version" => 1,
    "id" => "7b9f3c1a-2d8e-4f1b-9a35-c4e2f8d63b71",
    "name" => "esr-dev",
    "owner" => "linyilun",
    "folders" => [%{"path" => "/tmp/repo", "name" => "esr"}],
    "agent" => "cc",
    "settings" => %{"cc.model" => "claude-opus-4-7"},
    "env" => %{"FOO" => "bar"},
    "chats" => [%{"chat_id" => "oc_x", "app_id" => "cli_y", "kind" => "dm"}],
    "transient" => false
  }

  setup do
    tmp = Path.join(System.tmp_dir!(), "fl_test_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)
    %{tmp: tmp}
  end

  test "parses a valid workspace.json (ESR-bound)", %{tmp: tmp} do
    path = Path.join(tmp, "workspace.json")
    File.write!(path, Jason.encode!(@valid))

    assert {:ok, %Struct{} = ws} = FileLoader.load(path, location: {:esr_bound, tmp})
    assert ws.id == "7b9f3c1a-2d8e-4f1b-9a35-c4e2f8d63b71"
    assert ws.name == "esr-dev"
    assert ws.owner == "linyilun"
    assert ws.folders == [%{path: "/tmp/repo", name: "esr"}]
    assert ws.agent == "cc"
    assert ws.settings == %{"cc.model" => "claude-opus-4-7"}
    assert ws.env == %{"FOO" => "bar"}
    assert ws.chats == [%{chat_id: "oc_x", app_id: "cli_y", kind: "dm"}]
    assert ws.transient == false
    assert ws.location == {:esr_bound, tmp}
  end

  test "rejects schema_version != 1", %{tmp: tmp} do
    path = Path.join(tmp, "workspace.json")
    File.write!(path, Jason.encode!(Map.put(@valid, "schema_version", 2)))

    assert {:error, {:bad_schema_version, 2}} = FileLoader.load(path, location: {:esr_bound, tmp})
  end

  test "rejects malformed UUID", %{tmp: tmp} do
    path = Path.join(tmp, "workspace.json")
    bad = Map.put(@valid, "id", "not-a-uuid")
    File.write!(path, Jason.encode!(bad))

    assert {:error, {:bad_uuid, "not-a-uuid"}} = FileLoader.load(path, location: {:esr_bound, tmp})
  end

  test "rejects missing required fields", %{tmp: tmp} do
    path = Path.join(tmp, "workspace.json")
    File.write!(path, Jason.encode!(Map.delete(@valid, "owner")))

    assert {:error, {:missing_field, "owner"}} = FileLoader.load(path, location: {:esr_bound, tmp})
  end

  test "rejects ESR-bound name != basename(parent)", %{tmp: tmp} do
    sub = Path.join(tmp, "esr-dev")
    File.mkdir_p!(sub)
    path = Path.join(sub, "workspace.json")
    File.write!(path, Jason.encode!(Map.put(@valid, "name", "different")))

    assert {:error, {:name_mismatch, "different", "esr-dev"}} =
             FileLoader.load(path, location: {:esr_bound, sub})
  end

  test "rejects transient: true on repo-bound", %{tmp: tmp} do
    repo_esr = Path.join([tmp, ".esr"])
    File.mkdir_p!(repo_esr)
    path = Path.join(repo_esr, "workspace.json")
    File.write!(path, Jason.encode!(Map.put(@valid, "transient", true)))

    assert {:error, :transient_repo_bound_forbidden} =
             FileLoader.load(path, location: {:repo_bound, tmp})
  end

  test "returns :file_missing if path doesn't exist" do
    assert {:error, :file_missing} =
             FileLoader.load("/nonexistent/workspace.json", location: {:esr_bound, "/nonexistent"})
  end
end
```

- [ ] **Step 2: Run — confirm tests fail**

```bash
cd runtime && mix test test/esr/resource/workspace/file_loader_test.exs 2>&1 | tail -10
```

Expected: compile errors (FileLoader.load doesn't exist yet) or test failures.

- [ ] **Step 3: Implement FileLoader**

Rewrite `runtime/lib/esr/resource/workspace/file_loader.ex`:

```elixir
defmodule Esr.Resource.Workspace.FileLoader do
  @moduledoc """
  Read a workspace.json file from disk and return an
  `%Esr.Resource.Workspace.Struct{}` or a structured error.

  Used by both the ESR-bound discovery path (walks
  `$ESRD_HOME/<inst>/workspaces/`) and the repo-bound path (walks
  `registered_repos.yaml` paths). Caller passes the `location:` kwarg
  so the loader knows which validity rules apply (e.g. ESR-bound
  names must equal basename; repo-bound transient is forbidden).
  """

  alias Esr.Resource.Workspace.Struct

  @uuid_re ~r/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/

  @spec load(String.t(), location: Struct.location()) ::
          {:ok, Struct.t()} | {:error, term()}
  def load(path, opts) do
    location = Keyword.fetch!(opts, :location)

    with {:ok, body} <- read_file(path),
         {:ok, doc} <- decode_json(body),
         :ok <- check_schema_version(doc),
         :ok <- check_required(doc, ["id", "name", "owner"]),
         :ok <- check_uuid(doc["id"]),
         :ok <- check_location_invariants(doc, location) do
      {:ok, build_struct(doc, location)}
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

  defp check_uuid(uuid) when is_binary(uuid) do
    if Regex.match?(@uuid_re, uuid), do: :ok, else: {:error, {:bad_uuid, uuid}}
  end

  defp check_uuid(other), do: {:error, {:bad_uuid, other}}

  defp check_location_invariants(doc, {:esr_bound, dir}) do
    expected = Path.basename(dir)
    cond do
      doc["name"] != expected -> {:error, {:name_mismatch, doc["name"], expected}}
      true -> :ok
    end
  end

  defp check_location_invariants(doc, {:repo_bound, _repo_path}) do
    cond do
      doc["transient"] == true -> {:error, :transient_repo_bound_forbidden}
      true -> :ok
    end
  end

  defp build_struct(doc, location) do
    %Struct{
      id: doc["id"],
      name: doc["name"],
      owner: doc["owner"],
      folders: Enum.map(doc["folders"] || [], &normalize_folder/1),
      agent: doc["agent"] || "cc",
      settings: doc["settings"] || %{},
      env: doc["env"] || %{},
      chats: Enum.map(doc["chats"] || [], &normalize_chat/1),
      transient: doc["transient"] || false,
      location: location
    }
  end

  defp normalize_folder(%{"path" => p} = m), do: %{path: p, name: m["name"]}

  defp normalize_chat(%{"chat_id" => cid, "app_id" => aid} = m) do
    base = %{chat_id: cid, app_id: aid}
    if m["kind"], do: Map.put(base, :kind, m["kind"]), else: Map.put(base, :kind, "dm")
  end
end
```

- [ ] **Step 4: Run tests — confirm all pass**

```bash
cd runtime && mix test test/esr/resource/workspace/file_loader_test.exs
```

Expected: 7 passing.

- [ ] **Step 5: Commit**

```bash
git add runtime/lib/esr/resource/workspace/file_loader.ex runtime/test/esr/resource/workspace/file_loader_test.exs
git commit -m "workspace.file_loader: parse workspace.json with location-aware validation (Phase 1)"
```

### Task 1.3: workspace.json atomic writer

**Files:**
- Create: `runtime/lib/esr/resource/workspace/json_writer.ex`
- Test: `runtime/test/esr/resource/workspace/json_writer_test.exs`

- [ ] **Step 1: Write failing tests**

Create `runtime/test/esr/resource/workspace/json_writer_test.exs`:

```elixir
defmodule Esr.Resource.Workspace.JsonWriterTest do
  use ExUnit.Case, async: true
  alias Esr.Resource.Workspace.{JsonWriter, Struct}

  setup do
    tmp = Path.join(System.tmp_dir!(), "jw_test_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)
    %{tmp: tmp}
  end

  test "writes a workspace.json with the correct shape", %{tmp: tmp} do
    ws = %Struct{
      id: "7b9f3c1a-2d8e-4f1b-9a35-c4e2f8d63b71",
      name: "esr-dev",
      owner: "linyilun",
      folders: [%{path: "/tmp/repo", name: "esr"}],
      settings: %{"cc.model" => "claude-opus-4-7"},
      chats: [%{chat_id: "oc_x", app_id: "cli_y", kind: "dm"}]
    }

    path = Path.join(tmp, "workspace.json")
    assert :ok = JsonWriter.write(path, ws)

    decoded = path |> File.read!() |> Jason.decode!()
    assert decoded["schema_version"] == 1
    assert decoded["id"] == ws.id
    assert decoded["name"] == "esr-dev"
    assert decoded["owner"] == "linyilun"
    assert decoded["folders"] == [%{"path" => "/tmp/repo", "name" => "esr"}]
    assert decoded["chats"] == [%{"chat_id" => "oc_x", "app_id" => "cli_y", "kind" => "dm"}]
  end

  test "atomically writes via *.tmp + rename", %{tmp: tmp} do
    ws = %Struct{id: "7b9f3c1a-2d8e-4f1b-9a35-c4e2f8d63b71", name: "x", owner: "u"}
    path = Path.join(tmp, "workspace.json")

    File.write!(path, "PRE-EXISTING-INVALID-JSON")
    assert :ok = JsonWriter.write(path, ws)

    decoded = path |> File.read!() |> Jason.decode!()
    assert decoded["name"] == "x"
    refute File.exists?(path <> ".tmp")
  end

  test "creates parent dir if missing", %{tmp: tmp} do
    ws = %Struct{id: "7b9f3c1a-2d8e-4f1b-9a35-c4e2f8d63b71", name: "y", owner: "u"}
    path = Path.join([tmp, "deep", "nested", "workspace.json"])

    assert :ok = JsonWriter.write(path, ws)
    assert File.exists?(path)
  end

  test "round-trips through FileLoader", %{tmp: tmp} do
    ws = %Struct{
      id: "7b9f3c1a-2d8e-4f1b-9a35-c4e2f8d63b71",
      name: Path.basename(tmp),
      owner: "u",
      folders: [%{path: "/p", name: "n"}],
      env: %{"K" => "V"}
    }

    path = Path.join(tmp, "workspace.json")
    :ok = JsonWriter.write(path, ws)

    {:ok, loaded} = Esr.Resource.Workspace.FileLoader.load(path, location: {:esr_bound, tmp})
    assert loaded.id == ws.id
    assert loaded.folders == ws.folders
    assert loaded.env == ws.env
  end
end
```

- [ ] **Step 2: Implement JsonWriter**

Create `runtime/lib/esr/resource/workspace/json_writer.ex`:

```elixir
defmodule Esr.Resource.Workspace.JsonWriter do
  @moduledoc """
  Atomic write of a `Workspace.Struct` to a `workspace.json` file.

  Uses `*.tmp` → fsync → rename to avoid leaving the file in a torn
  state if the process dies mid-write. Creates parent dirs as needed.
  """

  alias Esr.Resource.Workspace.Struct

  @spec write(String.t(), Struct.t()) :: :ok | {:error, term()}
  def write(path, %Struct{} = ws) do
    with :ok <- File.mkdir_p(Path.dirname(path)),
         {:ok, json} <- encode(ws),
         tmp = path <> ".tmp",
         :ok <- File.write(tmp, json),
         :ok <- File.rename(tmp, path) do
      :ok
    end
  end

  defp encode(ws) do
    map = %{
      "schema_version" => 1,
      "id" => ws.id,
      "name" => ws.name,
      "owner" => ws.owner,
      "folders" => Enum.map(ws.folders, &serialise_folder/1),
      "agent" => ws.agent,
      "settings" => ws.settings,
      "env" => ws.env,
      "chats" => Enum.map(ws.chats, &serialise_chat/1),
      "transient" => ws.transient
    }

    Jason.encode(map, pretty: true)
  end

  defp serialise_folder(%{path: p, name: nil}), do: %{"path" => p}
  defp serialise_folder(%{path: p, name: n}) when is_binary(n), do: %{"path" => p, "name" => n}
  defp serialise_folder(%{path: p}), do: %{"path" => p}

  defp serialise_chat(%{chat_id: cid, app_id: aid, kind: k}),
    do: %{"chat_id" => cid, "app_id" => aid, "kind" => k}
end
```

- [ ] **Step 3: Run tests**

```bash
cd runtime && mix test test/esr/resource/workspace/json_writer_test.exs
```

Expected: 4 passing.

- [ ] **Step 4: Commit**

```bash
git add runtime/lib/esr/resource/workspace/json_writer.ex runtime/test/esr/resource/workspace/json_writer_test.exs
git commit -m "workspace.json_writer: atomic write of workspace.json (Phase 1)"
```

### Task 1.4: registered_repos.yaml registry

**Files:**
- Create: `runtime/lib/esr/resource/workspace/repo_registry.ex`
- Test: `runtime/test/esr/resource/workspace/repo_registry_test.exs`

- [ ] **Step 1: Write failing tests**

Create `runtime/test/esr/resource/workspace/repo_registry_test.exs`:

```elixir
defmodule Esr.Resource.Workspace.RepoRegistryTest do
  use ExUnit.Case, async: true
  alias Esr.Resource.Workspace.RepoRegistry

  setup do
    tmp = Path.join(System.tmp_dir!(), "rr_test_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(tmp)
    yaml = Path.join(tmp, "registered_repos.yaml")
    on_exit(fn -> File.rm_rf!(tmp) end)
    %{yaml: yaml}
  end

  test "load empty when file missing", %{yaml: yaml} do
    assert {:ok, []} = RepoRegistry.load(yaml)
  end

  test "load valid yaml", %{yaml: yaml} do
    File.write!(yaml, """
    schema_version: 1
    repos:
      - path: /Users/h2oslabs/Workspace/esr
      - path: /Users/h2oslabs/Workspace/cc-openclaw
        name: cc-openclaw
    """)

    assert {:ok, [r1, r2]} = RepoRegistry.load(yaml)
    assert r1.path == "/Users/h2oslabs/Workspace/esr"
    assert r1.name == nil
    assert r2.path == "/Users/h2oslabs/Workspace/cc-openclaw"
    assert r2.name == "cc-openclaw"
  end

  test "register/unregister round-trip", %{yaml: yaml} do
    :ok = RepoRegistry.register(yaml, "/repo/a")
    :ok = RepoRegistry.register(yaml, "/repo/b", name: "bee")

    {:ok, repos} = RepoRegistry.load(yaml)
    assert Enum.map(repos, & &1.path) == ["/repo/a", "/repo/b"]
    assert Enum.find(repos, &(&1.path == "/repo/b")).name == "bee"

    :ok = RepoRegistry.unregister(yaml, "/repo/a")
    {:ok, repos} = RepoRegistry.load(yaml)
    assert Enum.map(repos, & &1.path) == ["/repo/b"]
  end

  test "register is idempotent (no duplicates)", %{yaml: yaml} do
    :ok = RepoRegistry.register(yaml, "/repo/x")
    :ok = RepoRegistry.register(yaml, "/repo/x")
    {:ok, repos} = RepoRegistry.load(yaml)
    assert length(repos) == 1
  end

  test "unregister non-existent path is ok", %{yaml: yaml} do
    assert :ok = RepoRegistry.unregister(yaml, "/never/registered")
  end
end
```

- [ ] **Step 2: Implement RepoRegistry**

Create `runtime/lib/esr/resource/workspace/repo_registry.ex`:

```elixir
defmodule Esr.Resource.Workspace.RepoRegistry do
  @moduledoc """
  Per-instance list of registered repo-bound workspace paths.

  Stored at `$ESRD_HOME/<inst>/registered_repos.yaml`. Each entry is
  the absolute path to a git repo whose `<path>/.esr/workspace.json`
  ESR should load into the workspace registry. Optional `name` is a
  display alias (unused except for human-readable rendering).

  Pure file IO module — no GenServer state. The in-memory registry
  reads from this file at boot and re-reads when CLI commands mutate
  it.
  """

  defmodule Entry do
    @enforce_keys [:path]
    defstruct [:path, :name]
    @type t :: %__MODULE__{path: String.t(), name: String.t() | nil}
  end

  @spec load(String.t()) :: {:ok, [Entry.t()]} | {:error, term()}
  def load(yaml_path) do
    cond do
      not File.exists?(yaml_path) ->
        {:ok, []}

      true ->
        case YamlElixir.read_from_file(yaml_path) do
          {:ok, %{"repos" => repos}} when is_list(repos) ->
            {:ok, Enum.map(repos, &to_entry/1)}

          {:ok, _other} ->
            {:ok, []}

          {:error, reason} ->
            {:error, {:yaml_read_failed, reason}}
        end
    end
  end

  @spec register(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def register(yaml_path, repo_path, opts \\ []) do
    name = Keyword.get(opts, :name)

    {:ok, repos} = load(yaml_path)

    cond do
      Enum.any?(repos, &(&1.path == repo_path)) ->
        :ok

      true ->
        new_repos = repos ++ [%Entry{path: repo_path, name: name}]
        write(yaml_path, new_repos)
    end
  end

  @spec unregister(String.t(), String.t()) :: :ok | {:error, term()}
  def unregister(yaml_path, repo_path) do
    {:ok, repos} = load(yaml_path)
    new_repos = Enum.reject(repos, &(&1.path == repo_path))
    write(yaml_path, new_repos)
  end

  defp to_entry(%{"path" => p} = m), do: %Entry{path: p, name: m["name"]}

  defp write(yaml_path, repos) do
    body = """
    schema_version: 1
    repos:
    #{render_repos(repos)}
    """

    File.mkdir_p!(Path.dirname(yaml_path))
    tmp = yaml_path <> ".tmp"
    :ok = File.write(tmp, body)
    File.rename(tmp, yaml_path)
  end

  defp render_repos([]), do: "  []"

  defp render_repos(repos) do
    repos
    |> Enum.map(fn
      %Entry{name: nil, path: p} -> "  - path: #{p}"
      %Entry{name: n, path: p} -> "  - path: #{p}\n    name: #{n}"
    end)
    |> Enum.join("\n")
  end
end
```

- [ ] **Step 3: Run tests**

```bash
cd runtime && mix test test/esr/resource/workspace/repo_registry_test.exs
```

Expected: 5 passing.

- [ ] **Step 4: Commit**

```bash
git add runtime/lib/esr/resource/workspace/repo_registry.ex runtime/test/esr/resource/workspace/repo_registry_test.exs
git commit -m "workspace.repo_registry: registered_repos.yaml read/write (Phase 1)"
```

### Task 1.5: name↔id index module

**Files:**
- Create: `runtime/lib/esr/resource/workspace/name_index.ex`
- Test: `runtime/test/esr/resource/workspace/name_index_test.exs`

- [ ] **Step 1: Write failing tests**

Create `runtime/test/esr/resource/workspace/name_index_test.exs`:

```elixir
defmodule Esr.Resource.Workspace.NameIndexTest do
  use ExUnit.Case, async: true
  alias Esr.Resource.Workspace.NameIndex

  setup do
    table = :"ni_test_#{:rand.uniform(1_000_000_000)}"
    {:ok, _pid} = NameIndex.start_link(table: table)
    %{table: table}
  end

  test "put + lookup by name + by id", %{table: table} do
    NameIndex.put(table, "esr-dev", "uuid-1")
    NameIndex.put(table, "scratch", "uuid-2")

    assert NameIndex.id_for_name(table, "esr-dev") == {:ok, "uuid-1"}
    assert NameIndex.name_for_id(table, "uuid-1") == {:ok, "esr-dev"}
    assert NameIndex.id_for_name(table, "scratch") == {:ok, "uuid-2"}
    assert NameIndex.name_for_id(table, "uuid-2") == {:ok, "scratch"}
  end

  test "id_for_name on unknown returns :not_found", %{table: table} do
    assert NameIndex.id_for_name(table, "ghost") == :not_found
    assert NameIndex.name_for_id(table, "ghost-uuid") == :not_found
  end

  test "rename: keep id, change name", %{table: table} do
    NameIndex.put(table, "esr-dev", "uuid-1")
    NameIndex.rename(table, "esr-dev", "esr-prod")

    assert NameIndex.id_for_name(table, "esr-dev") == :not_found
    assert NameIndex.id_for_name(table, "esr-prod") == {:ok, "uuid-1"}
    assert NameIndex.name_for_id(table, "uuid-1") == {:ok, "esr-prod"}
  end

  test "delete by id", %{table: table} do
    NameIndex.put(table, "esr-dev", "uuid-1")
    NameIndex.delete_by_id(table, "uuid-1")

    assert NameIndex.id_for_name(table, "esr-dev") == :not_found
    assert NameIndex.name_for_id(table, "uuid-1") == :not_found
  end

  test "all/1 returns all (name, id) tuples", %{table: table} do
    NameIndex.put(table, "a", "uuid-a")
    NameIndex.put(table, "b", "uuid-b")
    pairs = NameIndex.all(table) |> Enum.sort()
    assert pairs == [{"a", "uuid-a"}, {"b", "uuid-b"}]
  end

  test "duplicate name with different id rejects", %{table: table} do
    NameIndex.put(table, "esr-dev", "uuid-1")
    assert {:error, :name_exists} = NameIndex.put(table, "esr-dev", "uuid-2")
  end

  test "duplicate id with different name rejects", %{table: table} do
    NameIndex.put(table, "a", "uuid-1")
    assert {:error, :id_exists} = NameIndex.put(table, "b", "uuid-1")
  end
end
```

- [ ] **Step 2: Implement NameIndex**

Create `runtime/lib/esr/resource/workspace/name_index.ex`:

```elixir
defmodule Esr.Resource.Workspace.NameIndex do
  @moduledoc """
  Bidirectional name↔id index for workspaces, backed by two ETS tables.

  Used by:
    * CLI input layer to translate operator-typed name → UUID before
      persisting (capabilities.yaml, session→workspace binding,
      chat-current-slot's default workspace).
    * CLI output layer to translate persisted UUID → name when
      rendering (`/cap list`, `/workspace info`, etc.).

  Owned by `Esr.Resource.Workspace.Registry` GenServer; ETS table
  is configurable for test isolation.
  """

  use GenServer

  @default_table :esr_workspace_name_index

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: name_for(Keyword.get(opts, :table, @default_table)))
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

- [ ] **Step 3: Run tests**

```bash
cd runtime && mix test test/esr/resource/workspace/name_index_test.exs
```

Expected: 7 passing.

- [ ] **Step 4: Commit**

```bash
git add runtime/lib/esr/resource/workspace/name_index.ex runtime/test/esr/resource/workspace/name_index_test.exs
git commit -m "workspace.name_index: bidirectional ETS-backed name↔id (Phase 1)"
```

---

## Phase 2 — Registry rewrite

### Task 2.1: Esr.Resource.Workspace.Registry GenServer

**Files:**
- Rewrite: `runtime/lib/esr/resource/workspace/registry.ex`
- Test: `runtime/test/esr/resource/workspace/registry_test.exs`

- [ ] **Step 1: Read current Registry to capture existing public API**

```bash
cat runtime/lib/esr/resource/workspace/registry.ex | head -100
```

Note the public functions other code calls (`get/1`, `list/0`, `put/1`, `workspace_for_chat/2`, etc.). The new Registry must keep these signatures (callers in `Esr.Commands.Scope.New`, etc.).

- [ ] **Step 2: Write failing tests**

Create `runtime/test/esr/resource/workspace/registry_test.exs`:

```elixir
defmodule Esr.Resource.Workspace.RegistryTest do
  use ExUnit.Case, async: false
  alias Esr.Resource.Workspace.{Registry, Struct}

  setup do
    tmp = Path.join(System.tmp_dir!(), "reg_test_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(tmp)

    System.put_env("ESRD_HOME", tmp)
    System.put_env("ESR_INSTANCE", "default")

    File.mkdir_p!(Path.join([tmp, "default", "workspaces"]))

    on_exit(fn ->
      System.delete_env("ESRD_HOME")
      System.delete_env("ESR_INSTANCE")
      File.rm_rf!(tmp)
    end)

    if Process.whereis(Registry), do: GenServer.stop(Registry)
    {:ok, _} = Registry.start_link([])

    %{tmp: tmp}
  end

  defp make_ws_dir(tmp, name, json_overrides \\ %{}) do
    dir = Path.join([tmp, "default", "workspaces", name])
    File.mkdir_p!(dir)

    base = %{
      "schema_version" => 1,
      "id" => generate_uuid(),
      "name" => name,
      "owner" => "linyilun"
    }

    File.write!(Path.join(dir, "workspace.json"), Jason.encode!(Map.merge(base, json_overrides)))
    dir
  end

  defp generate_uuid, do: UUID.uuid4()

  test "discovers ESR-bound workspaces from $ESRD_HOME", %{tmp: tmp} do
    make_ws_dir(tmp, "default")
    make_ws_dir(tmp, "esr-dev")

    Registry.refresh()
    {:ok, names} = Registry.list_names()
    assert Enum.sort(names) == ["default", "esr-dev"]
  end

  test "get/1 by name returns the struct", %{tmp: tmp} do
    make_ws_dir(tmp, "esr-dev")
    Registry.refresh()
    assert {:ok, %Struct{name: "esr-dev"}} = Registry.get("esr-dev")
  end

  test "get_by_id/1 returns the struct", %{tmp: tmp} do
    make_ws_dir(tmp, "esr-dev", %{"id" => "7b9f3c1a-2d8e-4f1b-9a35-c4e2f8d63b71"})
    Registry.refresh()
    assert {:ok, %Struct{name: "esr-dev"}} = Registry.get_by_id("7b9f3c1a-2d8e-4f1b-9a35-c4e2f8d63b71")
  end

  test "rejects duplicate UUIDs across two sources", %{tmp: tmp} do
    same_id = "7b9f3c1a-2d8e-4f1b-9a35-c4e2f8d63b71"
    make_ws_dir(tmp, "a", %{"id" => same_id})
    make_ws_dir(tmp, "b", %{"id" => same_id})

    assert {:error, {:duplicate_uuid, ^same_id, [_, _]}} = Registry.refresh()
  end

  test "name uniqueness enforced", %{tmp: tmp} do
    make_ws_dir(tmp, "esr-dev", %{"id" => "11111111-2222-4333-8444-555555555551"})
    Registry.refresh()

    bad = %Struct{
      id: "11111111-2222-4333-8444-555555555552",
      name: "esr-dev",
      owner: "u"
    }
    assert {:error, :name_exists} = Registry.put(bad)
  end

  test "workspace_for_chat looks up by chats[]", %{tmp: tmp} do
    make_ws_dir(tmp, "esr-dev", %{
      "chats" => [%{"chat_id" => "oc_abc", "app_id" => "cli_xyz", "kind" => "dm"}]
    })
    Registry.refresh()

    assert {:ok, "esr-dev"} = Registry.workspace_for_chat("oc_abc", "cli_xyz")
    assert :not_found = Registry.workspace_for_chat("oc_other", "cli_xyz")
  end

  test "rename updates name index but keeps id", %{tmp: tmp} do
    dir = make_ws_dir(tmp, "esr-dev", %{"id" => "11111111-2222-4333-8444-555555555551"})
    Registry.refresh()

    assert :ok = Registry.rename("esr-dev", "esr-prod")

    {:ok, ws} = Registry.get("esr-prod")
    assert ws.id == "11111111-2222-4333-8444-555555555551"
    assert :not_found = Registry.get("esr-dev")

    new_dir = Path.join([tmp, "default", "workspaces", "esr-prod"])
    assert File.exists?(Path.join(new_dir, "workspace.json"))
    refute File.exists?(dir)
  end
end
```

- [ ] **Step 3: Implement Registry GenServer**

Rewrite `runtime/lib/esr/resource/workspace/registry.ex`:

```elixir
defmodule Esr.Resource.Workspace.Registry do
  @moduledoc """
  In-memory registry of all workspaces (ESR-bound + repo-bound).

  Boot sequence:
    1. Walk `Esr.Paths.workspaces_dir()` for ESR-bound workspaces.
    2. Walk `Esr.Paths.registered_repos_yaml()` for repo-bound paths
       and load each `<repo>/.esr/workspace.json`.
    3. Build name↔id index. Reject duplicates loudly.

  Mutation API: all CLI slash commands call `put/1`, `delete_by_id/1`,
  `rename/2` etc. on this GenServer; the GenServer serialises writes
  and updates the in-memory ETS index inline. **No filesystem watcher
  exists** — yaml/json hand-edits won't take effect until daemon
  restart.
  """

  use GenServer
  require Logger

  alias Esr.Paths
  alias Esr.Resource.Workspace.{Struct, FileLoader, JsonWriter, NameIndex, RepoRegistry}

  @table_name :esr_workspaces

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  ## Public API ----------------------------------------------------------

  @spec list_names() :: {:ok, [String.t()]}
  def list_names, do: GenServer.call(__MODULE__, :list_names)

  @spec list_all() :: [Struct.t()]
  def list_all, do: GenServer.call(__MODULE__, :list_all)

  @spec get(String.t()) :: {:ok, Struct.t()} | :not_found
  def get(name), do: GenServer.call(__MODULE__, {:get, name})

  @spec get_by_id(String.t()) :: {:ok, Struct.t()} | :not_found
  def get_by_id(id), do: GenServer.call(__MODULE__, {:get_by_id, id})

  @spec put(Struct.t()) :: :ok | {:error, term()}
  def put(%Struct{} = ws), do: GenServer.call(__MODULE__, {:put, ws})

  @spec delete_by_id(String.t()) :: :ok
  def delete_by_id(id), do: GenServer.call(__MODULE__, {:delete_by_id, id})

  @spec rename(String.t(), String.t()) :: :ok | {:error, term()}
  def rename(old_name, new_name), do: GenServer.call(__MODULE__, {:rename, old_name, new_name})

  @spec workspace_for_chat(String.t(), String.t()) :: {:ok, String.t()} | :not_found
  def workspace_for_chat(chat_id, app_id),
    do: GenServer.call(__MODULE__, {:workspace_for_chat, chat_id, app_id})

  @spec refresh() :: :ok | {:error, term()}
  def refresh, do: GenServer.call(__MODULE__, :refresh)

  ## GenServer callbacks -----------------------------------------------

  @impl true
  def init(_opts) do
    if :ets.info(@table_name) == :undefined do
      :ets.new(@table_name, [:named_table, :set, :public, read_concurrency: true])
    end

    if Process.whereis(NameIndex) == nil do
      {:ok, _} = NameIndex.start_link(table: :esr_workspace_name_index)
    end

    case do_refresh() do
      :ok -> {:ok, %{}}
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call(:list_names, _from, state),
    do: {:reply, {:ok, list_all_names()}, state}

  def handle_call(:list_all, _from, state),
    do: {:reply, list_all_structs(), state}

  def handle_call({:get, name}, _from, state) do
    reply =
      case NameIndex.id_for_name(name) do
        {:ok, id} -> get_struct_by_id(id)
        :not_found -> :not_found
      end

    {:reply, reply, state}
  end

  def handle_call({:get_by_id, id}, _from, state),
    do: {:reply, get_struct_by_id(id), state}

  def handle_call({:put, ws}, _from, state) do
    reply = do_put(ws)
    {:reply, reply, state}
  end

  def handle_call({:delete_by_id, id}, _from, state) do
    NameIndex.delete_by_id(id)
    :ets.delete(@table_name, id)
    {:reply, :ok, state}
  end

  def handle_call({:rename, old, new}, _from, state) do
    reply = do_rename(old, new)
    {:reply, reply, state}
  end

  def handle_call({:workspace_for_chat, chat_id, app_id}, _from, state) do
    reply = do_workspace_for_chat(chat_id, app_id)
    {:reply, reply, state}
  end

  def handle_call(:refresh, _from, state),
    do: {:reply, do_refresh(), state}

  ## Internals ----------------------------------------------------------

  defp do_refresh do
    :ets.delete_all_objects(@table_name)
    Enum.each(NameIndex.all(), fn {_n, id} -> NameIndex.delete_by_id(id) end)

    esr_bound = scan_esr_bound()
    repo_bound = scan_repo_bound()
    all = esr_bound ++ repo_bound

    case duplicate_uuid(all) do
      nil ->
        Enum.each(all, fn ws ->
          :ets.insert(@table_name, {ws.id, ws})
          NameIndex.put(ws.name, ws.id)
        end)

        :ok

      {dup_id, dup_locations} ->
        {:error, {:duplicate_uuid, dup_id, dup_locations}}
    end
  end

  defp scan_esr_bound do
    base = Paths.workspaces_dir()

    if File.exists?(base) do
      base
      |> File.ls!()
      |> Enum.flat_map(fn name ->
        dir = Path.join(base, name)
        path = Path.join(dir, "workspace.json")

        case FileLoader.load(path, location: {:esr_bound, dir}) do
          {:ok, ws} -> [ws]
          {:error, reason} ->
            Logger.warning("workspace.registry: skipping #{path} (#{inspect(reason)})")
            []
        end
      end)
    else
      []
    end
  end

  defp scan_repo_bound do
    case RepoRegistry.load(Paths.registered_repos_yaml()) do
      {:ok, repos} ->
        Enum.flat_map(repos, fn entry ->
          path = Paths.workspace_json_repo(entry.path)

          case FileLoader.load(path, location: {:repo_bound, entry.path}) do
            {:ok, ws} -> [ws]
            {:error, reason} ->
              Logger.warning("workspace.registry: skipping repo #{entry.path} (#{inspect(reason)})")
              []
          end
        end)

      {:error, _} -> []
    end
  end

  defp duplicate_uuid(workspaces) do
    workspaces
    |> Enum.group_by(& &1.id)
    |> Enum.find(fn {_id, list} -> length(list) > 1 end)
    |> case do
      nil -> nil
      {id, list} -> {id, Enum.map(list, & &1.location)}
    end
  end

  defp list_all_names do
    NameIndex.all() |> Enum.map(fn {n, _id} -> n end) |> Enum.sort()
  end

  defp list_all_structs do
    @table_name
    |> :ets.tab2list()
    |> Enum.map(fn {_id, ws} -> ws end)
    |> Enum.sort_by(& &1.name)
  end

  defp get_struct_by_id(id) do
    case :ets.lookup(@table_name, id) do
      [{^id, ws}] -> {:ok, ws}
      [] -> :not_found
    end
  end

  defp do_put(%Struct{} = ws) do
    case NameIndex.put(ws.name, ws.id) do
      :ok ->
        :ets.insert(@table_name, {ws.id, ws})
        write_to_disk(ws)

      {:error, _} = err -> err
    end
  end

  defp do_rename(old_name, new_name) do
    with {:ok, id} <- NameIndex.id_for_name(old_name) |> wrap_not_found(),
         [{^id, ws}] <- :ets.lookup(@table_name, id),
         :ok <- NameIndex.rename(old_name, new_name) do
      new_ws = %{ws | name: new_name}
      new_ws =
        case ws.location do
          {:esr_bound, old_dir} ->
            new_dir = Path.join(Path.dirname(old_dir), new_name)
            :ok = File.rename(old_dir, new_dir)
            %{new_ws | location: {:esr_bound, new_dir}}

          {:repo_bound, _} ->
            new_ws
        end

      :ets.insert(@table_name, {id, new_ws})
      write_to_disk(new_ws)
    end
  end

  defp do_workspace_for_chat(chat_id, app_id) do
    @table_name
    |> :ets.tab2list()
    |> Enum.find_value(:not_found, fn {_id, ws} ->
      if Enum.any?(ws.chats, &(&1.chat_id == chat_id and &1.app_id == app_id)) do
        {:ok, ws.name}
      end
    end)
  end

  defp wrap_not_found({:ok, _} = ok), do: ok
  defp wrap_not_found(:not_found), do: {:error, :not_found}

  defp write_to_disk(%Struct{location: {:esr_bound, dir}} = ws) do
    JsonWriter.write(Path.join(dir, "workspace.json"), ws)
  end

  defp write_to_disk(%Struct{location: {:repo_bound, repo}} = ws) do
    JsonWriter.write(Paths.workspace_json_repo(repo), ws)
  end
end
```

- [ ] **Step 4: Run tests**

```bash
cd runtime && mix test test/esr/resource/workspace/registry_test.exs
```

Expected: 7 passing.

- [ ] **Step 5: Commit**

```bash
git add runtime/lib/esr/resource/workspace/registry.ex runtime/test/esr/resource/workspace/registry_test.exs
git commit -m "workspace.registry: rewrite for hybrid storage + UUID identity (Phase 2)"
```

---

## Phase 3 — Capability UUID translation

### Task 3.1: Cap input translation (Grant + Revoke)

**Files:**
- Modify: `runtime/lib/esr/commands/cap/grant.ex`
- Modify: `runtime/lib/esr/commands/cap/revoke.ex`
- Test: `runtime/test/esr/commands/cap/uuid_translation_test.exs`

- [ ] **Step 1: Write failing translation tests**

Create `runtime/test/esr/commands/cap/uuid_translation_test.exs`:

```elixir
defmodule Esr.Commands.Cap.UuidTranslationTest do
  use ExUnit.Case, async: false
  alias Esr.Commands.Cap.{Grant, Revoke}
  alias Esr.Resource.Workspace.{Registry, Struct}

  @uuid "7b9f3c1a-2d8e-4f1b-9a35-c4e2f8d63b71"

  setup do
    tmp = Path.join(System.tmp_dir!(), "cap_uuid_test_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(Path.join([tmp, "default", "workspaces"]))
    System.put_env("ESRD_HOME", tmp)
    System.put_env("ESR_INSTANCE", "default")

    on_exit(fn ->
      System.delete_env("ESRD_HOME")
      System.delete_env("ESR_INSTANCE")
      File.rm_rf!(tmp)
    end)

    if Process.whereis(Registry), do: GenServer.stop(Registry)
    {:ok, _} = Registry.start_link([])

    Registry.put(%Struct{
      id: @uuid,
      name: "esr-dev",
      owner: "linyilun",
      location: {:esr_bound, Path.join([tmp, "default", "workspaces", "esr-dev"])}
    })

    %{}
  end

  test "Cap.Grant translates session:<name>/<perm> → session:<uuid>/<perm> before persisting" do
    {:ok, %{"text" => _}} = Grant.execute(%{
      "args" => %{"principal_id" => "linyilun", "permission" => "session:esr-dev/create"}
    })

    grants = Esr.Resource.Capability.Grants.list_for_principal("linyilun")
    assert "session:#{@uuid}/create" in grants
    refute "session:esr-dev/create" in grants
  end

  test "Cap.Revoke translates name → UUID before matching" do
    Esr.Resource.Capability.Grants.put("linyilun", ["session:#{@uuid}/create"])

    {:ok, %{"text" => _}} = Revoke.execute(%{
      "args" => %{"principal_id" => "linyilun", "permission" => "session:esr-dev/create"}
    })

    grants = Esr.Resource.Capability.Grants.list_for_principal("linyilun")
    refute "session:#{@uuid}/create" in grants
  end

  test "Grant errors on unknown workspace name" do
    assert {:error, %{"type" => "unknown_workspace"}} = Grant.execute(%{
      "args" => %{"principal_id" => "linyilun", "permission" => "session:ghost-ws/create"}
    })
  end

  test "non-workspace-scoped caps pass through unchanged" do
    {:ok, _} = Grant.execute(%{
      "args" => %{"principal_id" => "linyilun", "permission" => "user.manage"}
    })

    grants = Esr.Resource.Capability.Grants.list_for_principal("linyilun")
    assert "user.manage" in grants
  end
end
```

- [ ] **Step 2: Add translation helper**

Create `runtime/lib/esr/resource/capability/uuid_translator.ex`:

```elixir
defmodule Esr.Resource.Capability.UuidTranslator do
  @moduledoc """
  Translate cap strings between operator-readable form (with workspace
  names) and storage form (with workspace UUIDs).

  Caps shaped `<resource>:<scope>/<perm>` where `<resource>` is one
  of {"session", "workspace"} get their `<scope>` translated. Other
  cap strings (`user.manage`, `adapter.manage`, `runtime.deadletter`)
  pass through unchanged.

  ## Examples

      iex> # name → UUID (input direction)
      iex> name_to_uuid("session:esr-dev/create")
      {:ok, "session:7b9f3c1a-...../create"}

      iex> # UUID → name (output direction)
      iex> uuid_to_name("session:7b9f3c1a-...../create")
      "session:esr-dev/create"  # falls back to <UNKNOWN-...> if no match
  """

  alias Esr.Resource.Workspace.{NameIndex, Registry}

  @workspace_scoped_resources ~w(session workspace)

  @spec name_to_uuid(String.t()) :: {:ok, String.t()} | {:error, :unknown_workspace}
  def name_to_uuid(cap) do
    case parse(cap) do
      {:scoped, resource, scope, perm} when resource in @workspace_scoped_resources ->
        case Registry.get(scope) do
          {:ok, ws} -> {:ok, "#{resource}:#{ws.id}/#{perm}"}
          :not_found -> {:error, :unknown_workspace}
        end

      _ ->
        {:ok, cap}
    end
  end

  @spec uuid_to_name(String.t()) :: String.t()
  def uuid_to_name(cap) do
    case parse(cap) do
      {:scoped, resource, uuid, perm} when resource in @workspace_scoped_resources ->
        case NameIndex.name_for_id(uuid) do
          {:ok, name} -> "#{resource}:#{name}/#{perm}"
          :not_found -> "#{resource}:<UNKNOWN-#{String.slice(uuid, 0..7)}>/#{perm}"
        end

      _ ->
        cap
    end
  end

  defp parse(cap) when is_binary(cap) do
    case String.split(cap, ":", parts: 2) do
      [resource, rest] ->
        case String.split(rest, "/", parts: 2) do
          [scope, perm] -> {:scoped, resource, scope, perm}
          _ -> {:flat, cap}
        end

      _ ->
        {:flat, cap}
    end
  end
end
```

- [ ] **Step 3: Modify Cap.Grant + Cap.Revoke to use translator**

Edit `runtime/lib/esr/commands/cap/grant.ex` to translate `permission` arg:

```elixir
# At the top of execute/1, after extracting permission:
case Esr.Resource.Capability.UuidTranslator.name_to_uuid(permission) do
  {:ok, translated_perm} ->
    # ... existing path with `translated_perm` instead of `permission`

  {:error, :unknown_workspace} ->
    {:error, %{"type" => "unknown_workspace",
               "message" => "no workspace named in capability: #{permission}"}}
end
```

(Repeat the same change in `runtime/lib/esr/commands/cap/revoke.ex`.)

- [ ] **Step 4: Run tests**

```bash
cd runtime && mix test test/esr/commands/cap/uuid_translation_test.exs
```

Expected: 4 passing.

- [ ] **Step 5: Commit**

```bash
git add runtime/lib/esr/resource/capability/uuid_translator.ex \
        runtime/lib/esr/commands/cap/grant.ex \
        runtime/lib/esr/commands/cap/revoke.ex \
        runtime/test/esr/commands/cap/uuid_translation_test.exs
git commit -m "cap.uuid_translator: translate workspace name↔uuid in cap strings (Phase 3)"
```

### Task 3.2: Cap output translation (List + Show + WhoCan)

**Files:**
- Modify: `runtime/lib/esr/commands/cap/list.ex`
- Modify: `runtime/lib/esr/commands/cap/show.ex`
- Modify: `runtime/lib/esr/commands/cap/who_can.ex`

- [ ] **Step 1: Add UUID→name translation to List output**

Modify `runtime/lib/esr/commands/cap/list.ex` — when rendering each cap string, run it through `UuidTranslator.uuid_to_name/1`.

- [ ] **Step 2: Same change to Show + WhoCan output paths**

- [ ] **Step 3: Add output translation tests**

Append to `runtime/test/esr/commands/cap/uuid_translation_test.exs`:

```elixir
test "Cap.List translates UUIDs back to names in output" do
  Esr.Resource.Capability.Grants.put("linyilun", [
    "session:#{@uuid}/create",
    "user.manage"
  ])

  {:ok, %{"text" => text}} = Esr.Commands.Cap.List.execute(%{})

  assert text =~ "session:esr-dev/create"
  refute text =~ @uuid
  assert text =~ "user.manage"
end

test "Cap.List shows <UNKNOWN-...> for orphan UUIDs" do
  Esr.Resource.Capability.Grants.put("linyilun", [
    "session:99999999-9999-4999-8999-999999999999/create"
  ])

  {:ok, %{"text" => text}} = Esr.Commands.Cap.List.execute(%{})
  assert text =~ "<UNKNOWN-99999999>"
end
```

- [ ] **Step 4: Run tests**

```bash
cd runtime && mix test test/esr/commands/cap/uuid_translation_test.exs
```

Expected: 6 passing.

- [ ] **Step 5: Commit**

```bash
git add runtime/lib/esr/commands/cap/list.ex \
        runtime/lib/esr/commands/cap/show.ex \
        runtime/lib/esr/commands/cap/who_can.ex \
        runtime/test/esr/commands/cap/uuid_translation_test.exs
git commit -m "cap: translate UUIDs → names in list/show/who-can output (Phase 3)"
```

---

## Phase 4 — Slash command modules

### Task 4.1: Refactor `/new-workspace`

**Files:**
- Rewrite: `runtime/lib/esr/commands/workspace/new.ex`
- Test: `runtime/test/esr/commands/workspace/new_test.exs`

- [ ] **Step 1: Read current `Esr.Commands.Workspace.New` to capture existing args contract**

```bash
cat runtime/lib/esr/commands/workspace/new.ex
```

- [ ] **Step 2: Write failing tests covering both ESR-bound and repo-bound creation**

Write tests for:
- `/new-workspace esr-dev` (no folder) → creates ESR-bound at `<workspaces>/esr-dev/workspace.json`
- `/new-workspace esr-dev folder=/tmp/repo` → creates repo-bound at `/tmp/repo/.esr/workspace.json` + auto-registers repo
- `transient=true` rejected for repo-bound
- duplicate name rejected
- generates valid UUID

(Test code structure follows the same pattern as previous phases.)

- [ ] **Step 3: Implement new module**

Rewrite to:
1. Generate UUID via `UUID.uuid4()` (add `{:uuid_utils, "~> 1.6"}` dep if not present).
2. Build `Workspace.Struct` with appropriate `location` based on `folder=` arg.
3. If repo-bound: `RepoRegistry.register/2` first, then `Registry.put/1`.
4. If ESR-bound: `Registry.put/1` directly (which calls `JsonWriter.write/2` on the struct's location).
5. Auto-bind current chat (existing logic).

- [ ] **Step 4: Run tests + commit**

### Task 4.2: New `/workspace list`

**Files:**
- Create: `runtime/lib/esr/commands/workspace/list.ex`
- Test: `runtime/test/esr/commands/workspace/list_test.exs`

Implementation: walk `Registry.list_all/0`, format per spec output (name, id, owner, folders count, chats count, location, transient). Yaml-render using existing escript envelope helper.

### Task 4.3: New `/workspace edit --set <key>=<value>`

**Files:**
- Create: `runtime/lib/esr/commands/workspace/edit.ex`
- Test: `runtime/test/esr/commands/workspace/edit_test.exs`

Implementation: parse `--set key=value` into nested-map merge into `workspace.json`. Reject `--set chats=...` and `--set folders=...` (use dedicated slashes). Reject `--set id=...` (immutable). Reject `--set name=...` (use rename). Reject `--set transient=true` for repo-bound.

### Task 4.4: New `/workspace add-folder` + `/workspace remove-folder`

**Files:**
- Create: `runtime/lib/esr/commands/workspace/add_folder.ex`
- Create: `runtime/lib/esr/commands/workspace/remove_folder.ex`
- Test: each module gets a test file

Add validates path exists + is a git repo (`File.dir?(path) and File.exists?(Path.join(path, ".git"))`). Remove rejects removing folders[0] from a repo-bound workspace.

### Task 4.5: New `/workspace bind-chat` + `/workspace unbind-chat`

**Files:**
- Create: `runtime/lib/esr/commands/workspace/bind_chat.ex`
- Create: `runtime/lib/esr/commands/workspace/unbind_chat.ex`
- Test: each module gets a test file

Implementation: append/remove `{chat_id, app_id, kind}` from `workspace.json.chats[]`. App_id defaults to inbound envelope's app_id.

### Task 4.6: New `/workspace remove`

**Files:**
- Create: `runtime/lib/esr/commands/workspace/remove.ex`
- Test: same

Implementation:
- Validate no live sessions reference the workspace's UUID (call `Esr.Scope.Registry.list_for_workspace/1`).
- ESR-bound: `File.rm_rf!(workspace_dir)`.
- Repo-bound: `File.rm!(<repo>/.esr/workspace.json)` + `File.rm!(<repo>/.esr/topology.yaml)` IF EXISTS. Never `rm -rf <repo>/.esr/`. Then `RepoRegistry.unregister/2`.
- `Registry.delete_by_id/1`.

### Task 4.7: New `/workspace rename`

**Files:**
- Create: `runtime/lib/esr/commands/workspace/rename.ex`
- Test: same

Implementation: just calls `Registry.rename/2` (which handles ETS index + filesystem `mv` for ESR-bound). For repo-bound the directory path doesn't change because it's inside the repo.

### Task 4.8: New `/workspace use`

**Files:**
- Create: `runtime/lib/esr/commands/workspace/use.ex`
- Test: same

Implementation: store the chat's default workspace UUID into the chat-current-slot ETS table (extend the existing slot module to carry a `default_workspace_id` field).

### Task 4.9: New `/workspace import-repo` + `/workspace forget-repo`

**Files:**
- Create: `runtime/lib/esr/commands/workspace/import_repo.ex`
- Create: `runtime/lib/esr/commands/workspace/forget_repo.ex`
- Test: each gets a test file

Implementation:
- import-repo: validate `<path>/.esr/workspace.json` exists + parses; `RepoRegistry.register/2`; `Registry.refresh/0` to pick up new entry.
- forget-repo: `RepoRegistry.unregister/2`; `Registry.refresh/0`.

### Task 4.10: Refactor `/workspace info`, `/workspace describe`, `/workspace sessions`

**Files:**
- Modify: `runtime/lib/esr/commands/workspace/info.ex`
- Modify: `runtime/lib/esr/commands/workspace/describe.ex`
- Modify: `runtime/lib/esr/commands/scope/list.ex`

Each refactored to read from new Registry shape. `info` overlays `<folders[0]>/.esr/topology.yaml` if present. `describe` keeps PR-222 security boundary unchanged. `sessions` reads `Esr.Scope.Registry.list_for_workspace/1`.

### Task 4.11: Add 8 new slashes to `runtime/priv/slash-routes.default.yaml`

Add entries (fields per existing pattern):

```yaml
"/workspace list":
  kind: workspace_list
  permission: "session.list"
  command_module: "Esr.Commands.Workspace.List"
  ...

"/workspace edit":
  kind: workspace_edit
  permission: "workspace.create"
  command_module: "Esr.Commands.Workspace.Edit"
  args:
    - { name: name, required: true }
    - { name: set, required: true }   # parsed by command module

# ... same pattern for add-folder, remove-folder, bind-chat,
# unbind-chat, remove, rename, use, import-repo, forget-repo
```

(Each task in this phase ends with `mix compile && mix test test/esr/commands/workspace/<the_test>.exs && git commit`.)

---

## Phase 5 — Session integration

### Task 5.1: Workspace resolution in `/new-session`

**Files:**
- Modify: `runtime/lib/esr/commands/scope/new.ex`
- Test: `runtime/test/esr/commands/scope/new_resolution_test.exs`

- [ ] **Step 1: Write failing tests for the 3-step fallback chain**

Test cases:
- explicit ws_name arg → uses it
- no ws_name + chat has `/workspace use` set → uses chat's default
- no ws_name + no chat default → uses `default` workspace
- no ws_name + no chat default + no `default` workspace exists → returns helpful error

- [ ] **Step 2: Implement the chain in execute/1**

Replace the current "ws is required" check with a resolution function:

```elixir
defp resolve_workspace(args, envelope) do
  cond do
    args["workspace"] not in [nil, ""] ->
      {:explicit, args["workspace"]}

    chat_default = lookup_chat_default(envelope) ->
      {:chat_default, chat_default}

    Registry.get("default") != :not_found ->
      {:fallback, "default"}

    true ->
      {:error, :no_workspace_resolvable}
  end
end
```

- [ ] **Step 3: Record session.workspace_id immutably**

When session is registered, `session.workspace_id = workspace.id` (UUID).

- [ ] **Step 4: Run tests + commit**

### Task 5.2: Transient workspace cleanup hook

**Files:**
- Modify: `runtime/lib/esr/commands/scope/end.ex`
- Test: `runtime/test/esr/commands/scope/end_transient_cleanup_test.exs`

- [ ] **Step 1: Write failing test**

Spawn 1 session under a `transient: true` workspace, end it, assert workspace is removed.

- [ ] **Step 2: Implement hook**

After session teardown, if the workspace's `transient` is true and `Esr.Scope.Registry.list_for_workspace(ws_id)` returns empty, call `Workspace.Registry.delete_by_id(ws_id)` (which handles file cleanup).

- [ ] **Step 3: Run tests + commit**

### Task 5.3: chat-current-slot extension for `default_workspace_id`

**Files:**
- Modify: existing chat-current-slot module (find via `grep -rn "chat_current_slot\|ChatCurrentSlot" runtime/lib`)
- Test: existing test file

Add a `default_workspace_id` field to the slot ETS row. `/workspace use` writes it; `Esr.Commands.Scope.New` reads it during workspace resolution.

---

## Phase 6 — Boot integration

### Task 6.1: Application start: legacy yaml deletion + default workspace

**Files:**
- Modify: `runtime/lib/esr/application.ex`
- Test: `runtime/test/esr/application_first_boot_test.exs`

- [ ] **Step 1: Write failing test**

Test scenario: place a stale `workspaces.yaml` in tmp ESRD_HOME, start app, assert (a) yaml is deleted, (b) WARN log line emitted with the deleted path, (c) `default` workspace exists in the registry.

- [ ] **Step 2: Implement boot hook**

Add a Task child between `Permission.Registry` boot and `Workspace.Registry` boot:

```elixir
defmodule Esr.Resource.Workspace.Bootstrap do
  @moduledoc "First-boot tasks: delete legacy yaml + ensure default workspace."

  use Task, restart: :transient

  def start_link(_), do: Task.start_link(__MODULE__, :run, [])

  def run do
    delete_legacy_yaml()
    ensure_default_workspace()
  end

  defp delete_legacy_yaml do
    legacy_path = Path.join(Esr.Paths.runtime_home(), "workspaces.yaml")

    if File.exists?(legacy_path) do
      File.rm!(legacy_path)
      Logger.warning("workspace.bootstrap: deleted legacy #{legacy_path}; recreate workspaces via /new-workspace")
    end
  end

  defp ensure_default_workspace do
    if Esr.Resource.Workspace.Registry.get("default") == :not_found do
      ws = %Esr.Resource.Workspace.Struct{
        id: UUID.uuid4(),
        name: "default",
        owner: System.get_env("ESR_BOOTSTRAP_PRINCIPAL_ID") || "admin",
        location: {:esr_bound, Esr.Paths.workspace_dir("default")}
      }
      :ok = Esr.Resource.Workspace.Registry.put(ws)
      Logger.info("workspace.bootstrap: created default workspace at #{ws.location |> elem(1)}")
    end
  end
end
```

Insert into `Esr.Application.children/0` after `Workspace.Registry`.

- [ ] **Step 3: Run tests + commit**

---

## Phase 7 — describe_topology integration

### Task 7.1: Refactor `Esr.Resource.Workspace.Describe` to overlay topology.yaml

**Files:**
- Modify: `runtime/lib/esr/resource/workspace/describe.ex`
- Modify: `runtime/test/esr/entity_server_describe_topology_test.exs`

- [ ] **Step 1: Update describe/1 to read overlay**

Add: when `folders[0]` exists, read `<path>/.esr/topology.yaml` and merge `description`, `metadata`, `neighbors` into the response. Security allowlist (PR-222) unchanged.

- [ ] **Step 2: Add overlay test cases**

- create a tmp git repo, write `.esr/topology.yaml` with description + metadata, register workspace pointing at it
- `Describe.describe(name)` returns merged data
- absent topology.yaml → fall back to workspace.json fields only

- [ ] **Step 3: Run all 5 PR-21z security tests + new overlay tests + commit**

```bash
cd runtime && mix test test/esr/entity_server_describe_topology_test.exs
```

Expected: 5 PR-21z tests + 2 new overlay tests passing.

---

## Phase 8 — Docs sweep + e2e

### Task 8.1: Docs sweep

**Files:** (all modify, no new files)
- `README.md`
- `README.zh_cn.md` (or the Chinese section in same file — depends on convention)
- `docs/dev-guide.md`
- `docs/cookbook.md`
- `docs/notes/actor-topology-routing.md`
- `docs/futures/todo.md`
- `docs/architecture.md` (if it exists; `ls docs/architecture.md`)
- All `docs/superpowers/specs/*` referencing `workspaces.yaml`

For each file, grep for `workspaces.yaml`, `workspace.root`, `Esr.Resource.Workspace.Registry` (old shape), and replace with new design references. Keep changes minimal — just enough so docs stop lying about what exists.

- [ ] **Step 1: Run sweep**

```bash
grep -rln "workspaces\.yaml\|workspace\.root" docs/ README.md README.zh_cn.md 2>/dev/null
```

For each hit: open file, replace stale references with new design (or strike them out with a "deprecated, see spec 2026-05-06" pointer).

- [ ] **Step 2: Update todo.md**

In `docs/futures/todo.md`: mark "esr daemon init + esrd home redesign" as still-deferred but unblocked (workspace redesign decision now made). Mark workspace-redesign itself as **shipped after merge**.

- [ ] **Step 3: Commit docs sweep separately**

```bash
git add README*.md docs/
git commit -m "docs: sweep — workspaces.yaml refs → workspace VS-Code-style redesign"
```

### Task 8.2: e2e scenario for full lifecycle

**Files:**
- Create: `tests/e2e/scenarios/14_workspace_lifecycle.sh`

- [ ] **Step 1: Write bash scenario**

Test cases:
1. `runtime/esr exec /new-workspace lifecycle-test folder=/tmp/test-repo` (create repo-bound)
2. `runtime/esr exec /workspace list` → contains entry
3. `runtime/esr exec /workspace edit lifecycle-test --set settings.cc.model=claude-opus-4-7`
4. `runtime/esr exec /workspace info lifecycle-test` → shows updated setting
5. `runtime/esr exec /workspace rename lifecycle-test renamed-test`
6. `runtime/esr exec /cap grant linyilun session:renamed-test/create` → success
7. `runtime/esr exec /cap list` → shows `session:renamed-test/create`
8. `runtime/esr exec /workspace remove renamed-test --force` → cleanup

Each step asserts ok-true response.

- [ ] **Step 2: Add Makefile target + run + commit**

```bash
make e2e-14
```

Expected: PASS.

### Task 8.3: Subagent code-reviewer pass on the impl PR

After all phases land, before opening PR:

```
Use the superpowers:code-reviewer subagent on the branch
feature/workspace-vs-code-redesign-impl. Review against the spec at
docs/superpowers/specs/2026-05-06-workspace-vs-code-redesign.md.
Concerns to flag: any deviation from the spec, missing tests, broken
PR-222 security boundary, leftover references to old workspaces.yaml
shape.
```

Apply findings, then:

### Task 8.4: Open PR

```bash
gh pr create --base dev --title "Workspace VS-Code-style redesign: hybrid storage + UUID identity" \
  --body-file <(cat <<'EOF'
## Summary

Implements the workspace redesign per `docs/superpowers/specs/2026-05-06-workspace-vs-code-redesign.md` (rev 3, user-approved 2026-05-06).

- Hybrid storage: workspace.json lives in `<repo>/.esr/` (repo-bound) or `$ESRD_HOME/<inst>/workspaces/<name>/` (ESR-bound)
- UUID-based identity → free `/workspace rename` (no cap rewrites)
- 11 new slash commands for full lifecycle CLI management
- describe_topology now overlays `<dir>/.esr/topology.yaml` over workspace.json
- Old workspaces.yaml deleted on first boot (no migrator)
- No filesystem watcher — all mutations go through CLI inline-invalidate

## Operator pre-merge checklist

⚠️ Existing `~/.esrd/<inst>/workspaces.yaml` will be deleted on first boot under this PR.

Before pulling:
- `cat ~/.esrd-dev/default/workspaces.yaml` and copy any non-default settings to a notepad
- After merge: re-create workspaces via `/new-workspace <name> folder=<path>` for each project

## Test plan
- [x] `mix test` clean (excluding pre-existing dev failures)
- [x] PR-21z 5 security tests pass
- [x] e2e 14 (workspace lifecycle) green
- [x] Subagent code-reviewer pass

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)
```

---

## Self-review checklist (run before considering plan complete)

- [ ] **Spec coverage**: every numbered section in the spec maps to ≥1 task
- [ ] **Placeholder scan**: no "TBD", "TODO", "implement later"
- [ ] **Type consistency**: `Esr.Resource.Workspace.Struct` field names used consistently across phases (id, name, owner, folders, agent, settings, env, chats, transient, location)
- [ ] **Docs sweep**: Phase 8.1 lists all known doc paths from spec
- [ ] **Self-review final**: re-read this plan top-to-bottom in one sitting

---

## Execution

**Plan complete and saved to `docs/superpowers/plans/2026-05-06-workspace-vs-code-redesign-plan.md`. Two execution options:**

**1. Subagent-Driven (recommended)** — I dispatch a fresh subagent per task, review between tasks, fast iteration.

**2. Inline Execution** — Execute tasks in this session using executing-plans, batch execution with checkpoints.

**Which approach?**
