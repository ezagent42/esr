# Future: package `esr` as a single-file binary on PATH

**Status:** not started. Tracked alongside `./esr.sh` (the interim
shell wrapper at the repo root) so the temporary nature of the
wrapper stays visible.

## Why this exists

The Python CLI in `py/src/esr/cli/` runs via:

```bash
uv run --project py esr <subcmd>      # full form — repo-cwd dependent
./esr.sh <subcmd>                     # PR-J wrapper — works from anywhere
```

Both still require `uv` on PATH and a Python 3.11+ runtime. Three
classes of friction follow:

1. **Onboarding** — every new operator installs `uv` + `python` even
   if they only care about ops (kickstart, log inspection, capability
   grants). The CLI is thin glue, but the install footprint isn't.
2. **PATH** — `./esr.sh` works only from a known absolute path. Real
   `esr` on PATH would let `esr status` run from anywhere without
   thinking about repo location.
3. **Reproducibility** — interpreted Python is sensitive to which
   Python is selected by `uv`. A binary pins both interpreter and
   dependency versions at build time.

## What ships v1

A single-file binary under `~/.local/bin/esr` (or wherever the
operator's PATH points), built reproducibly from the Python source.

Three viable build tools, in order of preference:

| Tool | Output | Cold start | Hex install |
|---|---|---|---|
| [`shiv`](https://github.com/linkedin/shiv) | `.pyz` (zipapp) — needs Python on host | ~50 ms | LinkedIn-tested |
| [`pex`](https://github.com/pex-tool/pex) | `.pex` — same as shiv but pip-aware | ~80 ms | Twitter-tested |
| [`PyInstaller`](https://pyinstaller.org/) | true single-file native binary | 200-500 ms | broadest |

`shiv` is the lowest-friction starting point because it produces a
~5MB zipapp that runs on any Python 3.11+ host without bundling the
interpreter. PyInstaller is the right answer if "no Python on host"
becomes a hard requirement.

## When it becomes worth doing

- Operators outside the original two-person team need to run `esr`
  on machines they don't fully control.
- A CI step needs to call `esr` (e.g. capability-drift detection)
  and shouldn't pay the `uv sync` cost on every run.
- The CLI surface stabilises (today subcommands are still moving —
  see `py/src/esr/cli/main.py` for the live list).

## What today's wrapper covers

`./esr.sh` (PR-J) handles the "operator wants to call esr from any
cwd" case as long as the repo is checked out and `uv` is installed.
That's enough for the dev/prod-isolation single-mac setup.

## Estimated scope

| Step | LOC / cost |
|---|---|
| Add `shiv` build target to `py/pyproject.toml` | ~10 |
| Build script `scripts/build-esr-binary.sh` | ~15 |
| CI hook to publish a release artifact | ~30 (GitHub Actions) |
| Install instructions in `docs/dev-guide.md` | ~5 |

Total ≈ 60 LOC + 1 release pipeline. ~2 hours including a clean test
on a fresh machine.

## Related

- `esr.sh` (repo root) — the interim wrapper this would replace.
- `py/pyproject.toml` — defines the `esr` entry point; build tools
  reuse the same metadata.
- `docs/dev-guide.md` §"Getting started" — quick-start currently
  references `uv run --project py esr ...`; would update post-binary.
