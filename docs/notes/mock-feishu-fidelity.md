# mock_feishu fidelity audit (2026-04-25)

> Pre-PR-A precondition: PR-A's multi-app E2E coverage is only as
> trustworthy as the mock that backs it. This note enumerates known
> gaps between `scripts/mock_feishu.py` and real Feishu / lark_oapi
> behaviour, sourced from:
>
>   * `adapters/feishu/tests/fixtures/live-capture/*.json` — three real
>     P2ImMessageReceiveV1 envelopes captured during live testing
>   * `cc-openclaw/channel_server/adapters/feishu/{adapter,parsers}.py`
>     — production-grade real-Feishu adapter the user's been talking
>     to me through, runs lark_oapi at scale
>   * `cc-openclaw/.claude/skills/feishu-{access,configure}` — DM /
>     group access policy semantics from the same production code
>   * `lark_oapi-1.5.3` SDK source under `py/.venv/.../lark_oapi`

The file lists are kept short on purpose so future audits stay grounded
in evidence — extend the list, don't rewrite from memory.

---

## 1. Inbound envelope shape — `push_inbound`

### Real (text_message.json captured 2026-04-19)

```json
{
  "schema": "2.0",
  "header": {
    "event_id": "55d7bc7de7f85a5d8dd9faec5e54e3ad",
    "token": "",
    "create_time": "1776615138517",
    "event_type": "im.message.receive_v1",
    "tenant_key": "16a9e2384317175f",       ← MISSING IN MOCK
    "app_id": "cli_a9564804f1789cc9"          ← real cli_xxx
  },
  "event": {
    "sender": {
      "sender_id": {
        "user_id": "788ce5f2",                ← MISSING IN MOCK (short id)
        "open_id": "ou_6b11faf8e93aedfb9d3857b9cc23b9e7",
        "union_id": "on_baeccd39496efa9fb65d65abe74f449b"  ← MISSING
      },
      "sender_type": "user",
      "tenant_key": "16a9e2384317175f"        ← MISSING
    },
    "message": {
      "message_id": "om_x100b517ba0ec58a0c422d8bec788fd2",
      "create_time": "1776615138225",
      "update_time": "1776615138225",          ← MISSING
      "chat_id": "oc_d9b47511b085e9d5b66c4595b3ef9bb9",
      "chat_type": "p2p",                       ← mock hardcoded "p2p"
      "message_type": "text",
      "content": "{\"text\":\"test1\"}",
      "user_agent": "Mozilla/5.0 (iPhone; ..."  ← MISSING
    }
  }
}
```

### Threaded reply (thread_reply.json) adds:

```json
"message": {
  ...
  "root_id":   "om_x100b517ba0ec58a0c422d8bec788fd2",   ← MISSING IN MOCK
  "parent_id": "om_x100b517ba0ec58a0c422d8bec788fd2"    ← MISSING
}
```

Without `root_id`/`parent_id`, the FCP T5c `un-react on reply`
mechanism in scenario 01 step 3 wouldn't work for thread-reply
inbounds (the inbound's message_id comes from the FORWARDED
`reply_to_message_id`, not the parent).

### Group chat (no live capture — **inferred from cc-openclaw + Feishu doc**):

```json
"message": {
  ...
  "chat_type": "group",                          ← mock can't emit
  "mentions": [{"key":"@_user_1","id":{"open_id":"ou_..."},"name":"小助手"}],
                                                  ← FULLY MISSING IN MOCK
  ...
}
```

**Impact**: PR-B (group-chat multi-bot routing) cannot be validated
against this mock without adding `mentions[]` + `chat_type: "group"`.

---

## 2. Inbound message_types — only `text` works

Real Feishu inbound message_types observed in cc-openclaw's
`parsers.py`:

