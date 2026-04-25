# Testing-pyramid lessons from the PR-9 T12-comms E2E debug chain

**Context:** PR-9's scenario 01/02/03 — first time the full Feishu → ESR
→ claude-in-tmux → cc_mcp → reply loop ran end-to-end. Before the live
run the code base had 488 passing unit tests. The live run surfaced 8
distinct bugs that took 18 commits to fix.

This note captures which bugs belonged at which layer of the test
pyramid, and the engineering practice we should have followed from the
start.

## The 18-commit retrospective

### A. Only E2E can catch these (timing / OTP lifecycle)

| Bug | Why only E2E | Commit |
|---|---|---|
| `CCProcess.send_input` broadcast fired ~10 s before cc_mcp joined `cli:channel/<sid>`; Phoenix.PubSub dropped it on 0 subscribers | Requires two live processes booting with different warm-up times and a concurrent message arriving | fd025d0 |
| `OSProcessWorker` didn't `Process.flag(:trap_exit, true)`, so supervisor `:shutdown` killed it directly and `terminate/2` (which invokes `on_terminate`) never ran — tmux session orphaned | OTP supervisor-termination semantics; unit tests stop GenServers with explicit `:stop` which runs `terminate` regardless | 9254d94 |

### B. Contract tests at module boundaries would have caught these

| Bug | Missing test | Commit |
|---|---|---|
| `ESR_ESRD_URL` set to fully-qualified Phoenix URL; cc_mcp appended path again → `vsn=2.0.0/channel/socket/...` → Phoenix rejected | `adapters/cc_mcp/tests/test_url_resolution.py` documented the base-URL contract, but the ESR side (TmuxProcess.channel_ws_url/0) had no test verifying it matched | a4e4a54 |
| FCP forwarded `send_file` with `{chat_id, file_path}`; feishu adapter's `_send_file` expected `{chat_id, file_name, content_b64, sha256}` | No cross-module contract test between FCP's `dispatch_tool_invoke("send_file", …)` and `esr_feishu.adapter._send_file` | 485ca32 |
| `chat_id` dropped from FCP meta → `<channel>` tag had empty `chat_id` → claude refused to call `reply` tool | No test asserting the FCP→CCProcess meta shape matches what `build_channel_notification` consumes | 53408b2 |

### C. Integration tests (real tool in isolation) should cover these

| Bug | What the test would look like | Commit |
|---|---|---|
| Tmux's `update-environment` whitelist silently dropped `ESR_*` vars between client and pane | `env -i ESR_X=y tmux -S /tmp/s new-session 'env'` and grep for ESR_X — ~15 lines, real tmux, no ESR code | f7c5446 |
| CLI's `discover_runtime_url` fell through to localhost:4001 even when `$ESRD_HOME/$ESR_INSTANCE/esrd.port` existed | Stub the port file, call `discover_runtime_url()`, assert URL uses the port | 6911c5c |

### D. Scenario drift (not bugs — stale tests)

| Symptom | Cause | Commits |
|---|---|---|
| `cc:single` / `cc:alpha` / `cc:tmux` actor names no longer exist | Pre-T11b naming; current model uses `thread:<session_id>` | 1c08b93, e66fba2, 983ea8a |
| `esr cmd run "/..."` resolves `.compiled/<name>.yaml`, not slash commands | T11b moved session lifecycle under admin queue | e14c444 |
| Scenario expected live reaction count=1 after reply; FCP now un-reacts on reply by design | Production flow changed, scenario didn't | e8f16b0 |

## Recommended practice (ordered)

### 1. Walking-skeleton first

The first commit on any new topology should be "narrowest E2E passes
with everything mocked." Add real components one at a time; the
walking-skeleton E2E must stay green at every step. **Do not let 13
sub-tasks accumulate before the first live run** — bug interactions
compound non-linearly.

In PR-9 we had 13 tasks (T11b.0 … T11b.8 + T12a/b/c) merged before the
first live scenario attempt. Each fix above was straightforward in
isolation; finding them all at once was not.

### 2. Contract test at every cross-process / cross-language boundary

For every `{Elixir_module}` ↔ `{Python_module}` or `{Elixir}` ↔ `{CLI
tool invocation}` pair, write a test that asserts:

  - the exact shape of the payload sent
  - the exact shape expected by the receiver
  - AND at least one round-trip using the real wire format

Category-B bugs would have failed these tests at write-time.

Concrete anchors to keep this honest:

  - `runtime/lib/esr/peers/feishu_chat_proxy.ex:dispatch_tool_invoke/5` ↔
    `adapters/feishu/src/esr_feishu/adapter.py:on_directive/2` — one
    test per tool kind (`reply`, `react`, `send_file`, `un_react`)
  - `runtime/lib/esr/peers/cc_process.ex:build_channel_notification/2` ↔
    `adapters/cc_mcp/src/esr_cc_mcp/channel.py:_handle_inbound` — one
    test asserting the notification keys claude's channels listener
    needs (`chat_id`, `message_id`, `user`, `content`)

### 3. "Hard to unit test" is a signal, not a license to skip

If a behaviour needs two processes to observe, spin up two processes
in a test (possibly with :test lane shortcuts — fake erlexec, fake
Phoenix PubSub, etc.). Do not defer that behaviour to E2E. Most of
our category-A bugs still have an intermediate-level test that would
have caught them:

  - PubSub race → a test that spawns CCProcess + delays cli:channel
    join by 100 ms, asserts the `send_input` arrives after join
  - trap_exit → `DynamicSupervisor.terminate_child` in a test and
    assert `on_terminate` was called

These landed as unit tests as part of the fix; they should have
existed before the fix.

### 4. Every live-surfaced bug earns a regression test before the fix

Memory already carries this rule (`feedback_e2e_failure_earns_unit_test.md`).
Follow it *before* the fix, not after — the red test is the proof that
the fix works, and it protects the invariant for future refactors. PR-9
T12 did this for ~6 of the 8 bugs; do 8/8 next time.

### 5. Scenarios own a refactor cycle when the architecture shifts

When a major change lands (PR-9's T11b pipeline rewrite), scenarios
get a synchronised update, not a deferred one. The stale actor naming
and slash-command paths in 01/02/03 would have been easy to fix
alongside T11b; by the time they surfaced 2 weeks later, the original
context was gone and each scenario needed a careful re-read.

## Meta observation

E2E is a **terminal safety net**, not a source of truth. When E2E is
the first time a new integration runs, every issue surfaces as a
bundle and each debug cycle pays the full boot-claude-tmux cost. The
goal is: by the time you run E2E, most bugs have already been caught
cheaper.

In this round, E2E paid for itself — it caught two genuine
architecture bugs (pubsub race, trap_exit) that no reasonable test
pyramid could have predicted. That is what E2E is for. It should not
have also been the discovery point for the six bugs below it.
