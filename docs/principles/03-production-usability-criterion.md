# 03. Production usability of `esrd` is the primary selection criterion

## Statement

When choosing between multiple valid approaches for ESR work, pick
the one that moves `esrd` closer to real production use. Every other
consideration — spec alignment, LoC reduction, test coverage
numbers, stylistic preference — is secondary.

## Why

The project ships when a real user can DM the Feishu bot with
`/new-session --agent cc --dir /foo`, have `esrd` stand up the CC
session bound to that chat, and work with it. Decisions that look
"cleaner" but kick the production-readiness can down the road are
deprecated. Decisions that cost more effort now but directly unblock
a production flow are preferred.

## How to apply

- When presenting options to the user, lead with **production impact** per option, not just technical tradeoffs.
- If a shortcut would make a test green without advancing production-readiness, flag it explicitly so the user can choose knowingly.
- Refactors, simplifications, and cleanups are worthwhile — but when they compete with production-readiness work, production wins unless the cleanup directly unblocks it.
- When you don't have an obvious production-impact signal, default to the choice that exercises the most user-reachable code path.

## Concrete example (PR-7 → PR-8, 2026-04-23)

Three paths surfaced to unblock scenario 01's step 2 (post-session
chat-binding):

- **(a)** `session_new` accepts `chat_thread_key` args.
- **(b)** New `bind_session_to_chat` admin command.
- **(c)** Route `/new-session` via the Feishu slash path end-to-end (DM bot → FeishuAppAdapter → SlashHandler → session_new with chat_id implicit).

Paths (a) and (b) would make e2e green faster but represent a
test-specific API surface a production user would never hit. Path (c)
is medium-scope but exercises the real production flow: a Feishu user
types `/new-session` and `esrd` does the right thing end-to-end.

User's directive (direct Feishu quote, 2026-04-23):

> 路线c 我们需要实现整个业务拓扑，后续都以能不能帮助我们在生产中使用 esrd 作为选择标准

("Path c — we need to implement the full business topology; production
usability of `esrd` is the selection criterion going forward.")

PR-8's three tasks (T1 bootstrap SlashHandler, T2 thread chat_id
through Session.New, T3 integration test) were selected against this
criterion.

## Cross-refs

- Memory: `feedback_production_usability_is_selection_criterion.md`
