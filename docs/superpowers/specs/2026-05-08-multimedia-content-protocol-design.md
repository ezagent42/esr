# Multimedia content protocol — design

**Date:** 2026-05-08
**Status:** Brainstorm output, awaiting review
**Owner:** Allen Woods
**Modifies:** PRD 04 §F14 / §10.1 (file/image/audio handling — `download_file` directive output contract changes; storage layout moves)
**Origin:** `docs/futures/todo.md` "Feishu file / image / audio inbound" (long-pending since 2026-05-02 — surfaced again in the 2026-05-08 post-multi-instance audit)

## Decisions (locked during 2026-05-08 brainstorm)

These are pinned up-front because they are spec-blocking, not
implementation details. Reviewers should see the resolution before
reading the flow diagrams below. Each was discussed and chosen during
the brainstorm; rationale captured per row.

| # | Decision | Rationale |
|---|---|---|
| D1 | Module namespace = `Esr.Resource.Media.*` | The top-level `Esr.Resource.*` namespace already hosts ~20 identity-type modules (Capability, Workspace, ChatScope, SlashRoute, …). Adding "bytes-on-disk" semantics there would dilute meaning. `Esr.Resource.Media` reads as "a kind of Resource that is media bytes" without colliding with identity-type Resources. |
| D2 | Resource URI = top-level `esr://<env>@<host>/resources/<media_type>/<sha256>.<ext>` (not nested under workspaces/sessions) | Content-addressing is intentionally *orthogonal* to workspace/session scope: the same SHA-256 served from any chat or session points at the same bytes, with refs[] tracking the chats that referenced it. Nesting under `workspaces/<ws>/...` would lose dedup across workspaces and complicate the future GC sweep. |
| D3 | Concurrent store-of-same-sha256 atomicity = append-only `<sha>.refs.jsonl` + tmp-rename for bytes; `.meta.json` is a derived cache rebuilt from `.refs.jsonl` on boot | POSIX guarantees: append to existing file is atomic for ≤PIPE_BUF writes; rename within same FS is atomic. Refs are append-only single-line JSON; meta is a cache. No locks, no GenServer hot-spot, crash-safe by construction. |
| D4 | `send_file` outbound = upstream `Esr.Resource.Media.store` + URI envelope at peer level; downstream Elixir→Python sidecar wire preserves existing α-shape (`{chat_id, file_name, content_b64, sha256}`) | The α-wire is the deliberate Python-adapter-uniformity boundary (`feishu_chat_proxy.ex:480-524` comment "Do the read + hash + encode at the Elixir boundary so the Python adapter's contract stays uniform across all channel adapters"). The peer-level envelope can be URI-shaped without touching the sidecar contract; FCP's outbound branch resolves URI → Path → existing `read_file_for_send` → existing `_send_file` directive. PR-3 stays Elixir-only (~200 LOC). |
| D5 | PR-1 atomicity | The loader-rejection check + cc manifest update + feishu manifest update + adapter `esr.toml` `[media_types]` block all ship in one atomic commit. No partial migration window where the loader rejects manifests that have not yet been updated. |
| D6 | Capability-miss throttling key = `(sender_id, kind)`, not `(chat_id, kind)` | Group chats with multiple senders pasting unsupported types: per-chat throttle hides all but the first sender's drop. Per-sender throttle gives every sender at least one feedback DM. |

## Abstract

Today ESR's per-peer message envelopes carry only `text`. Any non-text
inbound (image / file / audio / interactive / sticker / post) from
Feishu is silently dropped: an operator who pastes a screenshot to a
chat-bot gets nothing back. The Python `feishu` adapter parses the
event types, but no downstream actor consumes them, no bytes are
fetched from Lark, and no shape exists for cc to receive an
attachment.

This spec introduces a **media-type-agnostic content protocol** so any
peer (today: Feishu adapter, Claude Code; future: Slack / Discord /
voice peers) can send and receive structured non-text content via a
single shared abstraction:

```
envelope = { msg_type: <kind>, content: <text | esr://... resource URI>, meta: {...} }
```

Resources live at content-addressed paths under
`$ESRD_HOME/$ESR_INSTANCE/resources/<media_type>/<sha256>.<ext>`,
referenced by a new `resources` path-style segment in the `esr://` URI
grammar, fetched lazily, and converted to consumer-side formats by
per-media-type **Phasers**. Adapters declare their supported inbound /
outbound media types in `manifest.yaml`; the routing layer fail-fasts
on unsupported types.

Feishu becomes the first concrete consumer of the protocol; Claude
Code receives attachments as channel notifications carrying a `kind` +
`path` meta-pair that Claude reads with its existing Read tool.

## Background

### Current state on `origin/dev` `5c5357b` (2026-05-08)

