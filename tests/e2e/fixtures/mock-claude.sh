#!/usr/bin/env bash
# mock-claude.sh — synthetic claude binary for e2e scenario 17.
#
# Simulates the interactive I/O contract of the real `claude` binary:
#   - Accepts the same flags as the real binary (all silently ignored)
#   - Reads lines from stdin (PTY session input)
#   - For each non-empty line, emits a MOCK_REPLY that includes the
#     current HTTP_PROXY and ANTHROPIC_API_KEY env values so tests can
#     assert env propagation happened correctly.
#
# Output format (one line per input line):
#   MOCK_REPLY[proxy=<HTTP_PROXY|-NONE->, key=<ANTHROPIC_API_KEY|-NONE->]: <input>
#
# Side-channel file (for e2e assertion without PTY capture):
#   If ESR_MOCK_CLAUDE_DUMP_FILE is set, the process writes its env
#   snapshot to that path on startup. Scenario 17 sets this to a
#   per-run temp file and asserts its content after each agent restart.
#
# The mock exits cleanly when stdin closes (EOF) or receives SIGTERM.
#
# Note: all flags passed by Launcher.spawn_cmd/1
# (--permission-mode, --mcp-config, --dangerously-load-development-channels,
#  --add-dir, --settings) are silently ignored — accepted but not acted on.

set -euo pipefail

_proxy="${HTTP_PROXY:-${http_proxy:--NONE-}}"
_key_raw="${ANTHROPIC_API_KEY:-}"
if [[ -z "$_key_raw" ]]; then
  _key="-NONE-"
else
  # Mask the key after the first 4 chars for safety.
  _key="${_key_raw:0:4}***"
fi

# Write env snapshot to side-channel file if requested.
# Scenario 17 uses this to assert env propagation without PTY capture.
if [[ -n "${ESR_MOCK_CLAUDE_DUMP_FILE:-}" ]]; then
  printf 'proxy=%s\nkey=%s\n' "${_proxy}" "${_key}" > "${ESR_MOCK_CLAUDE_DUMP_FILE}"
fi

# Emit a startup banner so the test harness can confirm the process is live.
printf 'MOCK_CLAUDE_READY[proxy=%s, key=%s]\n' "${_proxy}" "${_key}"

# Read stdin line-by-line, echo a tagged reply for each non-empty line.
while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  printf 'MOCK_REPLY[proxy=%s, key=%s]: %s\n' "${_proxy}" "${_key}" "${line}"
done
