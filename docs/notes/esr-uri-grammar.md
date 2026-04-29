# `esr://` URI grammar — practical reference

**Date:** 2026-04-29.
**Reason this doc exists:** the URI mechanism existed since PR-A but
was only documented in module docstrings + `docs/superpowers/glossary.md:117`
(the canonical spec §7.5 reference). New contributors and AI pair-programmers
were re-inventing addressing schemes because the grammar wasn't surfaced
in `CLAUDE.md` "Things to look up". This note closes that gap.

If you're about to invent a new identifier shape for cross-process /
cross-boundary addressing — **stop and read this first**.

## TL;DR

esrd has one canonical addressing scheme: `esr://[org@]host[:port]/<segment>(/<segment>)*`.
Both Elixir and Python share parsers that agree on the wire shape.

| Layer | Module | Lines |
|---|---|---|
| Elixir parser/builder | `runtime/lib/esr/uri.ex` | full module |
| Elixir tests | `runtime/test/esr/uri_test.exs` | full file |
| Python parser/builder | `py/src/esr/uri.py` | full module |
| Python tests | `py/tests/test_uri.py` | full file |
| Spec reference | `docs/superpowers/glossary.md:117` ("esr:// URI" entry) | spec §7.5 |
| Reachable-set / topology | `runtime/lib/esr/topology.ex` | URI shapes §"URI shapes used here" |

## Grammar

```
esr://[org@]host[:port]/<segment>(/<segment>)*[?k=v&…]
```

Constraints:
- **Host is required** — empty host is `:empty_host` error. There's no
  `esr:///foo` shorthand.
- The first path segment names the **type**; valid types come from two
  fixed sets (see below).
- Subsequent segments are id components; their meaning depends on the type.
- Query params are parsed into a `%{String.t() => String.t()}` / `dict[str, str]`.

## Registered types

### Legacy 2-segment forms

Single `id` segment after the type:

| Type | Example | Used for |
|---|---|---|
| `actor` | `esr://localhost/actor/cc:sess-A` | actor identity in logs / cross-process refs |
| `adapter` | `esr://localhost/adapter/feishu` | legacy adapter id (mostly superseded by `adapters/`) |
| `handler` | `esr://localhost/handler/<name>` | handler routing |
| `command` | `esr://localhost/command/<name>` | command routing |
| `interface` | `esr://localhost/interface/<name>` | interface registry |

### Path-style RESTful forms (2026-04-27 onwards)

2+ id segments forming a hierarchical path:

| Type | Example | Used for |
|---|---|---|
| `adapters` | `esr://localhost/adapters/feishu/app_dev` | configured adapter instance (`{platform}/{instance_id}`) |
| `workspaces` | `esr://localhost/workspaces/ws_dev/chats/oc_xxx` | a chat scoped under a workspace |
| `chats` | (rarely top-level; usually nested under `workspaces/`) | chat addressing |
| `users` | `esr://localhost/users/ou_xxx` | user identity (today: feishu open_id; PR-21: switches to esr username) |
| `sessions` | `esr://localhost/sessions/sess_42` | a CC session (PR-21 extends with hierarchical `sessions/<user>/<workspace>/<name>`) |

The full registered set lives at `runtime/lib/esr/uri.ex:33-34` and
`py/src/esr/uri.py:31-34` — these two must stay in sync.

## Where URIs are built today

| Site | Shape | Builder call |
|---|---|---|
| `topology.ex:129` | `workspaces/{ws}/chats/{chat_id}` | `Esr.Uri.build_path/2` |
| `topology.ex:137` | `users/{open_id}` | `Esr.Uri.build_path/2` |
| `topology.ex:146` | `adapters/{platform}/{app_id}` | `Esr.Uri.build_path/2` |
| `peer_server.ex:683, 921` | `actor/{actor_id}` (legacy) | string interp |
| `feishu_app_adapter.ex:243, 252` | `admin/feishu_app_adapter_{instance_id}` (informational) | string interp |
| `handler_router.ex:43` | `runtime` (informational) | string literal |
| `runner_core.py:159` | source URI per spec §7.5 | `py/src/esr/uri.py` builder |
| `handler_worker.py:160-165` | `localhost/{topic}` (informational) | string interp |
| `channel_pusher.py:29` | `adapters/{platform}/{instance_id}` | comment-only |

