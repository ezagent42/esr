# Ralph Loop v2 Ledger

> Append-only evidence trail. Every iteration of the v2 loop appends a row.
> Editing or deleting rows fails LG-7; `evidence-type` must be one of the
> enum in spec §4.4.

| iter | date       | phase | FR     | commit  | evidence-type  | evidence-sha    |
|------|------------|-------|--------|---------|----------------|-----------------|
| 0    | 2026-04-20 | A17   | seed   | 200f8db | ledger_check   | sha256:00000000 |
