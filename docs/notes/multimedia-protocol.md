# Multimedia content protocol

**Date:** 2026-05-08
**Spec:** [`2026-05-08-multimedia-content-protocol-design`](../superpowers/specs/2026-05-08-multimedia-content-protocol-design.md)

ESR's per-peer envelope shape for non-text content (image, file —
audio/video/etc. follow as additive PRs). Surfaces the protocol's
moving parts so a contributor can add a new media type without
re-reading the entire spec.

## Envelope shape

All peer-to-peer non-text messages carry:

- `msg_type`: `"image"` | `"file"` (audio future)
- `content`: an `esr://<env>@<host>/resources/<media_type>/<sha256>.<ext>` URI
- `meta`: flat string-keyed map (channel-attribute discipline — keys must match `[A-Za-z0-9_]+`, nested children silently dropped)

For text envelopes: `content` is the text body string; no URI involved.

## Storage layout

```
$ESRD_HOME/$ESR_INSTANCE/resources/<media_type>/<sha256>.<ext>
$ESRD_HOME/$ESR_INSTANCE/resources/<media_type>/<sha256>.refs.jsonl
```

`<sha256>.<ext>` — bytes (source of truth, content-addressed).
`<sha256>.refs.jsonl` — append-only ref history (one JSON line per
referencing source); used by debug + future GC. **No
`.meta.json`** in MVP — the GC pass produces it on demand.

Atomic write: tmp + rename for bytes (POSIX atomic on same FS);
single-line JSON append for refs (POSIX-atomic for ≤PIPE_BUF lines).

## Adding a new media type

Each new type is a self-contained additive PR:

1. **URI grammar** — extend `@allowed_exts` in `runtime/lib/esr/uri.ex`
   and `_ALLOWED_EXTS` in `py/src/esr/uri.py`. Include the new media
   type's typical extensions; update both Elixir + Python in one PR
   per `docs/notes/esr-uri-grammar.md` rule.
2. **Phaser** — implement `Esr.Resource.Media.<X>Phaser` (Elixir
   `runtime/lib/esr/resource/media/<x>_phaser.ex`) + Python mirror
   (`py/src/esr/resource/media/<x>_phaser.py`). Register both in
   `PhaserRegistry`'s `@phasers` map / `_PHASERS` dict.
3. **Plugin manifests** — each plugin handling the new type adds it
   to `declares.media_types.{inbound,outbound}` in `manifest.yaml`
   AND to `[media_types]` in the corresponding `adapters/<name>/esr.toml`.
   `tests/integration/test_plugin_manifest_consistency.py` enforces
   strict equality.
4. **Tests** — unit tests for the new Phaser; e2e if a new flow is
   exercised.

## Failure modes

| Where | What | Recovery |
|---|---|---|
| Resolver | wrong env (URI's `<env>@` differs) | `:wrong_env`, dropped |
| Resolver | file gone (sha256 not on disk) | `:not_found`, dropped |
| Resolver | bad URI (sha256 / ext / media_type fails validation) | `:invalid_uri`, dropped |
| Phaser | unsupported target format | `{:error, {:unsupported_target, x}}` |
| Routing | downstream doesn't declare type in `media_types.inbound` | dropped + sender-keyed throttled DM (per D6) |
| Storage | `(media_type, ext)` doesn't match allowlist | `{:error, :unsupported_ext}` from `Esr.Resource.Media.store/3`, no I/O |

## See also

- `runtime/lib/esr/resource/media.ex` — the canonical store/resolve facade
- `runtime/lib/esr/resource/media/phaser_registry.ex` — dispatch
- `runtime/lib/esr_web/mcp_controller.ex` — SSE attachment notification (cc inbound exit)
- `runtime/lib/esr/plugins/feishu/feishu_chat_proxy.ex` — non-text inbound + DM gate
