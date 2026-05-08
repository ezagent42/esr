---
name: pre-merge-dev-gate
enabled: true
event: bash
pattern: gh\s+pr\s+merge.*--base[=\s]+dev
action: warn
---

ℹ️ **`gh pr merge ... --base dev` triggers the local pre-merge gate** (`scripts/hooks/pre-merge-dev-gate.sh`).

Before this command actually runs, the gate will:
1. Run `tests/e2e/scenarios/06_pty_attach.sh` (HTML shell smoke)
2. Run `tests/e2e/scenarios/07_pty_bidir.sh` (Feishu→cc roundtrip)
3. Headless-Chrome /attach probe — checks xterm.js dataset cols/rows are within sane bounds

If anything fails, the merge is blocked with the failing log tail. esrd-dev must be running (port 4001) for steps 1–3 to work; if it's not, restart with `launchctl kickstart -k gui/$UID/com.ezagent.esrd-dev` first.

**Why dev specifically:** dev is what esrd-dev runs — a bad merge there breaks the running service immediately. The gate is the local discipline; GitHub branch protection is bypassed by `--admin` per project policy, so this is the only enforcement layer.