- Plugin layout (Phase 6/7 + #263 session-first migration finished):
  - `runtime/lib/esr/plugins/{claude_code,feishu}/manifest.yaml`
    declares entities, sidecars, capabilities, slash routes, config
    schema (no media-type concept today).
  - Python sidecars live under `py/src/{feishu_adapter_runner,
    cc_adapter_runner, generic_adapter_runner}` plus shared
    `_adapter_common` / `_ipc_common`. The legacy `adapters/cc_mcp/`
    is gone; cc inbound notifications now flow through
    `runtime/lib/esr_web/mcp_controller.ex` (HTTP MCP transport with
    JSON-RPC POST + SSE GET, replacing the old stdio bridge).
  - The Feishu Python adapter package (`adapters/feishu/`) survives;
    its runner is `py/src/feishu_adapter_runner/`. The package
    declares I/O permissions in `adapters/feishu/esr.toml` for
    purity tests.
- `Esr.Uri` registered path-style types: `~w(adapters workspaces
  chats users sessions)a` (`runtime/lib/esr/uri.ex:33`). Python
  mirror at `py/src/esr/uri.py`. **`resources` is not yet
  registered.**
- PRD 04 §F14 specifies "lazy download": `emit_events()` yields
  `args={msg_id, file_key, file_name, msg_type}` for non-text;
  `download_file` directive fetches bytes to
  `~/.esrd/<instance>/uploads/<chat_id>/<file_name>`. The directive
  is wired in the Python adapter (`adapters/feishu/tests/test_download.py`)
  but no Elixir-side consumer exists — the bytes have nowhere to go.
- `<channel>` notifications (`docs/notes/claude-code-channels-reference.md`):
  flat-attribute discipline — keys must match `[A-Za-z0-9_]+`,
  nested children are silently dropped. Values are unconstrained
  strings.

### Why now

`docs/futures/todo.md` has tracked "Feishu file / image / audio
inbound" since 2026-05-02. The 2026-05-08 post-multi-instance audit
re-surfaced it as a missing first-30-minutes UX item. With
plugin-physical-migration shipped (#246) and session-first
default landed (#263), the protocol layer is the next stable enough
surface to extend without rebasing through architecture churn.

### What this spec is, and isn't

This spec is **protocol-first**: the content envelope, the URI
grammar, the Resolver / Phaser modules, the manifest declaration. It
covers Feishu image + file as the first concrete consumer (because
that closes the live operator pain), and cc image + file outbound to
match the existing `send_file` MCP tool.

It is **not** a full Feishu multimedia overhaul. Audio / video /
interactive cards / sticker / post / share_chat are explicitly out
of scope; once the protocol exists, each future media type is an
additive PR (new Phaser + manifest entry).

## Goals

1. Single content envelope shape `{msg_type, content, meta}` that all
   peers send and receive across IPC boundaries.
2. New `resources` path-style segment in the `esr://` URI grammar,
   content-addressed by SHA-256, with mirrored Elixir + Python
   parsers.
3. Per-`media_type` Phaser modules that convert resolved URIs to the
   format a consumer needs (`:path` / `:base64_data_url` / `:bytes`
   / `:inline_text`).
4. Plugin `manifest.yaml` declares `media_types.{inbound,outbound}`;
   Python `esr.toml` mirror declares the same; CI cross-check fails
   on drift.
5. Routing layer fail-fasts unsupported media types with a one-shot
   warning DM (no silent drop).
6. End-to-end: operator drops a PNG into Feishu chat, cc reads it via
   its Read tool; cc invokes `send_file` with a path, operator sees
   the image in Feishu.

## Non-goals

- Streaming Phasers (audio / video real-time). Callback shape
  reserved (`streaming?/0`); implementation deferred.
- Remote URI dereferencing (URI pointing at Lark CDN rather than a
  local file). All resource URIs in this spec resolve to local files.
- Cross-esrd-instance resource sharing (env A's resources fetched
  by env B). The `<env>@<host>` URI segment is preserved but
  cross-host fetch is unimplemented.
- Per-user resource quota / disk caps.
- Resource garbage collection. Tracked as a follow-up in
  `docs/futures/todo.md`.
- audio / video / interactive / sticker / post / share_chat /
  share_user / location / system / hongbao / vote / video_chat /
  calendar / folder. Each becomes a single-Phaser additive PR
  after this spec lands.
- Backward-compat for plugin manifests without `media_types:`.
  Plugin manifests that declare entities of a peer kind expected to
  send / receive content **must** include the block; loader rejects
  on miss. Operators of in-tree plugins (claude_code, feishu)
  receive the update in this work; out-of-tree plugin authors must
  update.

## Design

### 1. URI grammar extension

#### Why a new top-level `resources` segment, not nesting under workspaces/sessions

`docs/notes/esr-uri-grammar.md:156-169` rightly mandates: "First, ask:
can an existing type carry the new shape?" Considered + rejected:

- `workspaces/<ws>/resources/<media>/<sha>` — content-addressed dedup
  becomes per-workspace; the same screenshot pasted to two workspaces
  occupies disk twice. Future GC must walk every workspace.
- `sessions/<sid>/resources/...` — even worse: ties resource lifetime
  to session lifetime. Inbound arriving before SessionRouter routes a
  session has no `<sid>` yet.
- `chats/<chat>/resources/...` — couples resource to chat that
  referenced it; refs[] already does this without bending the URI.

Top-level `resources/` is the right level because **content-addressing
is orthogonal to all existing scopes**. The same SHA-256 from any
sender, in any chat, in any workspace, is *the same bytes*. Refs[]
tracks the (chat, msg, file_key) tuples that pointed to it; the URI
itself is scope-free.

#### 1.1 New path-style type `resources`

Register `:resources` in `runtime/lib/esr/uri.ex` `@path_style_types`
and `_PATH_STYLE_TYPES` in `py/src/esr/uri.py`. Path shape:

```
esr://<env>@<host>/resources/<media_type>/<sha256_hex>.<ext>

<media_type>  ∈ {image, file, audio}     # MVP set; extends additively
<sha256_hex>  64-char lowercase hex of file content
<ext>         original extension lowercased; type hint, not authoritative
```

Examples:

```
esr://default@localhost/resources/image/3a4b5c6d7e8f9a0b1c2d3e4f5a6b7c8d9e0f1a2b3c4d5e6f7a8b9c0d1e2f3a4b.png
esr://prod@esrd-1.internal:4001/resources/file/c29mZWJlZWZkZWFkYmVlZi4uLg.bin
```

#### 1.2 Typed builder + parser in `Esr.Uri`

User feedback (2026-05-08 brainstorm §3): URI parsing logic is
single-sourced in `Esr.Uri`. The Resolver does not re-parse URIs.

Add to `Esr.Uri`:

```elixir
@spec parse_resource(String.t() | t()) :: 
        {:ok, %{media_type: atom(), sha256: String.t(),
                ext: String.t(), env: String.t() | nil,
                host: String.t()}} 
        | {:error, atom()}

@spec build_resource(media_type :: atom(), sha256 :: String.t(), 
                     opts :: keyword()) :: String.t()
# opts: :ext (default "bin"), :env, :host
```

Mirrored in Python (`esr.uri.parse_resource`, `esr.uri.build_resource`).

#### 1.3 Fix known gap: `build_path/2` does not accept env

`docs/notes/esr-uri-grammar.md` notes that Elixir `build_path/2`
silently drops the `org@` segment. Resource URIs are env-scoped
(`<env>@<host>` is load-bearing — different esrd instances share host
but not state directory). Extend `Esr.Uri.build_path/3` to accept
`env: String.t()` keyword. Add Elixir test mirroring the existing
Python `build_path(..., org="default")` test.

### 2. Resource storage layout

```
$ESRD_HOME/$ESR_INSTANCE/resources/
├── image/
│   ├── <sha256>.png                 # bytes (SoT)
│   ├── <sha256>.refs.jsonl          # SoT for ref history (append-only)
│   ├── <sha256>.meta.json           # derived cache, rebuilt on boot
│   └── ...
├── file/
│   ├── <sha256>.bin
│   ├── <sha256>.refs.jsonl
│   ├── <sha256>.meta.json
│   └── ...
└── audio/                           # created on demand by future audio PR
```

`<sha256>.refs.jsonl` is the source of truth for who-referenced-this.
One JSON object per line, append-only:

```jsonl
{"adapter":"feishu","instance":"main_bot","chat_id":"oc_xxx","msg_id":"om_yyy","file_key":"file_xxx","received_at":"2026-05-08T14:23:01Z"}
{"adapter":"feishu","instance":"main_bot","chat_id":"oc_zzz","msg_id":"om_qqq","file_key":"file_zzz","received_at":"2026-05-08T14:24:30Z"}
```

`<sha256>.meta.json` is a derived cache (boot-time rebuild from
`<sha256>.refs.jsonl` + file stat). It exists for human-debug and
fast queries, never as input to `store/3`. Schema:

```json
{
  "sha256": "3a4b...",
  "media_type": "image",
  "original_filename": "screenshot.png",
  "mime_type": "image/png",
  "size_bytes": 152034,
  "first_seen_at": "2026-05-08T14:23:01Z",
  "refs": [
    {
      "source_adapter": "feishu",
      "source_instance": "main_bot",
      "chat_id": "oc_xxx",
      "msg_id": "om_yyy",
      "file_key": "file_xxx",
      "received_at": "2026-05-08T14:23:01Z"
    }
  ]
}
```

`refs[]` (in `.meta.json`, derived from `.refs.jsonl`) exists for
debug ("which chat sent this?") and for the future GC pass (refs
empty + `last_seen` > 30 days → safe to delete). The MVP appends
refs but does not act on them.

This layout **replaces** PRD §F14's `uploads/<chat_id>/<file_name>`.
The `download_file` directive's output contract changes
correspondingly (see §3.4 below). The `uploads/` path is removed
without backward-compat — there are no production callers reading
the old shape; only `adapters/feishu/tests/test_download.py`
references it, which gets updated in PR-2.

### 3. Resolver + Phaser

#### 3.1 Layer split

```
URI ──Resolver──> Path ──Phaser──> {format consumer needs}
     (parse_resource + filesystem stat)
```

- **Resolver** (`Esr.Resource.Media.resolve/1`): URI → Path. Calls
  `Esr.Uri.parse_resource/1`, joins with `$ESRD_HOME/<env>/resources/
  <media_type>/<sha256>.<ext>`, validates env (rules below), stats
  the file (missing → `:not_found`).
  
  **Env validation:** an absent `<env>@` segment in the URI is
  interpreted as the local esrd's env (read once at boot from
  `$ESR_INSTANCE`). An explicit `<env>@` segment must match the
  local env exactly; mismatch → `:wrong_env`. Cross-env fetch is
  out of scope (see Non-goals); explicit mismatch is therefore an
  operator error, not a feature gap.
- **Phaser** (`Esr.Resource.<MediaType>Phaser`): Path → consumer
  format. Per media type. Knows extensions, MIME, format
  conversions.

Single-source URI parsing lives in `Esr.Uri`. Filesystem mapping
lives in `Esr.Resource.Media`. Format conversion lives in
`Esr.Resource.<Type>Phaser`. Three responsibilities, three modules.

#### 3.2 Resolver API

Elixir (`Esr.Resource.Media`):

```elixir
@spec resolve(String.t() | Esr.Uri.t()) :: 
        {:ok, Path.t()} 
        | {:error, :invalid_uri | :wrong_env | :not_found}

@spec store(media_type :: atom(), source_path :: Path.t(), 
            ref_meta :: map()) ::
        {:ok, %{uri: String.t(), sha256: String.t(), 
                path: Path.t()}}
        | {:error, term()}
```

Python (`esr.resource.media`): mirrored signatures, idiomatic raise
on error (`EsrResourceError`).

##### Concurrency / atomicity contract (per D3)

`store/3` is concurrent-safe **without locks**:

1. Compute SHA-256 by streaming `source_path`.
2. Determine target dir `<resources>/<media_type>/`. `mkdir -p` is
   idempotent.
3. Write bytes to `<resources>/<media_type>/.<sha>.<ext>.tmp`. Then
   `File.rename!` to `<sha>.<ext>` (POSIX atomic on same filesystem;
   `$ESRD_HOME/$ESR_INSTANCE/resources/` lives on the daemon's home
   FS by construction).
4. Append a single line of JSON to `<sha>.refs.jsonl`. POSIX
   guarantees concurrent appends ≤ PIPE_BUF (4096 bytes) atomic;
   each ref is well under that limit.
5. Skip `.meta.json` writes during normal operation. Boot-time
   `Esr.Resource.Media.RefIndex.scan/0` rebuilds `.meta.json` from
   `<sha>.refs.jsonl` (and from byte stat if no refs file exists —
   resource pre-population case). `.meta.json` is a derived cache,
   never the source of truth.

Concurrent `store/3` for the same SHA-256 thus has zero locks: step
3's rename collisions are no-ops (same-sha = same content; rename
into existing dest succeeds with the new bytes-identical file
landing); step 4's appends are independent and order-preserving in
the file.

Read path (`Esr.Resource.Media.RefIndex.refs_for/1`) reads the
on-boot ETS index (mirror of `.refs.jsonl`); ETS gets one append per
new ref, debounced through the same GenServer that watches
`.refs.jsonl` for FSEvents (or polled on each `store/3`).

#### 3.3 Phaser behaviour

Elixir behaviour `Esr.Resource.Media.Phaser`:

```elixir
@callback media_type() :: atom()
@callback input_formats() :: [atom()]
@callback output_formats() :: [atom()]
@callback streaming?() :: boolean()
@callback transform(input :: {atom(), term()}, target :: atom()) ::
            {:ok, term()} | {:error, term()}
```

MVP implementations:

```elixir
defmodule Esr.Resource.Media.ImagePhaser do
  @behaviour Esr.Resource.Media.Phaser
  def media_type, do: :image
  def input_formats, do: [:path]
  def output_formats, do: [:path, :base64_data_url, :bytes]
  def streaming?, do: false
  
  def transform({:path, p}, :path),            do: {:ok, p}
  def transform({:path, p}, :base64_data_url), do: read_and_b64(p)
  def transform({:path, p}, :bytes),           do: File.read(p)
end

defmodule Esr.Resource.Media.FilePhaser do
  # output_formats: [:path, :bytes, :inline_text]
  # :inline_text only for size < 100 KB and detectable text encoding
end
```

Audio Phaser is deferred to follow-up PR (out of scope).

#### 3.4 PhaserRegistry — dispatch by URI

```elixir
defmodule Esr.Resource.Media.PhaserRegistry do
  @phasers %{
    image: Esr.Resource.Media.ImagePhaser,
    file:  Esr.Resource.Media.FilePhaser
  }

  @spec transform(uri :: String.t(), target :: atom()) ::
          {:ok, term()} | {:error, term()}
  def transform(uri, target) do
    with {:ok, %{media_type: mt}} <- Esr.Uri.parse_resource(uri),
         {:ok, path}              <- Esr.Resource.Media.resolve(uri),
         phaser when not is_nil(phaser) <- Map.get(@phasers, mt) do
      phaser.transform({:path, path}, target)
    end
  end
end
```

Python mirror: `esr.resource.media.phaser_registry.transform(uri, target)`.

#### 3.5 input_formats limited to `:path`

User feedback (§3.4): `input_formats` is `[:path]` only. Resolver
always yields a Path; Phaser does not consume `:bytes` or `:url`
inputs. If a future Phaser needs other inputs (e.g. an in-memory
streaming source), `input_formats` extends additively.

### 4. Plugin capability declaration

#### 4.1 `manifest.yaml` `declares.media_types`

Hard-required for any plugin whose entities send or receive content.
No backward-compat — the loader rejects `manifest.yaml` lacking the
block.

```yaml
# runtime/lib/esr/plugins/feishu/manifest.yaml
declares:
  # ... existing entities / capabilities / slash_routes / startup ...
  media_types:
    inbound:  [text, image, file]      # MVP. audio added in follow-up PR.
    outbound: [text, image, file]
```

```yaml
# runtime/lib/esr/plugins/claude_code/manifest.yaml
declares:
  media_types:
    inbound:  [text, image, file]
    outbound: [text, image, file]
```

#### 4.2 `esr.toml` `[media_types]` cross-check

```toml
# adapters/feishu/esr.toml
[allowed_io]
# ... existing ...

[media_types]
inbound  = ["text", "image", "file"]
outbound = ["text", "image", "file"]
```

Cross-check test (`tests/integration/test_plugin_manifest_consistency.py`,
new): for each plugin with both files, assert
`manifest.yaml.declares.media_types.{inbound,outbound}` equals
`esr.toml.[media_types].{inbound,outbound}`. Fails CI on drift.

Two-source consistency check (not asymmetric — the equality is
strict): the Elixir manifest is the routing-layer authority ("what
does the platform trust this adapter to do"); the Python manifest
is the sidecar self-knowledge ("what does the runner actually
parse"). They must agree exactly; CI is the cheapest enforcer.

### 5. Routing-layer capability resolve (fail-fast)

When a peer is about to send `{msg_type: <kind>, content: <uri>}` to
a downstream peer, the routing layer (today: SessionRouter +
FeishuChatProxy + CcProxy) checks the downstream peer's plugin
manifest `inbound` list. Unsupported → drop the envelope, emit a
metric `esr.media_type_unsupported`, and (Feishu→cc direction only)
trigger a one-shot warning DM through the inbound adapter:

> 操作员发了 `<kind>` 类型消息，但当前 cc 不支持此类型消费 — 已忽略

The DM is throttled per `(sender_id, kind)` to prevent spam (1 per
10 minutes; reuses PR-21x `CapGuard` rate-limit primitive). Keying
by sender (not chat) so that in a group chat each sender gets at
least one feedback DM, rather than only the first to paste an
unsupported type.

## Inbound flow — Feishu to cc

```
①  Lark WS                                    ②  Phoenix Channel adapter:feishu/<instance_id>
   ↓                                              ↓
   feishu_adapter_runner (Python)            Esr.Entity.FeishuAppAdapter (Elixir)
   • parse P2ImMessageReceiveV1                  • lookup ChatScope by chat_id
   • dispatch by msg_type                        ↓
   • non-text: yield Event(args={             ③  Esr.Entity.FeishuChatProxy (per session)
     msg_id, file_key, file_name, msg_type})     • on non-text branch: invoke ④
                                                 ↓
                                              ④  Esr.Resource.Media.Inbound.handle/2 (new)
                                                 a) check downstream cc plugin manifest
                                                    inbound list — unsupported → fail-fast
                                                    + throttled DM
                                                 b) directive `download_file` to feishu
                                                    sidecar → bytes file at temp path
                                                 c) Esr.Resource.Media.store(media_type,
                                                    temp_path, ref_meta)
                                                    → {:ok, %{uri, sha256, path}}
                                                 d) rebuild envelope:
                                                    {msg_type, content: uri, meta: {...}}
                                                 e) forward to ⑤
                                                 ↓
                                              ⑤  Esr.Entity.CCProxy
                                                 • PubSub broadcast cli:channel/<sid>
                                                 ↓
                                              ⑥  EsrWeb.McpController SSE handler
                                                 • PhaserRegistry.transform(uri, :path)
                                                 • emit notifications/claude/channel:
                                                   content="[<media_type> attachment]"
                                                   meta={kind, path, chat_id, sender_id, ...}
                                                 ↓
                                              ⑦  Claude TUI
                                                 • sees meta.kind + meta.path
                                                 • uses Read tool → multimodal consume
```

### Channel meta shape (Phaser output for cc inbound)

```json
{
  "kind": "image",
  "path": "/Users/h2oslabs/.esrd/default/resources/image/3a4b...png",
  "chat_id": "oc_xxx",
  "sender_id": "ou_yyy",
  "msg_id": "om_zzz",
  "filename_orig": "screenshot.png",
  "size_bytes": "152034"
}
```

All keys match `[A-Za-z0-9_]+`; values are strings (the channel
flat-attribute discipline — `docs/notes/actor-topology-routing.md` §8).
The `path` is an absolute path on the esrd host's filesystem; the
Read tool resolves it directly. cc's plugin manifest declared
`inbound: [..., image, file, ...]` — without that, ⑤ → ⑥ never fires.

### Failure modes

| Where | What | Recovery |
|---|---|---|
| ②→③ | Session not yet routed | FeishuChatProxy buffers (existing path) |
| ④a | downstream cc declares no support for `<kind>` | Drop envelope + warning DM |
| ④b | Lark `file_key` 30-day expired | `download_file` returns `{ok: false, error: "expired"}`; envelope dropped + DM |
| ④c | Disk full | `Esr.Resource.Media.store` returns error; envelope dropped + log |
| ⑥ | cc not subscribed (claude not running) | SSE emit no-ops; bytes already at rest in `resources/` |

## Outbound flow — cc to Feishu

Per **D4**: the peer-level envelope is URI-shaped, but the existing
Elixir → Python sidecar α-wire (`{chat_id, file_name, content_b64,
sha256}`) is preserved. PR-3 is therefore Elixir-only — no Python
sidecar changes.

```
①  Claude TUI invokes send_file MCP tool
   args = {chat_id, file_path}                   # actual schema, no app_id
   ↓
②  EsrWeb.McpController POST handler
   • tools/call → {:tool_invoke, "send_file", args, ...}
   ↓
③  Esr.Entity.CCProxy (NEW outbound store-on-the-way-out)
   a) media_type = infer_from_extension(args.file_path)
      # png/jpg/jpeg/gif/webp/heic → :image
      # any other extension        → :file
      # no extension               → reject {ok: false, error: "no extension"}
   b) Esr.Resource.Media.store(media_type, args.file_path,
                         ref_meta={source_actor: cc, sid, ...})
      → {:ok, %{uri, sha256, path}}              # stored, content-addressed
   c) capability check — feishu plugin manifest declares
      outbound: [..., :image | :file] — unsupported → tool returns
      {ok: false, error: "feishu does not declare outbound <kind>"}
   d) build envelope {msg_type: "image" | "file", content: uri,
                      meta: {chat_id, sha256, original_filename}}
   e) forward to ④
   ↓
④  Esr.Entity.FeishuChatProxy outbound branch (MODIFIED)
   On non-text envelope:
     a) Esr.Resource.Media.resolve(envelope.content) → {:ok, Path}
     b) reuse existing read_file_for_send(Path) → {file_name, content_b64, sha256}
        (already exists at feishu_chat_proxy.ex:489 — no change)
     c) emit existing α-wire to Python sidecar:
        emit_to_feishu_app_proxy(%{
          "kind" => "send_file",
          "args" => %{
            "chat_id" => envelope.meta.chat_id,
            "file_name" => file_name,
            "content_b64" => content_b64,
            "sha256" => sha256
          }
        })
   ↓
⑤  feishu_adapter_runner Python sidecar (UNCHANGED)
   • Existing _send_file directive consumes
     {chat_id, file_name, content_b64, sha256}
   • lark_oapi POST im/v1/files multipart → file_key
   • lark_oapi im.v1.message.create with content=JSON({"image_key": file_key})
```

### Tool surface preserved

`send_file` MCP tool (`Esr.Plugins.ClaudeCode.Mcp.Tools`) keeps its
existing schema `{chat_id, file_path}` (verified at
`runtime/lib/esr/plugins/claude_code/mcp/tools.ex:67-87` —
`required: [chat_id, file_path]`, no `app_id`). Only the
implementation behind it changes. Claude TUI remains unaware of the
protocol shift.

### Why preserve the α-wire (D4 rationale, expanded)

`feishu_chat_proxy.ex:480-524` carries a deliberate comment from
T12-comms-3g: "Do the read + hash + encode at the Elixir boundary so
the Python adapter's contract stays uniform across all channel
adapters (only they know how to talk to their platform)." Switching
to URI-passed-to-sidecar would break this uniformity for marginal
gain (saves one base64 encode + one IPC trip; costs the symmetry
that lets every future channel adapter consume the same wire).

Outbound bytes still pass through `resources/<sha>` (stored at step
③b) — so dedup, refs[] tracking, and future GC apply equally to
inbound and outbound. The α-wire is preserved at the **Python
sidecar contract layer** only; the upstream peer-level envelope is
URI-shaped throughout.

### Failure modes

| Where | What | Recovery |
|---|---|---|
| ③a | unknown extension | tool returns `{ok: false, error: "no extension"}` |
| ③b | `args.file_path` unreadable / disk full | tool returns `{ok: false, error: "read_failed: ..."}` (existing path at `feishu_chat_proxy.ex:511-520`) |
| ③c | feishu doesn't declare outbound `<kind>` | tool returns `{ok: false, error: "..."}` |
| ④a | URI resolves but bytes have been GC'd between store and resolve | tool returns `{ok: false, error: "resource gone"}`; should not happen in MVP (no GC); log if it does |
| ⑤ | Lark file size limit (30 MB image / 50 MB file) | size check at ③b before store + caption in error message; sidecar enforces too on retry |
| ⑤ | Lark API auth / rate limit | Existing F15 retry + 30s timeout from PRD-04; tool returns error |

## PR slicing

All three PRs are implemented in this single working session. The
split is for atomic review + bisect, not phased delivery.

| PR | Title | LOC | Sections covered |
|---|---|---|---|
| PR-1 | Multimedia protocol scaffold: `resources` URI grammar + Resolver/Phaser modules + manifest media_types | ~700-800 | §1, §3, §4 |
| PR-2 | Inbound MVP: Feishu image + file → cc (replaces PRD §F14 download path) | ~600-700 | §5, Inbound flow, replaces `uploads/`→`resources/` |
| PR-3 | Outbound MVP: cc `send_file` → Feishu image + file (Elixir-only per D4) | ~200 | Outbound flow |

### Per-PR completion definition

| PR | Acceptance |
|---|---|
| PR-1 | `mix test` green; `pytest` green; new `tests/integration/test_plugin_manifest_consistency.py` green; no e2e change. **Atomic per D5**: the loader-rejection check + cc/feishu manifest `media_types:` blocks + adapter `esr.toml` `[media_types]` ship in one commit; no intermediate state where the loader rejects manifests that haven't been updated. |
| PR-2 | `mix test` + `pytest` green; new e2e scenario 19 (Feishu inbound multimedia) passes; manual: PNG dropped into Feishu chat reaches cc as a Read-able path |
| PR-3 | `mix test` + `pytest` green; new e2e scenario 20 (cc outbound multimedia) passes; manual: claude `send_file` produces a visible Lark message |

## File-level change inventory

| Path | New / Modify | PR | Notes |
|---|---|---|---|
| `runtime/lib/esr/uri.ex` | Modify | PR-1 | register `:resources`; add `parse_resource`/`build_resource`; fix `build_path/3` env kwarg |
| `runtime/test/esr/uri_test.exs` | Modify | PR-1 | round-trip tests for resources |
| `runtime/lib/esr/resource/media.ex` | New | PR-1 | `resolve/1`, `store/3` |
| `runtime/lib/esr/resource/media/phaser.ex` | New | PR-1 | behaviour |
| `runtime/lib/esr/resource/media/image_phaser.ex` | New | PR-1 | |
| `runtime/lib/esr/resource/media/file_phaser.ex` | New | PR-1 | |
| `runtime/lib/esr/resource/media/phaser_registry.ex` | New | PR-1 | |
| `runtime/lib/esr/resource/media/ref_index.ex` | New | PR-1 | ETS-backed; reads .meta.json on boot |
| `runtime/test/esr/resource/media/*_test.exs` | New | PR-1 | per-module unit tests |
| `py/src/esr/uri.py` | Modify | PR-1 | register `resources`; `parse_resource`/`build_resource` |
| `py/tests/test_uri.py` | Modify | PR-1 | mirror Elixir tests |
| `py/src/esr/resource/media/__init__.py` | New | PR-1 | `resolve`, `store` |
| `py/src/esr/resource/media/phaser_registry.py` | New | PR-1 | |
| `py/src/esr/resource/media/image_phaser.py` | New | PR-1 | |
| `py/src/esr/resource/media/file_phaser.py` | New | PR-1 | |
| `py/tests/test_resource_media.py` | New | PR-1 | |
| `runtime/lib/esr/plugins/feishu/manifest.yaml` | Modify | PR-1 | add `declares.media_types` |
| `runtime/lib/esr/plugins/claude_code/manifest.yaml` | Modify | PR-1 | add `declares.media_types` |
| `runtime/lib/esr/plugin/manifest.ex` | Modify | PR-1 | parse `declares.media_types` block; required for plugins that declare any content-bearing entity (Boundary / Stateful / Proxy with inbound/outbound role) |
| `runtime/lib/esr/plugin/loader.ex` | Modify | PR-1 | reject manifest without `media_types` at boot — fail-loud, not warn-and-default |
| `adapters/feishu/esr.toml` | Modify | PR-1 | add `[media_types]` |
| `tests/integration/test_plugin_manifest_consistency.py` | New | PR-1 | cross-check |
| `adapters/feishu/src/esr_feishu/parsers.py` | Modify | PR-2 | image/file parsers populate `args` consistently |
| `adapters/feishu/src/esr_feishu/adapter.py` | Modify | PR-2 | `download_file` directive returns `{uri, sha256, path}` (was `{path}`) |
| `adapters/feishu/tests/test_download.py` | Modify | PR-2 | new directive output shape |
| `runtime/lib/esr/resource/media/inbound.ex` | New | PR-2 | `handle/2` orchestration; capability check + download + store + rebuild envelope |
| `runtime/lib/esr/plugins/feishu/feishu_chat_proxy.ex` | Modify | PR-2 | non-text branch invokes `Esr.Resource.Media.Inbound.handle/2` |
| `runtime/lib/esr_web/mcp_controller.ex` | Modify | PR-2 | SSE notification carries `meta.kind` + `meta.path` for non-text |
| `tests/e2e/scenarios/19_feishu_inbound_multimedia.sh` | New | PR-2 | |
| `runtime/lib/esr/plugins/claude_code/cc_proxy.ex` | Modify | PR-3 | outbound store + envelope build |
| `runtime/lib/esr/plugins/claude_code/mcp/tools.ex` | Modify | PR-3 | `send_file` re-implemented atop protocol |
| `runtime/lib/esr/plugins/feishu/feishu_app_proxy.ex` | Modify | PR-3 | outbound non-text dispatch |
| `runtime/lib/esr/plugins/feishu/feishu_chat_proxy.ex` | Modify | PR-3 | non-text outbound branch: resolve URI → `read_file_for_send` (existing) → emit existing α-wire `send_file` directive |
| `tests/e2e/scenarios/20_cc_outbound_multimedia.sh` | New | PR-3 | |

**Per D4: no Python sidecar changes in PR-3.** The existing
`_send_file` directive is the unchanged contract; FCP keeps emitting
the same `{chat_id, file_name, content_b64, sha256}` shape. PR-3
LOC therefore lands closer to **~200 LOC** than the original 400-500
estimate.

## Testing strategy

### Unit (per PR)

- PR-1: `Esr.Uri.parse_resource/1` round-trip; `Esr.Resource.Media.store/3`
  with seed bytes (verify hash, file location, .meta.json contents);
  Phaser transforms across all output formats per Phaser; Python
  mirrors. Manifest cross-check on real plugin manifests.
- PR-2: Feishu sidecar `download_file` returns new shape;
  `Esr.Resource.Media.Inbound.handle/2` happy + sad paths
  (capability-miss, file_key-expired, disk-full);
  `EsrWeb.McpController` SSE meta-construction.
- PR-3: `Esr.Entity.CCProxy` outbound store + envelope building;
  `send_file` tool schema unchanged; FCP non-text branch resolves
  URI → existing `read_file_for_send` → existing `_send_file`
  α-wire to Python sidecar (sidecar untouched per D4); end-to-end
  with Lark mock.

### Integration (per PR)

- PR-1: Plugin manifest cross-check, run via `mix test` and
  `pytest`.
- PR-2: New `runtime/test/esr/integration/feishu_inbound_image_test.exs`
  using `mock_feishu` (per `docs/notes/mock-feishu-fidelity.md`).
- PR-3: New `runtime/test/esr/integration/cc_outbound_image_test.exs`.

### E2E (PR-2, PR-3)

- Scenario 19: operator drops a fixture PNG via mock-feishu inbound,
  asserts cc receives `<channel kind="image" path=...>` and the path
  exists + bytes match.
- Scenario 20: claude (mocked) invokes `send_file` with a fixture
  PNG; mock-feishu records the upload + send sequence; assert the
  posted message has `msg_type=image` and the file_key resolves to
  the original bytes.

Both scenarios update README.md "E2E test scenarios" table and
`docs/architecture.md` "E2E coverage map" per project convention.

## Open questions

1. **Lark `file_key` 30-day expiry on outbound**. The existing
   `_send_file` Python directive performs upload + `message.create`
   as a single sequence; orphan `file_key`s are an existing failure
   mode (predates this spec) and Lark cleans them up after 30 days.
   No new compensation in this spec; existing F15 retry covers most
   transient cases.
2. **MIME sniffing**. MVP trusts the original extension on inbound
   (Feishu adapter knows the type) and the path's extension on
   outbound (cc tool input). Magic-byte sniffing is a future
   hardening (e.g. reject `.png` extension whose bytes are
   actually a script).
3. **Multi-esrd resource sharing**. Two esrd instances on one host
   keep separate `~/.esrd/<env>/resources/` trees, even for the
   same SHA-256. Future GC pass may symlink-share via
   `~/.esrd/_shared/`. Not in scope.
4. **Path traversal hardening**. `Esr.Uri.parse_resource/1`
   validates `<sha256>` is exactly 64 lowercase-hex characters and
   `<ext>` is in an allowlist (`png|jpg|jpeg|gif|webp|heic|bin|
   pdf|doc|docx|...`). The resolved path is asserted to start with
   `$ESRD_HOME/$ESR_INSTANCE/resources/`. Both checks are pre-
   merge; failures raise `:invalid_uri`.

## Future work

The following land in `docs/futures/todo.md` after this spec ships:

- **Audio Phaser + Feishu audio inbound/outbound**. cc's Read tool
  does not consume audio bytes; an audio attachment surfaces as a
  path that claude can dispatch other tools against (e.g. Whisper
  transcription via a separate MCP tool). Single-PR additive.
- **Other Feishu media types**: video, post (rich text),
  interactive cards, sticker, share_chat, share_user, location.
  Each is one Phaser + one parser tweak.
- **Resource GC**. `Esr.Resource.Media.RefIndex.gc_loop/0` periodic task:
  for each `.meta.json` with `refs == [] and (now - last_seen) >
  30d`, delete the bytes + meta. Safe-by-design (refs[] is the
  single oracle for "still needed"). Configurable per-env.
- **Streaming Phasers**. Voice peer (PR-VV proposal) needs
  streaming audio in/out. `streaming?/0` callback already
  reserved.
- **Cross-host resource fetch**. `<env>@<host>` segment in URIs
  semantically supports cross-host but the resolver only handles
  local today. Future work: HTTP gateway in `EsrWeb.ResourceController`
  serving `resources/<media_type>/<sha256>` with a one-shot signed
  token; remote Phaser fetches over HTTP.
- **MIME sniffing (libmagic)** as a Resolver-time optional check
  for adapter inputs that don't already know the type.

## Migration & docs impact

| Doc | Change | PR |
|---|---|---|
| `docs/superpowers/prds/04-adapters.md` §F14 / §10.1 | Rewrite `download_file` directive output to `{uri, sha256, path}`; replace `uploads/<chat_id>/<file_name>` references with `resources/<media_type>/<sha256>.<ext>` | PR-2 |
| `docs/notes/esr-uri-grammar.md` | New row in "Registered types" table for `resources`; new builder example | PR-1 |
| `docs/notes/claude-code-channels-reference.md` | New section "Attachment notification shape: `meta.kind` + `meta.path`" | PR-2 |
| `docs/architecture.md` "Module tree" | New `Esr.Resource.*` subtree | PR-1 |
| `docs/architecture.md` "E2E coverage map" | Scenarios 19, 20 | PR-2, PR-3 |
| `README.md` "E2E test scenarios" | Scenarios 19, 20 | PR-2, PR-3 |
| `docs/futures/todo.md` | Remove "Feishu file / image / audio inbound" row (closed by PR-2 + PR-3 except audio); add "Audio Phaser", "Resource GC", "Other Feishu media types", "Streaming Phasers", "Cross-host resource fetch" rows | PR-1 |
| `docs/notes/multimedia-protocol.md` | New field-note with the protocol shape, Phaser-author guide, manifest cross-check workflow | PR-1 |

## See also

- `docs/superpowers/prds/04-adapters.md` §F14 / §10.1 — predecessor (gets rewritten)
- `docs/notes/esr-uri-grammar.md` — URI extension target
- `docs/notes/claude-code-channels-reference.md` — flat-attribute discipline
- `docs/notes/actor-topology-routing.md` §8 — channel attribute rules
- `docs/futures/todo.md` — multimedia inbound row (closed by this work)
- `docs/manual-checks/2026-05-08-post-multi-instance-audit.md` — surfaces the gap
- `runtime/lib/esr/uri.ex` + `py/src/esr/uri.py` — URI parsers (must stay in sync)
- `runtime/lib/esr_web/mcp_controller.ex` — current cc inbound exit point
