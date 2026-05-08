# Refactor Lessons — large-scale module renames

**Date:** 2026-05-03
**Audience:** anyone doing a Session/Peer/Resource-style mass rename in ESR
**Status:** captured from R1 / R2 / R3 (post-metamodel rename, see `docs/notes/concept-rename-map.md`)

---

## 一、Why this exists

R1 (Session→Scope), R2 (Peer→Entity), R3 (Resource consolidation) each touched 80–150 files. R1 and R2 landed cleanly; R3 hit a bad alias-collapse cascade and had to be reverted mid-flight. This doc records what went right, what went wrong, and the playbook the next refactor batch should follow.

---

## 二、What worked

### 1. Long-first substitution order

When renaming `Esr.PeerSupervisor` and `Esr.Peer` in the same pass, run the longer pattern first. `Esr.Peer\b` matches `Esr.Peer` AND `Esr.Peer.Foo`, but my regex with `\b` does NOT match `Esr.PeerSupervisor` (`r` followed by `S` is no boundary). However if you accidentally drop `\b`, `Esr.Peer` → `Esr.Entity` would mangle `Esr.PeerSupervisor` into `Esr.EntitySupervisor` — usually wrong because the actual target is `Esr.Entity.Supervisor`.

**Rule:** always pair regex substitutions with `\b` word-boundary anchors, AND order them long-first.

### 2. Test pass-in-isolation criterion

After R1/R2/R3 landed, full-suite `mix test` showed extra failures vs. dev baseline. Running each suspected-regression test in isolation (`mix test path/to/test.exs`) revealed they passed cleanly — the failures were test-ordering flakes surfaced by the rename (test files renamed → ExUnit alphabetical ordering shifted → pre-existing leaks now collide).

**Rule:** before declaring a refactor PR broken, run the failing tests in isolation. A "pass in isolation, fail in full suite" failure is a pre-existing flake, not a refactor regression.

### 3. Pre-merge-dev gate as the green anchor

Scenario 06 + 07 + DOM dataset check is the canonical "still green" criterion (per `scripts/hooks/pre-merge-dev-gate.sh`). After R1, the gate caught nothing because R1 didn't touch the runtime path; after R2, it caught a daemon-state-file mismatch (see §三-2 below). The gate is the single authoritative check — if it passes, the refactor is safe to merge.

### 4. Stopping early on cascading damage

R3's alias-collapse pass induced 118 test failures (vs. R2's 12). The first instinct — "let me grep + fix each one" — would have taken 30+ min and was high-risk for missing edge cases. The right call (per the user 2026-05-03 14:18) was to **stop, brief the situation, and revert the bad pass, then redo cleanly**. This is a valuable instinct: when a refactor's failure count jumps order-of-magnitude, the issue is systemic, not point-fix territory.

**Rule:** if a refactor PR's failure count jumps >10× the baseline, stop and look for the systemic cause. Don't grind through point-fixes.

---

## 三、What went wrong

### 1. Alias-collapse pass over-collapsed

R1/R2 used a regex like:
```
perl -i -pe 's/^(\s*)alias Esr\.Scope\.\w+(?:\.\w+)*$/$1alias Esr.Scope/mg'
```
to collapse `alias Esr.Scope.Process` (and `alias Esr.Scope.Admin.Process`) into `alias Esr.Scope`. Code that used `Scope.Process.foo()` then resolves correctly via the `Scope` alias.

This **worked for R1/R2** because the collapsed-to top-level (`Esr.Scope`, `Esr.Entity`) matched the namespace primitive that the file's code referenced via the dotted form (`Scope.Process`, `Entity.Server`).

It **failed for R3** because original code used short names like `FileLoader`, `Grants`, `Bootstrap` that did NOT match the collapsed-to top level (`Capability`, `Permission`):

```elixir
# Before R3
alias Esr.Resource.Capability.Grants  # short name: Grants
Grants.load_snapshot(snapshot)

# After R3 substitution (correct)
alias Esr.Resource.Capability.Grants  # short name: Grants
Grants.load_snapshot(snapshot)

# After R3 alias collapse (WRONG)
alias Esr.Resource.Capability  # short name: Capability
Grants.load_snapshot(snapshot)  # ❌ Grants is undefined
```

**Rule:** alias-collapse is only safe when the collapsed-to short name matches the actual short names the file uses. For Scope/Entity primitives, the short name is the primitive itself. For Resource sub-types (Capability, Permission, Workspace), files use child short names (Grants, FileLoader, Watcher, Registry) that don't survive collapse. **Don't run alias-collapse for namespace-tier consolidations** (Phase 3-style); only for primitive-tier renames (Phase 1/2-style).

### 2. Daemon state files cache module names

Both R1 and R2 surfaced this: `~/.esrd-dev/default/{slash-routes,agents}.yaml` are runtime state files containing string module references (e.g., `command_module: "Esr.Admin.Commands.Session.End"`). They're written at boot from `runtime/priv/<file>.yaml` but persist across restarts.

