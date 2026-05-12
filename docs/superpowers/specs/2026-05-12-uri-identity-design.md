# URI Identity Subsystem Design

**Status:** approved 2026-05-12 (linyilun, Feishu chat oc_d9b47511b085e9d5b66c4595b3ef9bb9 — brainstorm transcript in same chat)
**Supersedes:** `docs/superpowers/specs/2026-05-12-entity-resolver-design.md` (merged via PR #350, then pivoted)
**Author:** Claude Opus 4.7 (controller) + linyilun (decisions)

## 1. Goal + Non-goals

**Goal:** make `esr://` URIs the **single canonical name** for every actor (user / workspace / session / agent). Every domain-specific identifier — Feishu open_id, future Codex / Slack / Linear ids, by-name lookups — becomes an alias URI that **redirects** to the canonical URI. A single store (`Esr.Uri.Store`) holds both aliases and entity data. Two public operations replace the dozens of scattered `lookup_by_*` / `get_*_for_name` / `set_default_*` functions: **`resolve/1`** (read) and **`alias/2`** (write).

This eliminates the "lookup chain drift" class of bugs (chat-cap-check stopped mid-chain, `resolve_submitter` didn't accept UUID form, etc.) and gives plugin authors a clean extension point: declare your URI subtree + implement two callbacks, no core changes needed.

**Non-goals:**
- Data migration. No esrd instance is in production yet; existing yaml/json files are re-loaded into the URI store at boot via the new FileLoader. Users can wipe + rebuild freely.
- Capabilities subsystem unification. `Esr.Resource.Capability.has?/2` USES the URI store via `resolve/1`, but caps storage stays in `capabilities.yaml`.
- Deep URI nesting (e.g. `esr://workspaces/<uuid>/sessions/<name>`) — sub-data lives inside entity structs in PR-1; future PRs can add nested URI lookup if needed.
- `Esr.Entity` namespace from the superseded entity-resolver spec — entirely removed; no `Esr.Entity.resolve_by/3`.

## 2. Background

Two 2026-05-12 manual-test bugs surfaced the underlying drift class:
- Chat-side `Esr.Resource.Capability.has?/2` resolved `ou_xxx → username` but stopped there; caps were UUID-keyed → false negative.
- `Esr.Commands.Workspace.Resolve.resolve_submitter/1` only handled `submitted_by=<ou_xxx>` and `submitter_username=`; UUID form returned `:not_found`.

The first attempted fix was `Esr.Entity.resolve_by(kind, by, value)` — a polymorphic resolver. After two review iterations, that design accumulated too many edge cases (`:agent` UUID semantics, cross-module `defp` enforcement impossibilities, fabricated function signatures during plan-writing) without solving the core problem cleanly. The user proposed pivoting: **make URI the canonical identity, not just a serialization format**. That pivot is this spec.

## 3. Architecture overview

```
┌────────────────────────────────────────────────────────────────────┐
│                       PUBLIC: Esr.Uri                              │
│                                                                    │
│   resolve(uri :: String.t())                                       │
│     :: {:ok, canonical_uri :: String.t()} | :not_found             │
│   alias(canonical_uri :: String.t(), alias_uri :: String.t())      │
│     :: :ok | {:error, reason}                                      │
│   put_entity(canonical_uri, kind :: atom(), data :: struct())      │
│     :: :ok | {:error, reason}                                      │
│   get_entity(uri :: String.t())                                    │
│     :: {:ok, kind :: atom(), data :: struct()} | :not_found        │
│   delete(uri :: String.t()) :: :ok                                 │
│                                                                    │
└────────────────────┬───────────────────────────────────────────────┘
                     │ writes go via GenServer.call
                     ▼
┌────────────────────────────────────────────────────────────────────┐
│         Esr.Uri.Store (GenServer + public ETS)                     │
│                                                                    │
│  Single ETS table :esr_uri_store, :public, read_concurrency: true  │
│                                                                    │
│  Row formats (tagged value):                                       │
│    {uri :: String.t(), {:entity, kind :: atom(), data :: struct()}}│
│    {uri :: String.t(), {:alias, canonical_uri :: String.t()}}      │
│                                                                    │
│  Reads bypass GenServer (direct :ets.lookup, O(1) no lock).        │
│  Writes serialize through GenServer for alias→canonical invariant. │
└────────────────────┬───────────────────────────────────────────────┘
                     │ at boot
                     ▲
┌────────────────────┴───────────────────────────────────────────────┐
│                  Plugin URI Handlers                               │
│                                                                    │
│  Manifest declares per-plugin URI subtrees:                        │
│    uri_subtrees:                                                   │
│      - prefix: "users/feishu"                                      │
│        handler: Esr.Plugins.Feishu.UriHandler                      │
│                                                                    │
│  Handler implements `Esr.Uri.Plugin` behaviour:                    │
│    resolve(remaining_segments) → {:ok, canonical_uri} | :not_found │
│    alias(canonical_uri, alias_args) → {:ok, alias_uri} | error     │
└────────────────────────────────────────────────────────────────────┘
```

`Esr.Uri.Store` owns the data. `Esr.Uri` is the public API (callers see only this). Plugin handlers translate domain-specific identifiers to canonical URIs; they call `Esr.Uri.alias/2` from `/feishu:bind`-style commands to write aliases.

## 4. URI grammar

Canonical and alias URIs share the same parser (existing `Esr.Uri` module evolves from "passive serializer" to "the store's key"). Existing scheme `esr://[org@]host[:port]/<segment>(/<segment>)*` stays.

### 4.1 Canonical forms (4 kinds)

```
esr://users/<uuid>
esr://workspaces/<uuid>
esr://sessions/<uuid>
esr://agents/<uuid>          # the Instance.id (stable across CC+PTY restarts)
```

UUID v4 hyphenated lowercase hex. The canonical row in the store holds the entity struct (`%User{}`, `%Workspace.Struct{}`, etc.).

### 4.2 Core-reserved alias forms

Aliases the core URI module handles directly (no plugin involvement):

```
esr://users/by-name/<username>            → esr://users/<uuid>
esr://workspaces/by-name/<workspace_name> → esr://workspaces/<uuid>
esr://sessions/by-name/<session_name>     → esr://sessions/<uuid>   (within scope; see §4.4)
esr://agents/by-name/<agent_name>         → esr://agents/<uuid>     (within session scope)
```

### 4.3 Plugin-owned alias forms

Plugins claim URI subtrees in their manifest. Examples:

```
# feishu plugin
esr://users/feishu/<ou_xxx>     → esr://users/<uuid>

# future codex plugin
esr://agents/codex/<runtime_id> → esr://agents/<uuid>
```

The first segment AFTER the kind (`feishu`, `codex`, `by-name`, etc.) is the **dispatch key**. `by-name` and `by-uuid` are reserved by core; everything else is claimable by plugins.

### 4.4 Scope-shaped aliases (session, agent)

Session and agent names are scoped — same name can exist in different workspaces / sessions. Their by-name URIs require scope segments:

```
esr://sessions/by-name/<env>/<user_uuid>/<workspace_uuid>/<session_name>
esr://agents/by-name/<session_uuid>/<agent_name>
```

The scope segments are UUIDs, not names — keeping the alias URI stable across renames of any ancestor. Core resolves these aliases by walking `Esr.Uri.resolve/1` recursively (alias → canonical → entity → scope segment translation).

### 4.5 No alias-of-alias

Aliases always point to a **canonical** URI, never to another alias. `Esr.Uri.alias/2` rejects writes where the target is itself an alias (`{:error, :target_is_alias}`). This bounds resolve at exactly 1 hop.

## 5. Public API

### 5.1 `Esr.Uri.resolve/1`

```elixir
@spec resolve(String.t()) :: {:ok, canonical_uri :: String.t()} | :not_found

# Examples:
Esr.Uri.resolve("esr://users/cba75063-...")            #=> {:ok, "esr://users/cba75063-..."}
Esr.Uri.resolve("esr://users/by-name/linyilun")        #=> {:ok, "esr://users/cba75063-..."}
Esr.Uri.resolve("esr://users/feishu/ou_97f16490...")   #=> {:ok, "esr://users/cba75063-..."}
Esr.Uri.resolve("esr://users/feishu/ou_unknown")       #=> :not_found
Esr.Uri.resolve("not a uri")                           #=> :not_found
```

Reads do NOT go through the GenServer — direct `:ets.lookup` for O(1) latency.

### 5.2 `Esr.Uri.alias/2`

```elixir
@spec alias(canonical_uri :: String.t(), alias_uri :: String.t())
        :: :ok | {:error, :canonical_missing | :target_is_alias | :alias_exists | :invalid_uri}

Esr.Uri.alias("esr://users/cba75063-...", "esr://users/by-name/linyilun")
Esr.Uri.alias("esr://users/cba75063-...", "esr://users/feishu/ou_97f16490...")
```

Validates: (a) canonical URI exists and is `:entity`-tagged, (b) alias URI isn't already in use, (c) alias URI is well-formed. Returns error tuple on violation. Writes go through `Esr.Uri.Store` GenServer.

### 5.3 `Esr.Uri.put_entity/3`

```elixir
@spec put_entity(canonical_uri :: String.t(), kind :: atom(), data :: struct())
        :: :ok | {:error, :invalid_uri | :wrong_kind}
```

Used by FileLoaders at boot and by mutator commands (`/user:add`, `/workspace:new`, etc.) to write entity data into the store. The `kind` must match the URI's prefix (`esr://users/...` → kind = `:user`).

### 5.4 `Esr.Uri.get_entity/1`

```elixir
@spec get_entity(uri :: String.t())
        :: {:ok, kind :: atom(), data :: struct()} | :not_found
```

Resolves alias → canonical (if needed) then returns the tagged entity data. Convenience over `resolve/1` + manual `:ets.lookup`.

### 5.5 `Esr.Uri.delete/1`

```elixir
@spec delete(uri :: String.t()) :: :ok
```

Removes the URI row. If a canonical URI is deleted, any aliases pointing to it remain in the store but resolve to `:not_found` (orphan aliases). Operators clean these up via `/uri:gc` (future) or boot-time validation.

## 6. Plugin handler behaviour

```elixir
defmodule Esr.Uri.Plugin do
  @doc """
  Translate domain-specific identifier segments into a canonical URI.

  `remaining_segments` is the URI path AFTER the plugin's claimed prefix.
  E.g. for prefix "users/feishu" and URI "esr://users/feishu/ou_xxx",
  `resolve/1` is called with `["ou_xxx"]`.

  Implementations typically: look up the bound entity in the plugin's
  domain state, then return its canonical URI.
  """
  @callback resolve(remaining_segments :: [String.t()])
              :: {:ok, canonical_uri :: String.t()} | :not_found | :invalid_format

  @doc """
  Persist a binding from plugin domain identifier to a canonical URI.

  Called when a chat-side `/feishu:bind` (or equivalent) needs to register
  a new alias. The handler decides how to persist the binding (typically
  by writing to a plugin-owned yaml/json file) AND calls
  `Esr.Uri.alias/2` to register the alias URI in the store.

  `args` is a plugin-defined map; e.g. for feishu:
    %{ou_id: "ou_97f...", username: "linyilun"}
  """
  @callback alias(canonical_uri :: String.t(), args :: map())
              :: {:ok, alias_uri :: String.t()} | {:error, term()}
end
```

### 6.1 Manifest declaration

```yaml
# runtime/lib/esr/plugins/feishu/manifest.yaml (additive — keeps existing channels/agent_kinds/slash_routes/etc.)

uri_subtrees:
  - prefix: "users/feishu"
    handler: Esr.Plugins.Feishu.UriHandler
```

At boot, `Esr.Plugin.Loader` reads each manifest's `uri_subtrees:` block and registers `prefix → handler` mappings in `Esr.Uri` (e.g. `:persistent_term.put({Esr.Uri, :plugin_handlers}, %{"users/feishu" => Esr.Plugins.Feishu.UriHandler, ...})`).

### 6.2 Resolution dispatch

```elixir
# Inside Esr.Uri.resolve/1:
case parse(uri) do
  {:ok, %{segments: [kind | rest]}} when kind in @core_kinds ->
    case rest do
      [<<_::8*8, "-", _::4*8, "-", _::4*8, "-", _::4*8, "-", _::12*8>>] ->
        # Canonical: esr://users/<uuid>
        case :ets.lookup(@table, uri) do
          [{^uri, {:entity, _, _}}] -> {:ok, uri}
          _ -> :not_found
        end

      ["by-name", name] ->
        # Core-handled alias: lookup directly
        case :ets.lookup(@table, uri) do
          [{^uri, {:alias, canonical}}] -> {:ok, canonical}
          _ -> :not_found
        end

      [plugin_segment | rest2] ->
        # Plugin-claimed subtree: dispatch to handler
        case :persistent_term.get({__MODULE__, :plugin_handlers})[Path.join([kind, plugin_segment])] do
          nil -> :not_found
          handler -> handler.resolve(rest2)
        end
    end
end
```

## 7. Handler contract

To prevent `*_uri_handler.ex` files from accumulating unrelated business logic (a γ-route concern flagged during brainstorm; α still preserves the discipline for plugin code clarity), handler modules MUST contain only:

1. **Identifier translation logic** — mapping domain identifiers to canonical URIs (and back).
2. **Calls to plugin-owned persistence** — e.g. writing to the plugin's yaml/json, OR calling existing per-plugin commands like `Esr.Plugins.Feishu.Commands.BindUser.persist/2`.

Handlers MUST NOT contain:
- Capability checks (`Esr.Resource.Capability.has?/2`)
- Slash dispatch or command routing
- Direct PubSub broadcasts unrelated to the binding event
- Cross-kind logic (a `users/feishu` handler cannot touch `workspaces` or `sessions`)

Enforcement: code review checklist (no automated lint in PR-1; future PR could add a custom Credo check).

## 8. Storage schema

Single ETS table:

```
Table name:  :esr_uri_store
Type:        :set
Access:      :public           # reads bypass GenServer
Concurrency: read_concurrency: true, write_concurrency: false

Row formats:
  {uri :: String.t(), {:entity, kind :: atom(), data :: struct()}}
  {uri :: String.t(), {:alias,  canonical_uri :: String.t()}}
```

`kind` atom is one of `:user | :workspace | :session | :agent`. `data` struct types — using existing structs where available, introducing new ones only where missing:
- `:user` → `%Esr.Entity.User.Registry.User{username, feishu_ids: [], default_workspace_id: nil}` (today's struct at `runtime/lib/esr/entity/user/registry.ex:35-41`). Module name preserved during migration; the embedded struct moves with it. Future PR can rename to `Esr.Resource.User.Struct` once stable.
- `:workspace` → `%Esr.Resource.Workspace.Struct{}` (exists at `runtime/lib/esr/resource/workspace/struct.ex`).
- `:session` → `%Esr.Resource.Session.Struct{}` (exists at `runtime/lib/esr/resource/session/struct.ex`).
- `:agent` → `%Esr.Entity.Agent.Instance{}` (exists at `runtime/lib/esr/entity/agent/instance.ex`, includes `id`, `name`, `type`, `actor_ids`, `session_ids`). PR-1 keeps this struct; future PR can move to `Resource.Agent.Struct` for naming consistency.

**Reviewer note**: spec rev-1 named `Esr.Resource.User.Struct` and `Esr.Resource.Agent.Struct` which don't exist. Corrected to use the real existing struct identifiers.

GenServer `Esr.Uri.Store` owns the table; reads use direct `:ets.lookup`; writes serialize via `GenServer.call`. Reload at boot via `Esr.Uri.FileLoader.load_all/0` which reads `users.yaml`, all `workspaces/<name>/workspace.json`, etc., and populates the store.

## 9. Migration: replace 4 registries

Module deletions in PR-N (or sub-PRs):

| Module to DELETE | Replacement |
|---|---|
| `Esr.Entity.User.Registry` (data + lookup) | Entity data in URI store rows; lookup via `Esr.Uri.resolve/1` |
| `Esr.Entity.User.NameIndex` | Core handles `users/by-name/<n>` aliases internally |
| `Esr.Resource.Workspace.Registry` | URI store rows for entity data; `workspace_for_chat/2` becomes `Esr.Uri.resolve("esr://workspaces/by-chat/<chat_id>/<app_id>")` (core or plugin handler) |
| `Esr.Resource.Workspace.NameIndex` | Core handles `workspaces/by-name/<n>` |
| `Esr.Resource.Session.Registry` | URI store rows |
| `Esr.Session.NameIndex.Registry` | Core handles `sessions/by-name/<scope-tuple>` |
| `Esr.Entity.Agent.InstanceRegistry` | URI store rows for `agents/<uuid>` + scoped `by-name`; `actor_ids` map lives in the entity struct |
| `Esr.Session.ChatRouting.Registry` | Stays (it's about chat ↔ session binding, distinct from identity); might emit aliases like `sessions/by-chat-current/<chat_id>/<app_id>` |

FileLoaders rewritten to populate the URI store at boot instead of the per-kind ETS tables.

### 9.1 Migration map for call sites (~387 call sites total — reviewer correction)

**Important correction (spec rev-2)**: the original "39 lines / 29 files" estimate was leftover from the superseded entity-resolver spec and undercounts by ~10x. Actual counts from `grep -rn` against current `runtime/lib/` + `runtime/test/`:

| Module slated for deletion | Call sites (lib + test) |
|---|---:|
| `Esr.Entity.User.Registry` | 115 |
| `Esr.Resource.Workspace.Registry` | 94 |
| `Esr.Entity.Agent.InstanceRegistry` | 91 |
| `Esr.Resource.Workspace.NameIndex` | 38 |
| `Esr.Entity.User.NameIndex` | 21 |
| `Esr.Session.NameIndex.Registry` | 16 |
| `Esr.Resource.Session.Registry` | 12 |
| **Total** | **387** |

Plan must split this work into per-domain PRs (User / Workspace / Session / Agent), each ~100-150 LOC of migration work, with the URI store + plugin handler behaviour landing in PR-0 before any domain migration starts.

### 9.1.1 FileLoader scope clarification (reviewer P1)

ESR has 7 FileLoader modules. Only the 4 identity-related ones get rewritten to populate the URI store:
- **In scope**: `Esr.Entity.User.FileLoader`, `Esr.Resource.Workspace.FileLoader`, `Esr.Resource.Session.FileLoader` (if exists), `Esr.Entity.Agent.<...>.FileLoader` (if exists).
- **OUT of scope** (kept as-is): `Esr.Resource.Capability.FileLoader`, `Esr.Resource.SlashRoute.FileLoader`, `Esr.Interface.FileLoader`, `Esr.Session.ChatRouting.FileLoader` — these read non-identity data.

### 9.1.2 Application.ex insertion point (reviewer P1)

The new `Esr.Uri.Store` GenServer must be inserted into the Application supervision tree **BEFORE** the existing identity registries (since they get replaced). Suggested position: after `Esr.Resource.Sidecar.Registry` (line 79) / `Esr.Entity.Agent.StatefulRegistry` (line 86), BEFORE `Esr.Entity.Agent.InstanceRegistry` (line 96). Exact position decided in plan.

### 9.1.3 Migration replacement pattern

Each old-API call site replaces:

```elixir
# Before:
User.Registry.lookup_by_feishu_id(ou_xxx)  # returns {:ok, username}

# After:
case Esr.Uri.resolve("esr://users/feishu/" <> ou_xxx) do
  {:ok, canonical} -> Esr.Uri.get_entity(canonical)  # if need data
  :not_found -> ...
end
```

Migration happens phase-by-phase per kind (User first, then Workspace, etc.) — see plan.

## 10. Enforcement

### L1' Path-pattern CI gate

`mix esr.check_uri_drift` greps `runtime/lib/` for old-API patterns (`lookup_by_feishu_id`, `Workspace.Registry.get_by_id`, `NameIndex.id_for_name`, etc.). Allowed ONLY in:
- `runtime/lib/esr/uri/**/*.ex` (core URI module + dispatch)
- `runtime/lib/esr/uri/handlers/**/*.ex` (core-handled `by-name`, `by-uuid` aliases)
- `runtime/lib/esr/plugins/*/uri_handler.ex` (plugin handlers, naming-enforced)
- `runtime/lib/esr/uri/file_loader.ex` (boot data load)

Any other file containing an old-API call → CI FAIL. Per-file whitelist NOT supported; the path pattern IS the whitelist.

After Phase N (full migration), the old registry modules are physically deleted. The path-pattern gate then becomes vestigial (still useful as a defense against re-introducing similar APIs).

### L2 `@doc false` (transitional)

During the phase-by-phase migration window, before each registry's deletion: add `@doc false` and a moduledoc deprecation banner. After deletion, this becomes moot.

### L3 Handler contract

Code review checklist for handler modules (see §7). Reviewers reject handler PRs that contain non-translation logic.

### L4 (NOT needed — α is permanent)

Unlike the γ-route brainstorm, α has no transitional state — once all 4 registries are replaced, the URI store IS the storage. No deadline-based follow-up needed.

## 11. Tests

### 11.1 Per-API unit tests

- `Esr.Uri.resolve/1`: canonical → self; alias → canonical; not_found; invalid URI.
- `Esr.Uri.alias/2`: happy path; canonical_missing; target_is_alias; alias_exists; invalid_uri.
- `Esr.Uri.put_entity/3`: happy; wrong_kind; invalid_uri.
- `Esr.Uri.get_entity/1`: canonical input; alias input (chain through resolve); not_found.

### 11.2 Plugin handler tests

For each plugin shipped with a URI handler (feishu in PR-1):
- `resolve/1` happy + not_found + invalid_format.
- `alias/2` happy + error cases.
- Round-trip: `alias/2` writes; subsequent `resolve/1` finds it.

### 11.3 Regression tests for 2026-05-12 drift bugs

- Chat-side cap-check (was: chain stopped at username; now: `Capability.has?/2` calls `Esr.Uri.resolve("esr://users/feishu/<ou>")` → canonical → check UUID-keyed grants).
- CLI `submitted_by=<uuid>` resolves to a workspace (was: `:no_workspace_target`; now: workspace flow accepts the UUID URI directly).

### 11.4 Compile-fail enforcement

After full migration: the old registry modules are gone. A test asserting `Code.ensure_compiled(Esr.Entity.User.Registry) == {:error, :nofile}` locks the deletion.

### 11.5 E2E

- `tests/e2e/scenarios/31_uri_identity_chat_flow.sh` — full wipe → boot → register_adapter → /feishu:bind → /session:new flow succeeds without manual cap_grant.
- `tests/e2e/scenarios/32_uri_identity_cli_uuid_form.sh` — CLI submit with `submitted_by=<uuid>` resolves user-default workspace.

## 12. Suppressed concerns + future

### `Esr.Uri` namespace dual role (reviewer P1)

The existing `runtime/lib/esr/uri.ex` already defines `parse/1` (returns `%Esr.Uri{}` struct), `build/3`, `build_path/3`, `parse_resource/1`, `build_resource/3`, `to_http_url/2`, plus `defstruct [:org, :host, :port, :type, :id, :segments, :params]`.

PR-1 adds new functions to the SAME module: `resolve/1` (returns string), `alias/2`, `put_entity/3`, `get_entity/1`, `delete/1`. This creates a dual-role module (parser + store-facade). Acceptable but the moduledoc must distinguish the two roles clearly:

> `Esr.Uri` serves two purposes: (1) `parse/1`/`build*/1` are pure parser-builder functions for the `esr://` grammar; (2) `resolve/1`/`alias/2`/`put_entity/3` are the store facade. The two roles share the URI syntax but otherwise have independent state — parser is pure, facade dispatches to `Esr.Uri.Store` GenServer.

`def alias/2` is **legal Elixir** despite `alias` being a kernel directive — `alias` is recognized as a directive only at module-body level, not as a function call. Verified.

Alternative naming if dual-role feels uncomfortable: rename store facade to `Esr.Uri.Identity.resolve/1` etc. PR-1 default: keep `Esr.Uri` for both roles, decide on potential rename in a follow-up PR.

### `Esr.Session.ChatRouting.Registry`

Kept as-is in PR-1. Its job is "which session is currently bound to this chat" — a runtime relation, not an identity mapping. It can optionally emit a URI alias `esr://sessions/by-chat-current/<chat_id>/<app_id>` as a convenience for callers, but the underlying storage stays.

### Plugin-defined kinds (future)

Today only 4 kinds are first-class (`:user | :workspace | :session | :agent`). A future plugin (e.g. `:project`, `:repo`) could declare a new kind in its manifest and own the entire `esr://<new_kind>/...` subtree. Out of scope for PR-1.

### Nested URIs

`esr://workspaces/<uuid>/sessions/<uuid>` is not supported in PR-1's grammar; sessions are first-class top-level URIs with workspace_uuid as a field on the entity struct. Future PR can add path-style joins if needed.

## 13. References

- Brainstorm transcript: Feishu chat `oc_d9b47511b085e9d5b66c4595b3ef9bb9`, 2026-05-12
- Superseded spec: `docs/superpowers/specs/2026-05-12-entity-resolver-design.md` (PR #350, status banner added)
- Memory rule: [[feedback_uuid_is_canonical_identifier]]
- Existing URI parser: `runtime/lib/esr/uri.ex` (kept; evolves to call the new store)
- Todo `uri-as-canonical-actor-name`: superseded by this spec, will be marked closed in next docs/futures/todo.md update
