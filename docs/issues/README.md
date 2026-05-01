# Issues

Decision-track records — one file per design question that has reached a closed
verdict (or is actively being decided).

## Why this exists

Pre-2026-05-01, decisions lived inside `docs/superpowers/specs/<date>-<topic>-design.md`
(the spec doc) and the conversation transcript that produced it. Both are the
right place for the long form, but neither lets a future operator answer "did
we ever decide X?" without reading 20-page docs in full.

This directory is the index. Each file is a TLDR-first record so a casual reader
gets the conclusion in 30 seconds and links into the spec / PRs / commits when
they need depth.

When a GitHub issues workflow is set up, these files map 1:1 to issues
(filename = issue number convention TBD).

## Filename convention

```
<NN>-<topic>.md           # open / in-progress
closed-<NN>-<topic>.md    # decided + implemented (or rejected with rationale)
```

Number `NN` is sequential by file creation; not tied to GitHub issue numbers
(yet). Two-digit padding (01..99) keeps file listings sorted.

## File structure

Every file starts with a `## TLDR` block in this exact shape:

```
## TLDR

- **Problem:** one-sentence statement of what was unclear / broken / decided.
- **Decision:** the verdict, in active voice ("we keep tmux", not "tmux was kept").
- **Why:** the load-bearing reason. Nothing else.
- **Where it landed:** PR# / commit / spec path. Or "rejected — not implemented".
```

Below that, free-form: discussion, alternatives considered, links to specs,
quotes from the conversation that drove the call.

## When to create one

- A non-trivial design decision (would surprise a future reader)
- A meaningful "we tried X and went back" moment
- A reliability / architecture question that can't be re-derived from the code

Don't create one for: typo fixes, mechanical refactors, routine bumps, anything
where the commit message + PR description already tells the whole story.
