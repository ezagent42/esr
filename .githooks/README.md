# Git hooks

Project-local git hooks, versioned in the repo so every dev gets the same behavior.

## One-time setup per clone

```bash
git config core.hooksPath .githooks
```

That's it. Unset with `git config --unset core.hooksPath` to revert to `.git/hooks/`.

## Hooks

### `post-merge` — refresh `.artifacts/` when main updates

Fires after `git merge` and `git pull` (which internally merges). When HEAD
ends up on `main`, runs
`.claude/skills/project-discussion-esr/scripts/refresh-index.sh --all --with-baseline`,
which rescans the module manifest **and** rebuilds
`.artifacts/bootstrap/test-baseline.json` by running the full test suite
via the `ezagent42/dev-loop-skills` plugin's `run-full-tests.sh`. This keeps
both the `project-discussion-esr` skill's module index and its "X passed"
numbers aligned with reality instead of drifting frozen at bootstrap time.

Expect this to take a few minutes — full test run touches runtime/ (mix
test), py/ (pytest), scripts/ (bash), adapters, and handlers.

**Silent no-op** when:

- HEAD is not on `main` (feature-branch merges don't trigger refresh)
- The skill isn't present in this checkout (e.g. an old branch)
- The `ezagent42/dev-loop-skills` plugin isn't installed locally

**Does NOT auto-commit.** If `.artifacts/` changed after refresh, the hook
prints a diff stat and the exact commit command — you decide whether and
when to commit.

**Does NOT fire on `git pull --rebase`.** Rebases trigger `post-rewrite`, not
`post-merge`. If your workflow uses rebase-pulls, run `refresh-index.sh`
manually, or add a `post-rewrite` hook with similar logic.
