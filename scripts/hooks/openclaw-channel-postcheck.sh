#!/usr/bin/env bash
# scripts/hooks/openclaw-channel-postcheck.sh — Claude Code PostToolUse
# hook fired AFTER `mcp__openclaw-channel__*` tools (Feishu reply / file
# send / etc.) return.
#
# Wired in `.claude/settings.json` as a PostToolUse hook. Reads the
# tool-call JSON on stdin; if the tool is an openclaw-channel call,
# emits a stdout reminder that becomes context for the next agent turn,
# forcing a self-check: was that Feishu message a stopping point or
# just progress? Continue accordingly; if stopping, tell the user
# WHY and WHAT YOU WANT FROM THEM.
#
# Set 2026-05-05 per user direction:
# > 在调用 openclaw-channel 之后，自动 hook 触发自检：我是否应该
# > 继续工作，还是确实有必要等待用户反馈。如果通知仅仅是进度更新，
# > 不应停下来；如果真的有必要停下来，请明确告知用户为什么停下来了、
# > 希望用户做什么。
#
# Why this lives in settings.json (not the hookify skill): hookify's
# rule events (bash/file/stop/prompt) don't include PostToolUse on
# specific MCP tools. This hook captures exactly the surface needed.
# A `.claude/hookify.openclaw-channel-postcheck.local.md` doc-only
# placeholder records the intent for repo grep-ability.
#
# Exit codes (per Claude Code hook protocol):
#   0  - default; stdout becomes context for next turn
#   2  - block (we never block here; this is advisory only)
#
# Fast-path on irrelevant tools (<10ms typical).

set -uo pipefail

INPUT="$(cat)"
TOOL_NAME=$(echo "$INPUT" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("tool_name",""))' 2>/dev/null || true)

# Only fire on openclaw-channel tools. Match prefix; covers reply,
# send_file, react, kill_session, spawn_session, etc.
case "$TOOL_NAME" in
  mcp__openclaw-channel__*) ;;
  *) exit 0 ;;
esac

# Emit a system-reminder that becomes context on the next agent turn.
# Wrapped in <system-reminder> so the agent treats it as authoritative
# (matches the convention used by other Claude Code hook reminders).
cat <<'EOF'
<system-reminder>
You just sent a message via openclaw-channel.

**Self-check before stopping**:

1. **Was the message a progress update?** If you reported "did X,
   working on Y next" or similar — DO NOT stop. Continue with the
   next task. The user reads Feishu but expects you to keep working
   unless told otherwise.

2. **Is there a genuine reason to wait for user input?** Only stop if:
   - You hit a forking decision the user must weigh in on
   - You completed a logical milestone and need their direction
   - A blocker requires human action (creds, external system, etc.)

3. **If you do stop**, the message you sent must explicitly include:
   - **Why** you stopped (logical milestone / waiting on input / blocker)
   - **What** you want the user to do (review X / decide Y / unblock Z)

   If your message lacks both, send another reply NOW that adds them
   before going idle. Do not leave the user guessing about your state.

Memory rules in play: `feedback_explicit_stop_signal_after_feishu`,
`feedback_always_use_reply`, `feedback_wake_but_dont_stop`.
</system-reminder>
EOF

exit 0