After a rename, the in-repo `priv/` files are correct, but the user-state cached files are stale → daemon can't load them → `unknown_module` errors → cascading boot failures.

**Rule:** every rename PR must also patch user-state files in `~/.esrd-dev/<instance>/*.yaml` with the same `perl -i -pe` substitution, then **restart the daemon** so the new state loads. The pre-merge-dev gate runs AGAINST the live daemon, so without the daemon restart, gate criteria can't be tested.

### 3. Test file renames shift ExUnit ordering → flake amplification

R1 renamed `session_test.exs` → `scope_test.exs` etc. ExUnit runs tests in alphabetical filename order, so the rename shifted execution order. Previously-passing pre-existing test-ordering leaks (e.g., shared ETS state, registry pollution between tests) suddenly surfaced as failures.

**Rule:** test-suite "regressions" after a rename are usually pre-existing leaks that the rename merely made visible. **Always run failing tests in isolation before assuming they're real regressions.** Document confirmed flakes in `docs/operations/known-flakes.md` (or a similar tracker) so they don't burn time on future rename PRs.

---

## 四、The Playbook (for future rename PRs)

For a rename of shape `Esr.OldName*` → `Esr.NewName.*`:

### 4.1 Branch + grep baseline

```bash
git checkout -b refactor/r<N>-<old>-to-<new>
mkdir -p docs/refactor
( for term in 'Esr\.OldNameSub' 'Esr\.OldName\b' …; do
    count=$(grep -rn "$term" --include='*.ex' … | wc -l)
    echo "$term: $count hits"
  done ) > docs/refactor/r<N>-grep-pre.txt
```

### 4.2 Long-first substitution

```bash
order=(
  "Esr\\.OldNameLongerSuffix\\b|Esr.NewName.LongerSuffix"
  "Esr\\.OldNameShorterSuffix\\b|Esr.NewName.ShorterSuffix"
  "Esr\\.OldName\\b|Esr.NewName"   # last
)
for pair in "${order[@]}"; do
  old="${pair%|*}"; new="${pair#*|}"
  files=$(grep -rl "${old}" --include='*.ex' --include='*.exs' --include='*.yaml' --include='*.json' --include='*.sh' .)
  [ -n "$files" ] && echo "$files" | xargs perl -i -pe "s/${old}/${new}/g"
done
```

### 4.3 Skip alias-collapse for namespace-tier renames

If the rename is a **namespace consolidation** (Phase 3-style, e.g. `Esr.Resource.Capability.* → Esr.Resource.Capability.*`), DO NOT run an alias-collapse pass. The original aliases (now `alias Esr.Resource.Capability.<X>` after substitution) already provide working short names.

If the rename is a **primitive rename** (Phase 1/2-style, e.g. `Esr.Session* → Esr.Scope.*`), alias collapse IS safe — the primitive short name (`Scope`/`Entity`) matches every dotted reference (`Scope.Process`, `Entity.Server`).

### 4.4 Unprefixed identifier sweep

Do this sparingly. If a test file uses `OldName.foo()` (unprefixed), sweep with negative-lookbehind:
```
perl -i -pe 's/(?<![\w.])OldName\b/NewName/g'
```
Lookbehind `(?<![\w.])` ensures we don't double-substitute `Esr.OldName.foo` (already `Esr.NewName.foo` from step 2).

### 4.5 File moves

```bash
git mv runtime/lib/esr/old_name.ex runtime/lib/esr/new_name.ex
git mv runtime/lib/esr/old_name/ runtime/lib/esr/new_name/
git mv runtime/test/esr/old_name_test.exs runtime/test/esr/new_name_test.exs
# also for test sub-dirs
```

### 4.6 Compile + test

```bash
(cd runtime && mix compile --warnings-as-errors)
(cd runtime && mix test)
```

If `mix test` shows N failures vs the dev baseline:
- N - baseline = "extras introduced by this PR"
- For each "extra," run in isolation. If it passes alone, it's a pre-existing flake — note in PR description, don't fix.
- If it fails in isolation too, that's a real regression — investigate.

### 4.7 Daemon state file sweep

```bash
for f in /Users/h2oslabs/.esrd-dev/default/*.yaml /Users/h2oslabs/.esrd-prod/default/*.yaml; do
  if grep -l 'Esr\.OldName' "$f"; then
    perl -i -pe 's/\bEsr\.OldName/Esr.NewName/g' "$f"
    echo "patched: $f"
  fi
done
```

### 4.8 Daemon restart

```bash
launchctl unload /Users/h2oslabs/Library/LaunchAgents/com.ezagent.esrd-dev.plist
sleep 3
launchctl load /Users/h2oslabs/Library/LaunchAgents/com.ezagent.esrd-dev.plist
until curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:4001/sessions/probe/attach | grep -q 200; do sleep 1; done
```

### 4.9 e2e + DOM check

