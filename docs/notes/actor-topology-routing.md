# Actor topology routing — operator note

Captured alongside the PR-B / PR-C / PR-D series (2026-04-27). Maps the
spec at `docs/superpowers/specs/2026-04-27-actor-topology-routing.md`
to the operational surface area: yaml shape, log lines, what to grep,
how hot-reload behaves in practice.

**2026-05-06 update**: workspace storage moved from a single
`~/.esrd/<inst>/workspaces.yaml` to per-workspace `workspace.json`
files (ESR-bound or repo-bound). `Workspace.Watcher` was removed; the
CLI invalidates the Registry inline. Workspaces now have `folders[]`
instead of a single `root`. See
`docs/superpowers/specs/2026-05-06-workspace-vs-code-redesign.md`.
Operator recipes below reflect the pre-redesign yaml shape and are kept
as historical reference for the topology/neighbours behaviour, which is
otherwise unchanged.

## What changed for operators

Three additions to the daily operator surface (as of PR-B/C/D):

1. **Workspace config** gains an optional `neighbors:` list per
   workspace and an optional `name:` field per chat. (Post-2026-05-06:
   each workspace stores this in its own `workspace.json` rather than a
   shared `workspaces.yaml`.)
2. **The `<channel>` tag** that CC sees in its prompt now carries
   three new attributes: `workspace=`, `user_id=`, and (when there
   are neighbours) `reachable=` (JSON-encoded list of `{uri, name}`
   pairs).
3. **Workspace config changes take effect immediately** — the CLI
   invalidates the Registry inline; no esrd restart needed. (The old
   `Workspace.Watcher` GenServer was removed in the 2026-05-06
   redesign. Removals are still lazy: existing sessions keep the URI in
   their reachable_set; the cap gate handles the actual revocation at
   send time.)

## Authoring workspace config (pre-2026-05-06 `workspaces.yaml` format)

```yaml
schema_version: 1
workspaces:
  ws_dev:
    cwd: /workspaces/dev
    role: dev
    chats:
      - chat_id: oc_dev_room
        app_id: feishu_app_dev
        kind: group
        name: dev-room              # optional — feeds the reachable list display name
      - chat_id: oc_dev_dm
        app_id: feishu_app_dev
        kind: p2p
    neighbors:                       # optional — strict <type>:<id> form
      - workspace:ws_kanban          # → all chats under ws_kanban become reachable
      - chat:oc_legal_special        # → that chat becomes reachable (workspace inferred via reverse-lookup)
      - user:ou_admin                # → that user URI becomes reachable
      - adapter:feishu:app_other     # → that adapter URI becomes reachable
    metadata:                        # PR-F: free-form business-topology context
      purpose: "Engineering team's day-to-day discussion"
      pipeline_position: 1
      hand_off_to: "ws_kanban"
      output_format: "markdown with code blocks"

  ws_kanban:
    cwd: /workspaces/kanban
    chats:
      - chat_id: oc_kanban_room
        app_id: feishu_app_kanban
        kind: group
        name: kanban-room
    # No `neighbors:` declared — ws_kanban inherits ws_dev as a
    # neighbour symmetrically because ws_dev declared workspace:ws_kanban.
    metadata:
      purpose: "Track engineering tasks; expects items in ##title|body## format"
      pipeline_position: 2
```

### `metadata:` — what to put there

PR-F's `mcp__esr-channel__describe_topology` MCP tool exposes the
`metadata:` sub-tree to the LLM verbatim. Operators populate it with
business-topology context that helps the LLM stay in lane:

| Field | Purpose |
|---|---|
| `purpose` | One-line description of this workspace's role in the broader system |
| `pipeline_position` | Where this stage sits if the workspace is part of a chain (1, 2, 3, ...) |
| `hand_off_to` | Next workspace name(s) when this one's job is done |
| `output_format` | Format/schema downstream stages expect |
| `not_my_job` | Things this workspace explicitly should NOT do (let downstream handle) |

The schema is **open** — operators add fields as their pipelines
demand. The LLM reads them and reasons accordingly. Code changes are
not required to add new fields.

### `metadata:` — what NOT to put there

`metadata:` is exposed to the LLM. **Do not put secrets there**:
- API keys → use `env:` (filtered out of the tool response)
- Filesystem paths to private dirs → use `cwd:` (also filtered)
- Personally identifying info beyond what's already in chats[]

Symmetric-closure rules (spec §6.4):

- `workspace:<other>` declarations are bidirectional. Declaring once is
  enough for both endpoints to see each other.
- `chat:` / `user:` / `adapter:` declarations are unidirectional. Adding
  them creates one-way reachability.
- Asymmetric *capabilities* (e.g. ws_dev can post to ws_kanban but not
  vice versa) live in `capabilities.yaml` — the topology graph just
  expresses *visibility*; the cap gate decides *permission*.

## What to grep when something looks wrong

### "CC isn't seeing kanban as a neighbour"

```bash
grep "topology:" stdout.log | tail
```

Expected lines:
- `cc_process: topology hot-reload added uri session_id=...` → the
  watcher pushed an addition into an active session.
- `cc_process: learned URIs session_id=... uris=[...]` → the BGP-style
  inbound learning saw a new source/principal URI.

If neither appears after editing yaml, the watcher didn't pick up the
change — see "Watcher not reacting" below.

### "Workspace edit not reflected in Registry"

`Workspace.Watcher` was removed in the 2026-05-06 redesign. The CLI
now invalidates the Registry inline after every write. If a workspace
change is not reflected, verify the CLI command completed successfully
(check exit code); a stale Registry entry after a CLI write is a bug.

