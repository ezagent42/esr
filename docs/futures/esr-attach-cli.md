# Future: `esr attach <session_id>` CLI subcommand

**Status:** not started. Tracked here as a deferral so the workaround
in `docs/cookbook.md` §"Recipe: Attach to a CC session's tmux pane"
has a clear "first-class fix" pointer.

## Why this exists

Operators attaching to a live CC session today must run two commands:

```bash
tmux -S $ESRD_HOME/default/tmux.sock list-sessions
tmux -S $ESRD_HOME/default/tmux.sock attach -t esr_cc_<N>
```

That's two pieces of state to remember (socket path, session name) and
one piece of arithmetic (which `esr_cc_<N>` corresponds to which
`thread:<sid>`). It's a lookup-and-syntax burden every time.

The desired UX:

```bash
esr attach <session_id>
# or, with workspace + chat:
esr attach --workspace ws_dev --chat oc_<…>
```

## What ships v1

A thin Python wrapper that:

1. Calls `esr actors inspect thread:<session_id>` (already wired —
   `EsrWeb.CliChannel.dispatch("cli:actors/inspect", …)`) to read
   `{tmux_session_name, tmux_socket}` off the snapshot.
2. `os.execvp("tmux", ["tmux", "-S", socket, "attach", "-t", name])` —
   replace the Python process so Ctrl-b d behaves correctly and
   stdin/stdout pass through cleanly.
3. Friendly errors when the actor doesn't exist, isn't a `tmux_process`
   peer, or the socket file is gone (esrd was restarted but tmux died).

## Why deferred

`esr attach` is operator convenience. The current two-command path
works and is well-documented (cookbook + dev-guide). PR-H prioritised
config-correctness fixes (mix PATH, dev worktree auto-creation, tmux
socket isolation) that **prevent** broken deploys — that work directly
unblocked `esr-dev` install. `esr attach` is upgrade-grade UX that
can wait.

## Where the data lives

- Actor snapshot fields: `tmux_session_name`, `tmux_socket` are
  already exposed by `Esr.Peers.TmuxProcess.spawn_args/1`
  (runtime/lib/esr/peers/tmux_process.ex:109-113) → consumed by the
  PeerServer `describe/1` path → surfaced in
  `EsrWeb.CliChannel.dispatch("cli:actors/inspect", …)`.
- The CLI side is `py/src/esr/cli/actors.py` (existing
  `actors inspect` subcommand) — a new sibling subcommand `attach`
  would reuse the same lookup helper.

## Estimated scope

~30 LOC Python (one new click subcommand + execvp call) + 1 unit test
asserting the inspect-then-execvp wiring. No runtime / Elixir change.

## Related

- `docs/cookbook.md` §"Recipe: Attach to a CC session's tmux pane" —
  documents the manual workaround.
- `docs/dev-guide.md` §"Debugging" — lists current `esr` debug commands.
