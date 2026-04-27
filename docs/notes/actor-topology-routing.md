# Actor topology routing — operator note

Captured alongside the PR-B / PR-C / PR-D series (2026-04-27). Maps the
spec at `docs/superpowers/specs/2026-04-27-actor-topology-routing.md`
to the operational surface area: yaml shape, log lines, what to grep,
how hot-reload behaves in practice.

## What changed for operators

Three additions to the daily operator surface:

1. **`workspaces.yaml`** gains an optional `neighbors:` list per
   workspace and an optional `name:` field per chat.
2. **The `<channel>` tag** that CC sees in its prompt now carries
   three new attributes: `workspace=`, `user_id=`, and (when there
   are neighbours) `reachable=` (JSON-encoded list of `{uri, name}`
   pairs).
3. **`workspaces.yaml` is hot-reloadable** — no esrd restart needed
   to add or revoke neighbours. (Removals are lazy: existing sessions
   keep the URI in their reachable_set; the cap gate handles the
   actual revocation at send time.)

## Authoring `workspaces.yaml`

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

  ws_kanban:
    cwd: /workspaces/kanban
    chats:
      - chat_id: oc_kanban_room
        app_id: feishu_app_kanban
        kind: group
        name: kanban-room
    # No `neighbors:` declared — ws_kanban inherits ws_dev as a
    # neighbour symmetrically because ws_dev declared workspace:ws_kanban.
```

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

### "Watcher not reacting to yaml edits"

```bash
grep "workspaces:" stdout.log | head
```

Expected on boot:
- `workspaces: file not present at <path>; will not watch` (only when
  yaml is missing — the watcher initialises on the next yaml write).

If the watcher is up but edits don't trigger reload:
- macOS `:file_system` library uses FSEvents. Editing under
  `/private/var/...` symlinked to `/var/...` works (basename match),
  but editor-side temp-file swap can trigger only `:stop` events.
  `vim`-style atomic writes are confirmed working; some editors that
  rename + delete are not.

### "Operator edited yaml but neighbour shows as still missing in tag"

The eager-add broadcast fires once per added URI. If a CC session
already has the URI in its reachable_set (because it learned it via
BGP earlier, or the broadcast already fired), no log line appears —
that's the idempotency check working as designed.

To force a re-render, send any inbound through the session — that
re-runs `build_channel_notification/2` with the current reachable_set.

## End-to-end verification

Manual smoke check after a yaml edit:

1. `cd $ESRD_HOME/$ESR_INSTANCE && cat workspaces.yaml` — confirm the
   new `neighbors:` entry parsed correctly.
2. Send an inbound to one of the workspace's chats from Feishu.
3. `grep '"reachable"' stdout.log | tail -1` — confirm the JSON-string
   attribute appears with the new URI.

Automated coverage:

- Unit: `mix test test/esr/topology_test.exs test/esr/workspaces/watcher_test.exs`
- Integration: `mix test test/esr/topology_integration_test.exs`
- cc_mcp pass-through: `(cd adapters/cc_mcp && uv run pytest tests/test_notification_inject.py)`
- Existing scenarios 01-04 don't exercise topology directly but
  serve as regression pins for the URI shape used by the topology
  layer (PR-B path-style migration is what `Esr.Topology.chat_uri/2`
  emits).

## Known limitations (spec follow-ups)

- **Addressability vs business-topology awareness**. PR-C's
  `reachable` attribute exposes 1-hop addressability — the agent
  knows who it can send to. It does NOT expose the agent's role
  in a multi-stage pipeline (e.g. "you are stage 2 of 4: translator
  → processor → polisher → exporter"). The LLM needs that broader
  context to make decisions like "don't polish the text yet — that's
  the next stage's job". Today this lives in agents.yaml system
  prompts and ad-hoc user prompts; PR-F will grill the design
  options (richer tag attribute vs agents.yaml schema vs status quo).
  Tracked as task #150.
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
- Flaky-tests cleanup: GitHub issue #57
- PR-B URI migration: PR #56 (merged)
- PR-C topology + reachable_set: PR #59 (merged, replaced PR #58)
- PR-D cc_mcp meta + spec fix: this PR
