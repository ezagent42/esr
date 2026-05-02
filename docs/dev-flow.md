# ESR git flow — feature → dev → main

**Filed**: 2026-04-30 (PR-21ζ)

## Invariant

`main` is never ahead of `dev`. Code reaches `main` only after `dev` (and the dev esrd it backs) has run with that code.

## Branches

- `main` — what prod esrd runs. Linear history. Updated only by `dev → main` fast-forward.
- `dev` — what dev esrd runs (`.worktrees/dev/` checks out this branch). Linear history. Each commit on `dev` corresponds to one merged feature PR.
- `feature/*` — short-lived branches. PRs target `dev`, never `main`.

## Flow

```
                 squash merge          fast-forward
feature/foo  ─────────────────►  dev  ────────────────►  main
                  (PR to dev)          (promotion PR)
```

### Feature PR (`feature/* → dev`)

- Open: `gh pr create --base dev --head feature/<name>`
- Merge: `gh pr merge <#> --squash --delete-branch` (admin OK; no required review at this layer)
- Result: dev advances by one commit; feature branch deleted

### Promotion PR (`dev → main`)

- Open: `bash scripts/promote-dev-to-main.sh` (auto-generates the PR description listing every commit on `dev` since `main`)
- Merge: **do NOT use `gh pr merge --rebase`** — that's a rebase merge which rewrites SHAs even when fast-forward is possible, causing dev and main to diverge by SHA. Instead, push `dev` directly to `main` (true fast-forward) and then close the PR with a comment.

```bash
# After PR opens (PR number $N):
( cd ~/Workspace/esr && git fetch origin && git push origin origin/dev:main )
gh pr close $N -c "Fast-forwarded via direct push (preserves SHAs across dev/main)."
```

- Result: main moves to dev's HEAD with **identical SHAs**; future promotions stay clean.

### Invariant enforcement

- **GitHub Action** `.github/workflows/enforce-pr-from-dev.yml` rejects any PR with `base=main` and `head ≠ dev`.
- **Branch protection on main**: requires PR + linear history + the enforce-pr-from-dev status check + restricts direct pushes.
- **Branch protection on dev** (lighter): requires PR + linear history. No required check at this layer.

## Worktree layout

```
~/Workspace/esr/                              ← primary worktree, branch: main
~/Workspace/esr/.worktrees/dev/        ← dev worktree, branch: dev
```

After a feature PR merges to dev, sync the dev worktree:

```bash
( cd ~/Workspace/esr/.worktrees/dev && git fetch origin && git pull --ff-only origin dev )
launchctl kickstart -k gui/$(id -u)/com.ezagent.esrd-dev
```

After a promotion PR merges to main, sync the primary worktree:

```bash
( cd ~/Workspace/esr && git fetch origin && git pull --ff-only origin main )
launchctl kickstart -k gui/$(id -u)/com.ezagent.esrd
```

## Hot-fixes

There is no fast-path. If prod breaks:

1. Open feature PR against `dev` as normal
2. Validate in dev esrd (5–10 min)
3. Open promotion PR `dev → main`
4. Merge

If prod is genuinely on fire and even 5 minutes is too long, an admin override (`gh pr merge --admin <#>` against `main`) is allowed but **must** be followed immediately by syncing dev to main's new HEAD (`git push origin main:refs/heads/dev` after fast-forward) so the invariant `main ≤ dev` holds again.

## Why this shape

- **No CI today** → can't gate promotions on a green build. The "validate in dev esrd" step replaces CI as the smoke test.
- **Squash for features** → dev history stays one-commit-per-PR, easy to read in `git log`.
- **FF for promotions** → main and dev have identical commit shape; `git blame` on main hits the original feature commit.
- **GHA enforcement** → the only client-side thing that survives `--no-verify` and worktree switches is GitHub-side check.
