# Tmux env propagation: client → pane is not automatic

## TL;DR

`tmux new-session …` does **not** pass arbitrary env vars from the tmux
*client* process to the pane's child command. Only a small whitelist
(`update-environment`: `DISPLAY`, `SSH_AUTH_SOCK`, …) survives.
**Pass per-session env explicitly via `-e VAR=VALUE` on `new-session`.**

## Repro

    env -i PATH=/usr/bin:/bin HOME=/tmp FOO=bar_from_client \
      tmux new-session -d -s probe 'sh -c "env > /tmp/out.txt"'
    # FOO not in /tmp/out.txt; HOME replaced with server's HOME

With `-e`:

    tmux new-session -d -s probe -e 'FOO=bar_from_client' \
      'sh -c "env > /tmp/out.txt"'
    # FOO=bar_from_client is in /tmp/out.txt

## How this bit us (PR-9 T12-comms-3)

`Esr.Peers.TmuxProcess.os_env/1` returned
`ESR_SESSION_ID` / `ESR_WORKSPACE` / `ESR_CHAT_IDS` / `ESR_ESRD_URL`.
erlexec applied them to the tmux client process's env. But tmux
silently dropped them before spawning the claude CLI in the pane —
`cc_mcp` (the MCP server claude forks) crashed on
`os.environ["ESR_SESSION_ID"]` KeyError at startup, leaving claude's
pane showing `server:esr-channel · no MCP server configured with that
name`.

Scenario 01 step 2 (`push_inbound` → expect "ack" reply) never saw a
reply.

## Fix

`runtime/lib/esr/peers/tmux_process.ex` `os_cmd/1` now interleaves `-e
VAR=VAL` flags between `new-session` and `-s`:

    ["tmux", "-C", "new-session",
     "-e", "ESR_SESSION_ID=…",
     "-e", "ESR_WORKSPACE=…",
     …
     "-s", session_name, "-c", dir,
     "<claude cmd as single shell-command positional>"]

Unit coverage: `runtime/test/esr/peers/tmux_process_test.exs` —
`"T12-comms-3: env flags appear BEFORE -s/-c and in pair shape \`-e
K=V\`"`.

## Why not `update-environment`?

`set-option -g update-environment 'ESR_*'` would work at tmux config
level but requires a server-wide global state mutation and doesn't
compose with our test-isolated sockets (`-S /tmp/…`). `-e` is
per-new-session, idempotent, and visible in the argv shape.

## See also

- `erlexec-migration.md` — why we spawn tmux via erlexec instead of
  `Port.open`
- `tmux-socket-isolation.md` — the `-S` override pattern used by the
  scenario harness
