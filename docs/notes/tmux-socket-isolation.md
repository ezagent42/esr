# tmux socket isolation for integration tests

**Status**: fixed (follow-up to PR-4a snapshot §Known regression)
**Date**: 2026-04-23
**Branch**: `feature/peer-session-refactor`

## Problem

PR-4a integration tests (`cc_e2e_test`, `cc_voice_test`, `n2_tmux_test`,
`voice_e2e_test`) and related non-integration tests
(`session_router_test`, `admin/commands/session/end_test`) spawned real
`tmux -C new-session` children via `Esr.SessionRouter.create_session/1`.
All of those children ran under the user's **default tmux socket**
(`/tmp/tmux-<uid>/default`). Every test invocation left 1–N
`esr_cc_<unique>` sessions dangling there, polluting the developer's
live `tmux ls` and eventually exhausting the default socket's fds.

The PR-4a snapshot flagged the issue as "57 sessions leaked during this
run; manually cleaned post-merge" and deferred the fix to PR-5.

## Fix

1. **`Esr.Peers.TmuxProcess`** — state accepts an optional
   `:tmux_socket` field. `os_cmd/1` prepends `["-S", path]` when it is
   set, and `on_terminate/1` runs `tmux -S <path> kill-server` followed
   by `File.rm/1` so both the session and its socket file are cleaned
   up in one shot (simpler and more robust than per-session
   `kill-session`, which can race sub-shell children).

2. **`Esr.SessionRouter.spawn_args/2`** for `Esr.Peers.TmuxProcess`
   forwards `:tmux_socket` from the caller's params if present.
   Omitted in production → default socket (prod behaviour unchanged).

3. **`Esr.TestSupport.TmuxIsolation`** (new, `test/support/`) — exposes
   a shared `setup :isolated_tmux_socket` helper. Each test gets a
   unique `/tmp/esr-tmux-<N>.sock` path and a registered `on_exit`
   that defensively runs `tmux -S <sock> kill-server` + `File.rm`
   even if the peer chain never came up (catches mid-setup crashes).

4. **Tests updated** — every `SessionRouter.create_session/1` call in
   integration + router + session-end tests now threads
   `tmux_socket: tmux_sock` from the setup ctx into the params map.
   Test files touched:
   - `test/esr/integration/cc_e2e_test.exs`
   - `test/esr/integration/cc_voice_test.exs`
   - `test/esr/integration/n2_tmux_test.exs`
   - `test/esr/integration/voice_e2e_test.exs`
   - `test/esr/session_router_test.exs`
   - `test/esr/admin/commands/session/end_test.exs`

`test/esr/peers/tmux_process_test.exs` already had a local isolated
setup (predates the shared helper) and is unchanged.

## Verification

After the fix, five consecutive runs of
`mix test --include integration` produced **zero** `esr_*` sessions in
`tmux ls` output. Test count stayed at 398 (0 failures, 1 excluded).

The earlier observed intermittent leak (≤1 per ~6 runs) traces to the
macOS TTY-lifecycle flake documented in `cc_e2e_test.exs` drift notes:
`tmux -C new-session` exits its control-mode client almost immediately
without a controlling TTY, and if the OSProcessWorker crashes before
its `terminate/2` runs, `on_terminate` never fires. The
`isolated_tmux_socket` setup's defensive `on_exit` kill-server handles
that case by tearing down the whole isolated server regardless of peer
state.

## Production impact

None. `tmux_socket` is opt-in: prod callers never pass it, so
`os_cmd/1` omits `-S` and tmux uses its default socket exactly as
before.
