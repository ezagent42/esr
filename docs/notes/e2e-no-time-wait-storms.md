# Don't write e2e wait loops that storm TIME_WAIT

Captured 2026-04-26 after a workstation outage RCA. Read this before
adding any new e2e wait loop to `tests/e2e/scenarios/`.

## TL;DR

**Never use `for _ in $(seq 1 N); do curl ...; done`.** Each iteration
forks a fresh `curl` subprocess that opens a new TCP socket. macOS
keeps closed sockets in `TIME_WAIT` for 30s. A single failing wait
loop can produce 1,200 TIME_WAIT entries on `127.0.0.1`; six such
loops in one scenario produces 7,200; a dozen retries during
development can pile 30,000-50,000+. The 127.0.0.1 ephemeral port
pool tops out at ~16k usable ports, so the host's outbound
connections (curl, channel-server → Feishu, ssh, anything) start
failing with `[Errno 49] Can't assign requested address`.

**Use `wait_for_url_jq_match` from `common.sh` instead.** It calls
`tests/e2e/scenarios/_wait_url.py` which holds a single
`requests.Session()` open for the entire wait window. 1,200 polls
share **one** TCP socket → 1 TIME_WAIT total.

## How to write a wait loop

✅ DO:

```bash
wait_for_url_jq_match \
  "http://127.0.0.1:${MOCK_FEISHU_PORT}/sent_messages" \
  '.[] | select(.receive_id=="oc_x")' \
  >/dev/null || true

assert_mock_feishu_sent_includes "oc_x" "expected text"
```

The `|| true` is intentional: the helper exits non-zero on timeout,
but you almost always want the next assertion (`assert_*`) to be the
load-bearing failure-mode check, not the wait-loop exit code itself.
The assertion gives you a useful "X not found in Y" message;
`exit 1` from the helper just says "deadline".

🚫 DON'T:

```bash
# This is the shape that caused the workstation outage. Don't.
for _ in $(seq 1 1200); do
  if curl -sS "http://127.0.0.1:${MOCK_FEISHU_PORT}/sent_messages" \
       | jq -e '.[] | select(.receive_id=="oc_x")' >/dev/null; then
    break
  fi
  sleep 0.1
done
```

## When `for _ + curl` is OK

Only when the loop is short (≤ 50 iterations) AND wraps a different
kind of probe — e.g., `tmux has-session`, `esr actors list`. These
don't open per-iteration TCP connections to test infra. The only
thing that hurts is HTTP polling against `127.0.0.1:<port>`.

The `_start_one_mock` readiness probe (≤ 100 iter at 0.2s) is also
fine in scope: each readiness probe opens 1 socket, and the loop
exits as soon as the mock binds (typically < 1s of actual probing).
Bumping that to use the helper would be over-engineering.

## Filter syntax

The 2nd argument to `wait_for_url_jq_match` is a **`jq -e` filter**.
Same syntax as the inline `jq -e '...'` you'd otherwise use:

- Existence check: `'.[] | select(.foo=="bar")'`
- Compound condition: `'select(([.[] | select(.a=="x")] | length) >= 1
                       and ([.[] | select(.b=="y")] | length) >= 1)'`
- Substring match: `'.[] | select(.content | contains("ack"))'`

Helper exits 0 on first match, 1 on timeout. It writes the matched
JSON to stdout (so callers can capture it), but for most assertion
shapes you can `>/dev/null` and rely on the subsequent `assert_*`.

## Tuning iterations + sleep

Defaults are 1200 iterations × 100ms = 120s deadline. If your wait
needs more (e.g., parallel CC cold-start in scenario 02 takes up to
~3 min), pass explicit args:

```bash
wait_for_url_jq_match URL FILTER 1800 200  # 1800 × 200ms = 6 min
```

Don't go below 100ms sleep — you start spinning hot on the helper's
own request loop.

## Diagnostic recipe

If e2e is flaky on macOS and you suspect TIME_WAIT exhaustion:

```bash
# Total TIME_WAIT count
netstat -an | grep -c TIME_WAIT

# Top remote endpoints (usually mock_feishu ports if it's a leak)
netstat -an | awk '/TIME_WAIT/ {print $5}' | sort | uniq -c | sort -rn | head -20

# Before/after delta on a single scenario run
before=$(netstat -an | grep -c TIME_WAIT)
make e2e-04
after=$(netstat -an | grep -c TIME_WAIT)
echo "delta=$((after-before))"
```

Healthy delta after this fix: < 300 per scenario run. If you see
> 1,000, somebody added a `for _ + curl` loop somewhere — grep for
the pattern and convert.

## See also

- `tests/e2e/scenarios/_wait_url.py` — the helper implementation
- `tests/e2e/scenarios/common.sh:wait_for_url_jq_match` — shell wrapper
- Original RCA: commit `491f670` ("e2e: single-session HTTP poll —
  TIME_WAIT storm fix")
- Failure cascade: `docs/notes/futures/multi-app-deferred.md` §6
  documents the workstation-level effects (channel-server
  EADDRNOTAVAIL when reaching `open.feishu.cn`, e2e-04 unable to
  bind probe sockets, etc.) — all rooted in the same shell-curl
  pattern.