| msg_type | Mock support | Notes |
|---|---|---|
| `text` | ✅ | only one mock emits |
| `post` | ❌ | rich-text with image_keys |
| `image` | ❌ | file_key reference, needs separate download |
| `file` | ❌ | file_key reference (different from outbound!) |
| `audio` | ❌ | file_key |
| `media` | ❌ | file_key |
| `merge_forward` | ❌ | requires `GET /im/v1/messages/{id}` to expand sub-messages |
| `interactive` | ❌ (mock receives, doesn't push) | card JSON |
| `sticker` | ❌ | sticker_key |
| `share_chat`, `share_user`, `location`, `todo`, `system`, `hongbao`, `vote`, `video_chat`, `share_calendar_event`, `folder` | ❌ | each has own content shape |

**Impact**: any agent that wants to support a non-text inbound has
zero mock coverage. For PR-A this is OK (cc agent + scenarios use
text inbounds only); for PR-B or future scenarios involving file
upload from user → CC, mock gaps will surface immediately.

---

## 3. Reaction events not pushed by mock

Real Feishu emits two event types we currently ignore:

- `im.message.reaction.created_v1` — fires for EVERY reaction on
  any message bot can see, including bot's own reactions
  (`operator_type=="app"`). cc-openclaw filters out bot-self
  reactions (`adapter.py:251-253`).
- `im.message.reaction.deleted_v1` — symmetric for un-reactions.

Mock only EXPOSES reactions via `GET /reactions` (a test
introspection endpoint) — it doesn't push events back to the WS
client when a reaction lands.

**Impact**: today FCP doesn't subscribe to reaction events, so this
gap is benign. If PR-D adds a "react-back to user reaction" feature
(e.g., user reacts ➕ → CC ack), mock can't drive it.

---

## 4. Outbound API — partially correct, missing auth

| Endpoint | Mock | Real semantics |
|---|---|---|
| `POST /open-apis/auth/v3/tenant_access_token/internal` | ❌ | mandatory before any other API call; live adapter fetches token + caches; mock is unauthenticated everywhere |
| `POST /open-apis/im/v1/messages` | ✅ shape ok | mock returns `{code:0, msg:"", data:{message_id,...}}` matching real |
| `POST /open-apis/im/v1/files` | ✅ basic | real requires multipart with `file_type` (file/image/audio/etc.); mock just hex-decodes blob into a file_key — works for round-trip but doesn't validate `file_type` enum |
| `POST /open-apis/im/v1/messages/{id}/reactions` | ✅ | real returns reaction_id |
| `DELETE /open-apis/im/v1/messages/{id}/reactions/{reaction_id}` | ✅ | match |
| `GET /open-apis/im/v1/messages/{id}` (fetch) | ❌ | needed by `merge_forward` parser |
| `GET /open-apis/im/v1/chats/{chat_id}/members` | ❌ | needed for "bot is member of chat" precheck |
| `POST /open-apis/im/v1/messages/{id}/edit` | ❌ | edit existing message — mock has no edit endpoint, but `cc_mcp` schema documents `edit_message_id` on `reply` tool |
| Rate limits | ❌ | real Feishu enforces per-app + per-bot QPS; FCP today has retry logic for `_is_rate_limited` checks (adapter.py:68) but mock never returns rate-limit errors |

**Impact for PR-A**:

- Cross-app forward authorization on REAL Feishu fails when app-B
  is not a member of target chat — **mock won't catch this**. PR-A
  e2e green ≠ prod ready. Spec must call this out + add a "live
  smoke" gate before merge.
- The `tenant_access_token` flow being mocked means the live
  adapter's token-refresh + retry path is untested in our pyramid;
  if cross-app introduces a new token-acquisition pattern, we won't
  see it until prod.

---

## 5. Bot / chat membership and group access policy

Real Feishu enforces (and cc-openclaw's `feishu-access` skill
encodes):

- **DM policy** — bot can be configured to accept DM only from
  paired/allowlisted users (`dmPolicy: "pairing"` or `"open"`)
- **Group policy** — `groups.<chat_id>.requireMention: true`
  means bot only sees messages where it's @-mentioned, even though
  it's a group member
- **Allowlist per group** — `groups.<chat_id>.allowFrom: [...]`
  whitelist of senders within a group
- **Mention pattern matching** — `mentionPatterns: ["小助手"]`,
  literal name matches as fallback for clients that don't always
  populate `mentions[]`

Mock has none of this. Every `push_inbound` is broadcast to every
WS client, regardless of "membership" or "mention".

**Impact for PR-B (group chat)**: huge. The group-chat scenario
ONLY makes sense if mock can simulate "bot-A sees the message,
bot-B doesn't" or "both see it but only bot-A was @-mentioned." Add
to mock as PR-B precondition.

**Impact for PR-A**: minimal — single-app DM-only scenarios bypass
this entirely.

---

## 6. Multi-app coexistence (the PR-A blocker)

Real Feishu:
- Each app has unique `app_id` (`cli_xxx`) + own bot identity (own
  `open_id` for the bot account in user view)
- A user DM-ing bot-A creates `chat_id` X with (user, bot-A)
- The same user DM-ing bot-B creates a DIFFERENT `chat_id` Y
- A group can host multiple bots, each from a different app
- An app can ONLY see messages from chats its bot is a member of
- An app can ONLY send to chats its bot is a member of (Feishu
  rejects with code≠0 otherwise)

Mock today:
- One `_ws_clients` list, one `_sent_messages` list, one
  `_reactions` list — global
- `push_inbound` broadcasts to all connected sidecars regardless of
  which app they represent
- `POST /open-apis/im/v1/messages` accepts any `receive_id`, no
  membership check

**For PR-A multi-app coexistence to be even partially testable**
mock needs:

- per-app namespace for `_ws_clients` + `_sent_messages` (key by
  `app_id`)
- `push_inbound(chat_id, app_id, ...)` to route only to the
  matching app's WS client
- on `POST /open-apis/im/v1/messages`, reject if `receive_id` was
  not previously paired with the calling `app_id` (look up
  `Authorization: Bearer <tenant_access_token>` to identify caller —
  or, simpler, accept `app_id` as a request header for tests)

This is ~80 lines of work. Worth doing as the FIRST commit of PR-A.

---

## 7. Identity-of-things: `app_id` in our env vs real

cc agent's `feishu_app_proxy` target is
`admin::feishu_app_adapter_${app_id}`. The `${app_id}` in this
string is the **ESR adapter instance_id** from `adapters.yaml`
(e.g. `feishu_app_e2e-mock`), NOT the real Feishu `cli_xxx`
app_id.

Today this works because there's a 1:1 mapping. With multi-app
PR-A, we need to disambiguate at the topology level whether
`${app_id}` means:

1. ESR instance_id (e.g. `feishu_dev`, `feishu_prod`)
2. Feishu app_id (`cli_a9564804f1789cc9`)

Mock fidelity isn't directly affected, but the test harness yaml
naming will be — pick one convention and stick to it. Recommend
ESR instance_id (matches existing adapters.yaml schema), with a
side-channel mapping to real `cli_xxx` for cases where the app
needs to act on real Feishu API.

---

## 8. Recommended remediation path

In order, smallest work to highest leverage:

| Item | Effort | Blocks |
|---|---|---|
| Add `tenant_key`, `update_time`, `user_agent` to mock inbound envelope; add full `sender_id` (user_id + open_id + union_id) | 30 min | nothing — backwards-compat fields, FCP ignores extras today, but writes correct data into envelopes that the live path produces |
| Add per-app namespacing (mock instance can host N apps; `push_inbound` routes by `app_id`) | 2 h | PR-A E2E |
| Add `mentions[]` + `chat_type: "group"` support to `push_inbound` + group access policy enforcement | 3 h | PR-B (group chat) |
| Add `tenant_access_token` flow (mock returns short-lived token, validates Authorization header on subsequent requests) | 2 h | live-parity confidence; not strictly required for E2E pass |
| Add reaction-event push (`im.message.reaction.created_v1` etc.) | 1 h | PR-D and any reaction-driven UX |
| Capture and ship a real group-chat envelope fixture (`adapters/feishu/tests/fixtures/live-capture/group_text_with_mention.json`) | manual via cc-openclaw | PR-B mock-shape correctness |

---

## 9. Sign-off criteria for "mock fidelity good enough for PR-A"

- [ ] Mock inbound envelope matches the captured `text_message.json`
  field-for-field (extras OK, missing fields not OK)
- [ ] Mock supports per-app namespacing on `_ws_clients` and
  `_sent_messages`
- [ ] Mock rejects outbound `POST /im/v1/messages` if calling app
  isn't a "member" of `receive_id` chat (membership = a
  registration step in test setup)
- [ ] Existing scenarios 01/02/03 still pass against the upgraded
  mock with the same expectations (= mock changes are additive,
  not breaking)
- [ ] `docs/notes/` has an updated entry describing the
  mock's new contract

For PR-B and beyond, raise the bar incrementally per row 3+ of §8.

---

## See also

- `adapters/feishu/tests/fixtures/live-capture/` — three real
  envelopes; if you change mock, diff against these
- `cc-openclaw/channel_server/adapters/feishu/` — production-grade
  real-Feishu adapter; reference implementation
- `cc-openclaw/.claude/skills/feishu-access/SKILL.md` — encodes the
  DM/group access policy semantics
- `py/.venv/.../lark_oapi/api/im/v1/` — SDK type definitions are
  the authoritative shape source when docs disagree