### "Operator edited yaml but neighbour shows as still missing in tag"

The eager-add broadcast fires once per added URI. If a CC session
already has the URI in its reachable_set (because it learned it via
BGP earlier, or the broadcast already fired), no log line appears —
that's the idempotency check working as designed.

To force a re-render, send any inbound through the session — that
re-runs `build_channel_notification/2` with the current reachable_set.

## End-to-end verification

Manual smoke check after a workspace config edit:

1. `runtime/esr exec /workspace info name=<ws>` — confirm the
   new `neighbors:` entry parsed correctly.
2. Send an inbound to one of the workspace's chats from Feishu.
3. `grep '"reachable"' stdout.log | tail -1` — confirm the JSON-string
   attribute appears with the new URI.

Automated coverage (counts as of 2026-04-28):

| What | Where | Tests |
|---|---|---|
| Topology unit logic (initial_seed, neighbour_set, symmetric closure) | `runtime/test/esr/topology_test.exs` | 16 |
| BGP-style learn + tag rendering | `runtime/test/esr/peers/cc_process_test.exs` | 13 |
| `<channel>` JSON-string attribute filter | `adapters/cc_mcp/tests/test_notification_inject.py` | 8 |
| `cli:workspaces/describe` (PR-F) | `runtime/test/esr_web/cli_channel_test.exs` | 22 |
| `describe_topology` injection (PR-F) | `adapters/cc_mcp/tests/test_describe_topology_invoke.py` | 5 |
| `Workspaces.Registry` neighbours / metadata round-trip | `runtime/test/esr/workspaces_registry_test.exs` | 8 |
| Registry inline invalidation (post-2026-05-06) | `runtime/test/esr/workspaces_registry_test.exs` | (see test suite) |
| Path-style URI parser (PR-B) | `runtime/test/esr/uri_test.exs` | 23 |
| Compose C1-C5 chain | `runtime/test/esr/topology_integration_test.exs` | 1 |
| End-to-end (mock_feishu → CC) | `tests/e2e/scenarios/05_topology_routing.sh` | 8 assertions |

Run them all:

```bash
(cd runtime && mix test test/esr/topology_test.exs \
                        test/esr/peers/cc_process_test.exs \
                        test/esr_web/cli_channel_test.exs \
                        test/esr/workspaces_registry_test.exs \
                        test/esr/topology_integration_test.exs \
                        test/esr/uri_test.exs)

(cd adapters/cc_mcp && uv run --with pytest --with pytest-asyncio pytest \
    tests/test_notification_inject.py tests/test_describe_topology_invoke.py)

bash tests/e2e/scenarios/05_topology_routing.sh
```

Existing scenarios 01-04 don't exercise topology directly but serve as
regression pins for the URI shape used by the topology layer (PR-B
path-style migration is what `Esr.Topology.chat_uri/2` emits).

## Known limitations (spec follow-ups)

- ~~**Addressability vs business-topology awareness**~~. **Resolved by
  PR-F (2026-04-28)**: the `mcp__esr-channel__describe_topology` MCP
  tool exposes the current workspace's `metadata:` sub-tree + 1-hop
  neighbour metadata to the LLM. Operators populate `metadata:` with
  business-topology context (`purpose`, `pipeline_position`,
  `hand_off_to`, ...) and the LLM reads it on demand without code
  changes. See spec
  `docs/superpowers/specs/2026-04-28-business-topology-mcp-tool.md`
  and the §"Authoring workspace config" → `metadata:` section above.
- **`<reachable>` is a JSON-string attribute, not a nested element**.
  `notifications/claude/channel` (Claude Code's experimental channel
  injection API) only forwards flat attributes matching
  `[A-Za-z0-9_]+`. Nested children like `<reachable><actor/></reachable>`
  are silently dropped. PR-D pivoted to JSON-string; spec §8 documents
  the constraint.
- **`<channel> user=` is still the open_id**, not a display name.
  Spec §8.1 calls for `user` to become the display name in v2. v1
  ships `user_id=` as a redundant alias so cc_mcp's existing prompt
  template stays compatible.
- **Display-name resolution for users** (FAA's open_id → display
  cache) isn't threaded through to `cc_process` yet. The `name`
  field on `user:<open_id>` URIs falls back to a short open_id.
- **No e2e scenario for topology**. The integration test
  (`topology_integration_test.exs`) covers the runtime side end-to-end;
  cc_mcp tests cover the IPC pass-through. A real-claude-turn scenario
  was deferred — see the next section.

## Future work

- **Scenario 05 (real claude turn)**: validate the LLM actually uses
  the `reachable` attribute to route by URI when the user asks for
  cross-workspace forwarding. Manual / soak check today.
- **`user` rename to display name**: coordinated cc_mcp prompt
  template update.
- **Per-edge metadata** (`mode`, `visibility`): yaml schema reserves
  the upgrade path; not implemented in v1.

## See also

- Spec: `docs/superpowers/specs/2026-04-27-actor-topology-routing.md`
- Architecture: `docs/architecture.md` §"Topology + reachable_set"
- Workspace redesign: `docs/superpowers/specs/2026-05-06-workspace-vs-code-redesign.md`
- Flaky-tests cleanup: GitHub issue #57
- PR-B URI migration: PR #56 (merged)
- PR-C topology + reachable_set: PR #59 (merged, replaced PR #58)
- PR-D cc_mcp meta + spec fix: this PR
