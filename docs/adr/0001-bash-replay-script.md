# `scripts/replay-guide.sh` is a bash script, not a mix task

**Date:** 2026-05-10
**Status:** accepted

ESR's other tooling (`mix esr.gen_slash_routes`, `mix esr.check_bundles`, `mix esr.gen_command_docs`) is implemented as mix tasks because each one operates on ESR's **internal** code — parsing Elixir AST, reading manifest data structures, walking `Esr.Commands.Meta`. They live inside the same BEAM as the code they inspect.

`scripts/replay-guide.sh` (introduced for the guide-driven e2e spec, 2026-05-10) is fundamentally different. It is a **black-box driver**: it boots a fresh `esrd` as a subprocess, talks to it over HTTP via `mock_feishu`, and asserts the captured reply matches the guide's fence body. The replay tool must run **out-of-process** so the test fixture is genuinely isolated from the binary under test. Making it a mix task would nest "mix task → mix task → production binary," require booting OTP just to parse markdown, and conceptually conflate internal tooling with e2e drivers.

The rule: **internal tools that operate on ESR's code are mix tasks; out-of-process drivers that treat esrd as a remote service are bash scripts.** This ADR exists so that a future engineer who notices the odd-one-out shell script and wonders "why isn't this a mix task like everything else?" finds the answer in one grep of `docs/adr/`.

If fence-parsing logic ever grows beyond what bash + small Python heredocs can handle cleanly, supersede this ADR — don't silently rewrite.
