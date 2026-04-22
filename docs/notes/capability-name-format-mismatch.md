# Capability Name Format: Spec Says `cap.*`, Code Requires `prefix:name/perm`

## Context

Discovered 2026-04-22 during PR-2 P2-13 (E2E smoke test).

Spec v3.1 §3.5 has `agents.yaml` entries like:

```yaml
agents:
  cc:
    capabilities_required:
      - cap.session.create
      - cap.tmux.spawn
      - cap.handler.cc_adapter_runner.invoke
```

And spec §3.6 has PeerProxy check:

```yaml
@required_cap "cap.peer_proxy.forward_feishu"
```

## Observation

`Esr.Capabilities.Grants.matches?/2` only accepts grants of these shapes:

1. Bare `*` — matches any required permission
2. `<prefix>:<name>/<perm>` — where `<prefix>`, `<name>`, `<perm>` can each be literal or `*` (whole-segment wildcards)

It parses the permission string by splitting on `/` then on `:`. A bare `cap.session.create` has no `/`, so the first split produces a single element and `matches?/2` fails (`split` returns `:error`).

Empirical verification: `Grants.has?("ou_user", "cap.session.create")` returns `false` even when ETS has `{"ou_user", ["cap.session.create"]}` — the match function rejects the shape.

## Implication

1. **Spec shape (`cap.*`) doesn't match code contract (`prefix:name/perm`).** Two options:
   - Change the spec's example entries to use the prefix:name/perm shape:
     - `cap.session.create` → `cap:session/create` or `session:default/create`
     - `cap.tmux.spawn` → `tmux:default/spawn`
     - `cap.peer_proxy.forward_feishu` → `peer_proxy:feishu/forward`
   - Extend `Grants.matches?/2` to accept the `cap.*` dotted-name shape as equivalent to some canonical prefix:name/perm form.
2. PR-2 P2-4 (FeishuAppProxy with `@required_cap "cap.peer_proxy.forward_feishu"`) does NOT fail today because its test-path uses `:esr_cap_test_override` in process dict that bypasses Grants entirely. In production, that check would silently always fail-closed (drop with `:unauthorized`).
3. PR-3 P3-8 (Admin.Commands.Session.New with `capabilities_required` verification) hits this in full form.

## Implementation recommendation

**Change the spec, not the code.** The `prefix:name/perm` form is:
- Already supported and tested
- Used consistently by existing grants like `workspace:proj-a/msg.send` and `workspace:*/session.create`
- More expressive (the `prefix` dimension lets you distinguish capability categories like `workspace:`, `session:`, `tmux:`, `voice_pool:`)

Proposed canonical forms for the spec's example agents:

| Spec (old) | Spec (proposed) |
|---|---|
| `cap.session.create` | `session:default/create` |
| `cap.tmux.spawn` | `tmux:default/spawn` |
| `cap.handler.cc_adapter_runner.invoke` | `handler:cc_adapter_runner/invoke` |
| `cap.peer_proxy.forward_feishu` | `peer_proxy:feishu/forward` |
| `cap.peer_pool.voice_asr.acquire` | `peer_pool:voice_asr/acquire` |

## Mitigation (short-term)

Until the spec is updated:

- Tests use `["*"]` grants to exercise positive paths (bypasses the format check entirely)
- `@required_cap` strings in production code should use the working prefix:name/perm form, NOT the `cap.*` form from the spec example
- `agents.yaml` fixtures should use the working form too

## Future

Resolve in one of:

1. **PR-3 P3-8** — the "consolidate Session.New + Session.AgentNew + verify capabilities_required" task. Good natural home: before hooking the verification end-to-end, canonicalize the names spec-wide.
2. **PR-5** cleanup — part of the final doc sweep.

**Priority: P3-8 is better** — deferring to PR-5 means the spec's examples look wrong for the duration of PR-3 / PR-4, confusing anyone reading the spec during that window.

## Spec update target

- `docs/superpowers/specs/2026-04-22-peer-session-refactor-design.md` §3.5 agents.yaml examples
- `docs/superpowers/specs/2026-04-22-peer-session-refactor-design.md` §3.6 PeerProxy example
- `docs/superpowers/specs/2026-04-22-peer-session-refactor-design.md` §1.8 D18 entry
