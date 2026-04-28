# Future: switch the prod esrd to true Elixir prod mode

**Status:** not started. Filed against the dev/prod-isolation deploy
work so the "we'll do this when it matters" stays visible.

## Why this exists

The two LaunchAgent plists (`com.ezagent.esrd` and `com.ezagent.esrd-dev`)
both set `MIX_ENV=dev` today. The label "prod esrd" denotes which
**Feishu app** the runtime serves (`ESR 助手` vs `ESR 开发助手`), not
Elixir's compile-time mode.

Running both as `MIX_ENV=dev` is a deliberate choice for the current
team-of-two-on-one-mac setup:

* No real production traffic — internal dev +联调 only.
* Phoenix's `runtime.exs:31` SECRET_KEY_BASE guard fires only under
  `:prod`. We use Channels, not cookie sessions, so the secret has no
  business purpose; the guard is a Phoenix scaffold default that costs
  more friction than it adds safety.
* Dev mode interpreted execution (`mix phx.server`) ↔ prod mode
  release execution (`bin/esr start`) — the two paths have different
  ergonomics; the team is iterating on code and wants the dev path's
  fast-feedback loop.

## When to switch

Reasons that would force the move from `MIX_ENV=dev` to a real
`mix release` deploy:

1. **External users depend on prod uptime.** Hot code reload, log
   verbosity, and `:dev`-only dependency loading become liabilities
   once a third party starts opening tickets.
2. **Compliance / audit requirements.** SOC 2-style controls
   typically require pinned versions and reproducible deploys, which
   `mix release` provides and `mix phx.server` does not.
3. **Resource budget.** Prod mode strips Logger backends, compiles
   to BEAM AOT, and produces a self-contained release tree (~200MB)
   that doesn't need Elixir or Hex on the host.
4. **Multiple operators across machines.** Releases are mac-portable;
   `mix phx.server` requires the host to have the matching
   Elixir/OTP toolchain.

## What the migration touches

Concrete checklist when the day comes:

1. **`SECRET_KEY_BASE`** — generate via `mix phx.gen.secret`; store in
   `~/.esrd/.env.local` (0600). Matches the existing
   `FEISHU_APP_SECRET_*` convention from
   `docs/operations/dev-prod-isolation.md` §5.
2. **`scripts/esrd-launchd.sh`** — load `.env.local` before exec.
   `scripts/esrd.sh` already does this; the launchd variant must too.
3. **Plist** — flip `MIX_ENV=prod` (this commit's revert).
4. **Build path** — replace `mix phx.server` with `bin/esr start`
   produced by `mix release`. Bake the release into the plist's
   `Program` instead of cd-ing to `runtime/`.
5. **Compile-time config** — review `runtime/config/prod.exs` and
   `runtime/config/runtime.exs:`prod` block; ensure logger level,
   endpoint host/port, DNS cluster query are set correctly.
6. **Backup the dev path** — keep `MIX_ENV=dev` as the dev plist
   default so iteration speed isn't lost.

## What is NOT enough

Just flipping `MIX_ENV=prod` without addressing #1-#5 will hit the
same `SECRET_KEY_BASE` raise we hit on 2026-04-28 (PR-J context).
Don't shortcut.

## Estimated scope

Small in code, large in operational discipline:

* ~30 LOC across plist + launchd wrapper + .env.local docs.
* +1 step to the `dev-prod-isolation.md` install procedure (generate
  secret).
* Real-time validation: connect a real customer-shaped traffic
  pattern and observe latencies / mem usage in prod mode for a day
  before declaring the migration complete.

## Related

* `runtime/config/runtime.exs:30-34` — the SECRET_KEY_BASE guard.
* `scripts/esrd.sh:77` — the `cd runtime && mix phx.server` invocation
  pattern; releases replace this.
* `scripts/esrd-launchd.sh` — the launchd wrapper. PR-I (`cd runtime`)
  + PR-J (this MIX_ENV revert) both touched it.
* Phoenix release docs:
  https://hexdocs.pm/phoenix/releases.html
