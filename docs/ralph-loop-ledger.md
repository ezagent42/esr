# Ralph Loop v2 Ledger

> Append-only evidence trail. Every iteration of the v2 loop appends a row.
> Editing or deleting rows fails LG-7; `evidence-type` must be one of the
> enum in spec §4.4.

| iter | date       | phase | FR     | commit  | evidence-type  | evidence-sha    |
|------|------------|-------|--------|---------|----------------|-----------------|
| 0    | 2026-04-20 | A17   | seed   | 200f8db | ledger_check   | sha256:00000000 |
| 1 | 2026-04-19 | 8a | F13-pusher | ee9af33 | unit_tests | sha256:7d44395e240f3ab3 |
| 2 | 2026-04-19 | 8a | F13-run-with-client | 99550df | unit_tests | sha256:92f760cecfd8b96d |
