# Future: first-boot admin principal + CLI bind flow

**Status:** deferred; placeholder stub authored 2026-04-24.
**Related:** capabilities spec §9.1 (first-run bootstrap); PR-9 T11b
`.env.local` workaround (2026-04-24 user direction).

---

## What exists today (the `.env.local` workaround)

ESR's capabilities subsystem uses an env var `ESR_BOOTSTRAP_PRINCIPAL_ID`
to avoid default-denying everything on a fresh install. The operator sets
it to their IM user id (e.g. Feishu open_id), and on first esrd start
`Esr.Capabilities.Supervisor.maybe_bootstrap_file/1` writes a seed
`capabilities.yaml` granting that principal wildcard `["*"]`. See
`runtime/lib/esr/capabilities/supervisor.ex:37-58`.

Starting 2026-04-24, `.env.local` (gitignored, auto-sourced by
`scripts/esrd.sh`) is the supported place to set this — see
`.env.local.example`. Default shipped value during T11b is the project
lead's Feishu open_id so the dev environment "just works".

## Why this isn't good enough long-term

1. **IM id = identity coupling.** The admin's identity inside ESR is
   currently pinned to a specific IM user's open_id. If that user
   changes IM platform (Feishu → Slack), rotates accounts, or adds a
   second IM identity they want to bind to the same admin role, there's
   no clean re-binding path — they'd have to edit `capabilities.yaml`
   by hand.

2. **No clear "this is the admin" concept.** The env var pins a
   specific principal. But conceptually ESR's admin is a role (bound to
   the operator of that esrd instance), not a specific Feishu account.
   The env-var approach makes these indistinguishable.

3. **Multi-IM support gets awkward.** Once we add Slack/Discord/iMessage
   adapters, a user's "I'm the admin" assertion has to come from
   *somewhere* per adapter. Either (a) re-set the env var per adapter —
   fragile — or (b) have `capabilities.yaml` grow an explicit identity
   graph — ugly.

## Proposed future design

**First-boot auto-generation + explicit CLI bind:**

1. On first `esrd start` with no existing `capabilities.yaml`, esrd
   generates a random **admin principal id** (e.g. `admin_<ulid>`).
   Writes `capabilities.yaml` granting it `["*"]` and prints:

       esrd: generated admin principal admin_01HXYZ…
       esrd: bind an IM identity with:
             esr admin bind-principal admin_01HXYZ… --feishu=ou_…
             esr admin bind-principal admin_01HXYZ… --slack=U01…

2. `esr admin bind-principal <principal-id> --<adapter>=<identity>` adds
   a row to `capabilities.yaml`:

       principals:
         - id: admin_01HXYZ…
           kind: admin
           capabilities: ["*"]
           bindings:
             feishu: ou_6b11faf8e93aedfb9d3857b9cc23b9e7
             slack: U012345

3. Adapter Lane A (`_is_authorized`) resolves the incoming IM identity
   via `bindings` back to the principal id, then checks capabilities.
   One admin can have any number of IM identities; switching platforms
   is a single CLI call.

4. `ESR_BOOTSTRAP_PRINCIPAL_ID` env var stays supported as an explicit
   override for CI and for operators who want full-manual config — but
   becomes optional, not the default.

## Why deferred

- The .env.local workaround is **working right now** and unblocks all of
  T11b's e2e needs. No production incident demands the proper design.
- The right design touches `capabilities.yaml` schema, adapter Lane A
  resolution, and a new `esr admin` subcommand. Probably 2-3 days of
  work + migration story for existing installs. Not T11b scope.
- Shipping the workaround first lets us learn what actually hurts with
  env-var-pinned identity — maybe the friction is less than we fear.

## When to revisit

- Second IM adapter (Slack/Discord) lands and multi-identity binding
  starts being actively painful.
- Any production deployment outside the founding team, where the
  env-var-is-my-open-id coupling stops being acceptable.
- A security/rotation requirement forces us to have a separable admin
  role vs IM identity.

## Pointers

- Current workaround: `.env.local` + `scripts/esrd.sh`'s auto-source
- Bootstrap implementation: `runtime/lib/esr/capabilities/supervisor.ex:29-63`
- Channel-side default: `runtime/lib/esr_web/channel_channel.ex:52,79`