The string-interp sites are informational/source-tagging only —
no parsing happens against them. The `Esr.Uri.build_path/2`-routed
emits are the load-bearing addresses (used in `reachable_set` for
ACL enforcement, etc.).

## Builders

### Elixir

```elixir
# Legacy 2-segment
Esr.Uri.build(:actor, "cc:sess-A", "localhost")
# → "esr://localhost/actor/cc:sess-A"

# Path-style
Esr.Uri.build_path(["adapters", "feishu", "app_dev"], "localhost")
# → "esr://localhost/adapters/feishu/app_dev"

Esr.Uri.build_path(["workspaces", "ws_dev", "chats", "oc_xxx"], "localhost")
# → "esr://localhost/workspaces/ws_dev/chats/oc_xxx"
```

**Known gap (2026-04-29):** Elixir `build/3` and `build_path/2` do not
accept an `org` parameter. The parser handles `org@host` correctly
(see `uri_test.exs:27`), but to *emit* `esr://default@localhost/...`
you currently have to interpolate manually. PR-21 (session URI redesign,
spec at `docs/superpowers/specs/2026-04-28-session-cwd-worktree-redesign.md`)
will be the first production user of `org@` and will extend the builder
signatures.

### Python

```python
from esr.uri import build, build_path

build("actor", "cc:sess-A", host="localhost")
# → "esr://localhost/actor/cc:sess-A"

build_path(["adapters", "feishu", "app_dev"], host="localhost")
# → "esr://localhost/adapters/feishu/app_dev"

# Python builders DO support org= already
build_path(["sessions", "linyilun"], host="localhost", org="default")
# → "esr://default@localhost/sessions/linyilun"
```

## Parsing

```elixir
{:ok, uri} = Esr.Uri.parse("esr://localhost/users/ou_xxx")
# uri.type     => :users
# uri.id       => "ou_xxx"
# uri.segments => ["users", "ou_xxx"]
# uri.host     => "localhost"
# uri.org      => nil
```

```python
from esr.uri import parse

uri = parse("esr://default@localhost/sessions/linyilun/esr-dev/foo")
# uri.type     == "sessions"
# uri.id       == "foo"          # last segment
# uri.segments == ("sessions", "linyilun", "esr-dev", "foo")
# uri.host     == "localhost"
# uri.org      == "default"
```

`type` (atom in Elixir, str in Python) and `id` (last segment) are
provided for legacy 2-segment readers. New code should read `segments`
(the full list).

## When to add a new path-style type

1. **First, ask: can an existing type carry the new shape?**
   Most "I want a new identifier" cases are sub-resources of `workspaces`,
   `adapters`, or `sessions`, and a longer path under one of those is the
   right answer (e.g. `workspaces/<ws>/jobs/<job_id>`).
2. **If a genuinely new top-level type is needed**, add it to BOTH
   `_PATH_STYLE_TYPES` in Python AND `@path_style_types` in Elixir.
   Ship the change in one commit — wire-shape divergence between the
   two parsers breaks IPC.
3. **Add a unit test** in both `runtime/test/esr/uri_test.exs` and
   `py/tests/test_uri.py` that round-trips `parse(build_path(…)) == …`.
4. **Update this doc** — append a row to "Registered types" and to
   "Where URIs are built today" if you ship a new emit site.

## Internal short forms

Inside a single PeerServer process, an actor can address its peer by a
short string like `cc:sess-A` — no `esr://` prefix. This is the carve-out
in spec §4.4 / §7.5: "cross-boundary references use the full `esr://`
form; intra-org references can use short strings." The boundary is the
PeerServer; anything that crosses IPC must be a full URI.

`docs/superpowers/glossary.md:113-117` is the canonical reference for
the carve-out language.

## Cross-references

- Spec: `docs/superpowers/glossary.md` §"esr:// URI"; spec §7.5; PRD 01-F17,
  PRD 02-F15, PRD 03-F12.
- Topology consumer: `runtime/lib/esr/topology.ex` (reachable_set
  construction; symmetric closure for cross-workspace neighbours).
- Reachable-set ACL: `runtime/lib/esr/peer_server.ex` (every outbound
  source URI checked against the peer's reachable_set).