```bash
bash tests/e2e/scenarios/06_pty_attach.sh
bash tests/e2e/scenarios/07_pty_bidir.sh
# DOM check: see scripts/hooks/pre-merge-dev-gate.sh §2b for the canonical Chrome incantation
```

### 4.10 Open PR + admin merge

```bash
git push -u origin refactor/r<N>-...
gh pr create --base dev --title "refactor(r<N>): …" --body "…"
gh pr merge <num> --admin --squash --delete-branch
git checkout dev && git pull --ff-only
```

---

## 五、Bail-out criteria

Stop the rename PR and ask the user before grinding through fixes if any of these triggers fire:

| Trigger | Reason |
|---|---|
| `mix test` failures > 10× the baseline | Systemic damage (alias collapse, missed substitution batch); point-fixing won't recover |
| `mix compile` shows undefined-function errors in load-bearing modules | Module surface is broken; tests will cascade |
| Daemon won't start after restart with new build | Boot path uses a renamed-but-not-loaded module |
| User-state yaml unparseable after rename | A stringified module reference was missed; daemon can't bootstrap |

In all four cases, the **right move is "revert the bad pass + redo cleanly"** — not "grep and fix each error one by one."

This was the lesson from R3 (2026-05-03). The next rename batch should bail at the first sign of cascade.

---

## 六、E2E lessons (added 2026-05-04 post-R11)

### 6.1 Don't excuse missing rendering as "tooling limitation"

During R4-R11 every PR's gate ran `bash tests/e2e/scenarios/06_pty_attach.sh + 07_pty_bidir.sh + DOM dataset check (cols/rows ranges)`. All passed. After R11 the user asked "can you actually see Claude's reply on the attach page?" I tried `chrome --headless --screenshot` with `--virtual-time-budget=20000 --run-all-compositor-stages-before-draw`, got an empty xterm (21 KB PNG), and **rationalized it** as "headless Chrome can't wait for WS-streamed cc TUI" (referencing a baseline note from PR-22).

That rationalization was wrong. The user's correct response: **"if a real screenshot shows empty, it means the page didn't render — your timeout excuse is illogical."** When I switched to `agent-browser open <url>; agent-browser screenshot <file>` (the tool memory rule §K mandates for web/UI work), the screenshot captured Claude Code TUI cleanly: "Welcome back Allen", "Opus 4.7 (1M context)", "Listening for channel messages from: server:esr-channel", "Try refactor <filepath>", "INSERT" — full content rendered.

**Rule:** if a screenshot is empty, **the page is broken or the screenshot tool is wrong**. Don't use "headless can't wait" as an excuse. Try the documented agent-browser path FIRST, not as fallback.

### 6.2 Always use agent-browser for UI verification

Per memory rule (user-set 2026-05-02): "ALWAYS use agent-browser for web/UI work; launch headless Chrome from agent side BEFORE asking user to verify; never iterate via 'try it and tell me what you see'."

`agent-browser open <url>` keeps the page alive across calls and `agent-browser screenshot <file>` captures the **actual rendered DOM** (Playwright/CDP based) including content streamed in via WebSocket — exactly what `chrome --screenshot` cannot do.

I violated this rule throughout R1-R11 (used raw `chrome --screenshot` everywhere) and the gate hook still does. Both should switch to agent-browser.

### 6.3 The pre-merge-dev gate's content blindness

The current gate (`scripts/hooks/pre-merge-dev-gate.sh` step 2b) only checks `data-opened-cols` / `data-opened-rows` dataset attrs — these get populated by xterm.js `init()` immediately on page load, BEFORE any WS data arrives. So the gate confirms "xterm initialized to a sane size" but NOT "content actually streamed in."

This means a regression that breaks the WS PTY channel (e.g., a wire-protocol mismatch) would NOT trip the gate; only the e2e scenario 07 catches it. If e2e 07 also has a hole, the regression ships.

**Follow-up TODO** (added to `docs/futures/todo.md`): upgrade the gate to use `agent-browser` + content assertion (e.g., `screenshot → assert image contains "Claude Code"` via OCR, OR `agent-browser eval` to read xterm cell text). Until then, manual visual check via agent-browser is the only true content gate.

### 6.4 Daemon state file caching is real

R1-R3 each had a daemon-state-file step where `~/.esrd-dev/default/{slash-routes,agents,permissions_registry}.{yaml,json}` cached old module names and broke daemon boot until swept + restarted. R4-R11 internalized this — every R-batch's playbook included the sweep + restart step. **Skip at peril.**

---

## 七、Related docs

- `docs/notes/concept-rename-map.md` — the rename catalog (R1/R2/R3 plus future R4-R6)
- `docs/notes/concepts.md` — the metamodel that drove the rename
- `scripts/hooks/pre-merge-dev-gate.sh` — the gate enforcement script
- `docs/operations/known-flakes.md` — pre-existing test-ordering flakes (none formally listed yet — populate as we discover them)
