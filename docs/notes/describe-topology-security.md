# `describe_topology` security boundary

**Filed**: 2026-04-30 (PR-21z)

## What

The `describe_topology` MCP tool (PR-F, 2026-04-28) is the only place where workspace yaml data is returned verbatim to the LLM. Operators put context fields in `metadata` for the LLM to read (`purpose`, `pipeline_position`, `hand_off_to`, etc.), and the tool's design intent is "non-secret yaml metadata + 1-hop neighbour info."

This makes the response builder a security boundary. Adding a new field to `%Esr.Workspaces.Registry.Workspace{}` that the LLM has no business reading would silently leak it.

## How we enforce it

Single allowlist in `Esr.PeerServer.filter_workspace_for_describe/1`:

```elixir
%{
  "name"          => ws.name,
  "role"          => ws.role || "dev",
  "chats"         => …allowlisted sub-fields…,
  "neighbors_declared" => ws.neighbors || [],
  "metadata"      => ws.metadata || %{}
}
```

**Excluded by design:**
- `owner` — esr-username; sensitive once paired with `users.yaml`'s feishu_ids. `describe_topology` is principal-agnostic on purpose.
- `start_cmd` — operator config; can leak shell paths / args.
- `env` — workspace env block; may carry secrets.

The `chats` sub-map uses its own allowlist for the same reason.

## Out of scope (never reachable)

`Esr.Users.Registry` data — the binding between esr-username and Feishu open_id — is not read by `build_emit_for_tool("describe_topology", _, _)` at all. There is no path through the response builder to `users.yaml`. Default-deny holds.

## Adding a new exposed field

If a future field on `%Workspace{}` *should* be visible to the LLM:

1. Add it to `filter_workspace_for_describe/1`
2. Add a regression test in `test/esr/peer_server_describe_topology_test.exs` asserting the field IS present
3. Update this note's "Excluded by design" list if you remove an exclusion

## Tests

[`runtime/test/esr/peer_server_describe_topology_test.exs`](../../runtime/test/esr/peer_server_describe_topology_test.exs) — 5 regression tests:

1. Response includes only the allowlisted top-level keys (frozen list)
2. `owner` filtered (esr-username)
3. `start_cmd` / `env` filtered (operator config)
4. `chats` sub-map allowlisted (no surprise nested fields like a future `feishu_user_ids`)
5. `users.yaml` data never reachable (sanity check — even with `Users.Registry` populated, the response carries no feishu_id)

## Related

- [`actor-role-vocabulary.md`](actor-role-vocabulary.md) — `*Guard` and `*State` role definitions
- CLAUDE.md gotcha #3 — `metadata:` is LLM-visible; never put secrets there. Use `env:` or `cwd:` (filtered).
