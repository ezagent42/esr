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
| 7 | 2026-04-19 | 8c | submit-helpers-rewire | 4b18d7e | unit_tests | sha256:1e0e70a0f3952047 |
| 8 | 2026-04-19 | 8c | cli-channel | 4293729 | unit_tests | sha256:0a8b2515259a1be3 |
| 9 | 2026-04-19 | 8c | cli-actors-list | 44d5a43 | unit_tests | sha256:ee9172ef9e76b456 |
| 10 | 2026-04-19 | 8c | cli-deadletter-list | 63e440a | unit_tests | sha256:9712b2a36495842c |
