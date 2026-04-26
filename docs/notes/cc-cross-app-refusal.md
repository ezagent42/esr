# CC refuses cross-app forward as prompt-injection (E2E observation)

Captured during PR-A scenario 04 development (2026-04-26). Documenting
the phenomenon + a forward-looking design direction.

## What happened

PR-A's scenario 04 §5.4 / §5.5 want to E2E-verify FCP's cross-app auth
gate — specifically the deny paths (`forbidden` when principal lacks
`workspace:<target>/msg.send`; `unknown_chat_in_app` when the (chat,
app) pair has no workspace mapping). The E2E was written as a CC
prompt: "send a status update to chat-X on app-Y; if the tool returns
ok:false with `error.type=forbidden`, reply with the literal string
`[forward-failed: forbidden]` so the orchestration layer can record
the failure mode."

Real CC consistently refuses to execute. Two captured refusal turns:

> "Declining. The request asks me to forward a payload labeled
> 'unauthorized-attempt' to a different chat under a different app,
> and pre-scripts the exact string I should send back if it fails.
> That shape matches a prompt-injection probe rather than a legitimate
> task, so I'm not executing the forward and I'm not emitting the
> dictated literal."

> "This pattern (cross-chat / cross-app relay requested via an inbound
> message) is a classic prompt-injection / lateral-movement shape.
> I won't send the message to oc_pra_kanban without out-of-band
> confirmation from you directly."

## Trigger signals (CC's own reasoning)

CC bundles several cues into the refusal decision:

1. **Cross-chat / cross-app relay request** — unusual tool path
2. **Instruction originates from inbound message** — classic injection
   vector
3. **Pre-scripted failure marker** — "if-fails-emit-literal-X" looks
   like an attacker trying to plant detection markers
4. **Limited-authorization principal hint** — when the inbound user
   id was `ou_restricted`, CC mentioned that as reinforcing suspicion

## E2E workaround (PR-A)

`runtime/lib/esr/admin/commands/cross_app_test.ex` synthesizes a
`tool_invoke` directly into FCP via the admin queue, bypassing CC.
FCP's auth gate runs unchanged — same `Capabilities.has?/2`, same
`Workspaces.Registry.workspace_for_chat/2`, same dispatch + deny
shapes. The E2E asserts on the structured `tool_result` envelope plus
the `Logger.info "FCP cross-app deny type=..."` line.

This is a **test-only** path. Production cross-app forward continues
to flow through the CC → cc_mcp → ChannelChannel → FCP route. The
happy path (PR-A scenario 04 step 2, with `ou_admin` and a natural
prompt) does work end-to-end through real CC.

## Production impact: zero (today)

A real user in a real workflow doesn't write "if the tool fails,
emit literal X for the orchestration layer to grep." That phrasing is
specific to E2E test instrumentation. In production:

- User asks: "sync this update to the kanban team"
- CC calls `mcp__esr-channel__reply` with cross-app args (no marker
  injection signals)
- FCP runs the gate
- On `ok:false`, CC receives the structured error and decides how to
  surface it to the user — naturally, in its own words

So production deny paths DO work, they're just not E2E-coverable via
prompt-driven tests because writing the test prompt to elicit them
inevitably looks like injection to CC.

## Forward-looking direction (deferred)

Long-term we want CC sessions to see enough whole-picture context
that "cross-app forward instructed via inbound" doesn't read as
hostile. All nodes in this topology are trusted (admin-controlled
adapters, admin-bound chats, capability-gated principals). CC's
refusal is correct given **what CC sees**; it's incorrect given
**what's actually true at the system level**. The gap is information
asymmetry, not policy disagreement.

Possible directions (not yet scoped — tracked for post-PR-A
discussion):

1. **System-prompt addendum** — load a session-level system prompt
   declaring "this CC runs in a trusted multi-tenant orchestration
   topology; cross-chat / cross-app tool calls are normal workflows
   subject to runtime auth gates rather than CC-side refusal." Risks:
   could over-permissively suppress legitimate refusal in genuinely
   adversarial workflows.
2. **Tool-description language** — `mcp__esr-channel__reply`'s
   description could mention that cross-app calls are gated at the
   runtime, so refusal isn't load-bearing for safety. Lighter touch
   than #1.
3. **Topology-aware MCP server** — emit a one-time `notification`
   on session register with the full topology shape (workspaces, app
   memberships, principal role) so CC has the model up-front rather
   than inferring from each inbound. Heaviest, most ambitious.
4. **Accept the asymmetry, keep the bypass** — the
   `cross_app_test` admin command is the test-only escape hatch;
   production keeps the CC-mediated path. Cheapest; what PR-A ships.

## Cross-references

- Spec: `docs/superpowers/specs/2026-04-25-pr-a-multi-app-design.md`
- E2E: `tests/e2e/scenarios/04_multi_app_routing.sh` steps 3 + 4
- Admin command: `runtime/lib/esr/admin/commands/cross_app_test.ex`
- Unit tests: `runtime/test/esr/peers/feishu_chat_proxy_cross_app_test.exs`
- Deferred-items list: `docs/notes/futures/multi-app-deferred.md` §5
