# Ralph Loop v2 Ledger

> Append-only evidence trail. Every iteration of the v2 loop appends a row.
> Editing or deleting rows fails LG-7; `evidence-type` must be one of the
> enum in spec §4.4.

| iter | date       | phase | FR     | commit  | evidence-type  | evidence-sha    |
|------|------------|-------|--------|---------|----------------|-----------------|
| 0    | 2026-04-20 | A17   | seed   | 200f8db | ledger_check   | sha256:00000000 |
| 1 | 2026-04-19 | 8a | F13-pusher | ee9af33 | unit_tests | sha256:7d44395e240f3ab3 |
| 2 | 2026-04-19 | 8a | F13-run-with-client | 99550df | unit_tests | sha256:92f760cecfd8b96d |
| 3 | 2026-04-19 | 8a | F13-adapter-loader | 6b55d14 | unit_tests | sha256:6b4505ef2ae3e602 |
| 4 | 2026-04-19 | 8a | F07-handler-worker-run | 9fe7925 | unit_tests | sha256:66a080f717fd5e5f |
| 5 | 2026-04-19 | 8a | F04-channel-call | 04e4789 | unit_tests | sha256:b063d4b65397eaa2 |
| 6 | 2026-04-19 | 8c | runtime-bridge-call | f92a012 | unit_tests | sha256:9f6b7a11b0b71064 |
