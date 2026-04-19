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
| 11 | 2026-04-19 | 8c | cli-deadletter-flush | 32bfcd6 | unit_tests | sha256:81023d7774fe4c06 |
| 12 | 2026-04-19 | 8c | cli-trace | 0e7aa1e | unit_tests | sha256:20406a7ab398c554 |
| 13 | 2026-04-19 | 8c | cli-actors-inspect | 66cd979 | unit_tests | sha256:c282a718d28fd6b3 |
| 14 | 2026-04-19 | 8c | cli-debug-pause-resume | 80e8a70 | unit_tests | sha256:29b5e62ad8635e0a |
| 15 | 2026-04-19 | 8c | cli-drain | fbc269b | unit_tests | sha256:92e8e24e7e57607f |
| 16 | 2026-04-19 | 8c | cli-stop-name | c00aa29 | unit_tests | sha256:dfc30744dc472dcc |
| 17 | 2026-04-19 | 8c | cli-run-name | 427ba9e | unit_tests | sha256:77f677782894a6d7 |
| 18 | 2026-04-19 | 8c | cli-actors-tree | 5b57d5a | unit_tests | sha256:d54b9935f94020f1 |
| 19 | 2026-04-19 | 8c | review-C1-C2 | 0b436e5 | unit_tests | sha256:fdbfc32b1cb52f11 |
| 20 | 2026-04-19 | 8c | review-C1-regression-test | ebbc5e3 | unit_tests | sha256:977c8a3d44955cf1 |
| 21 | 2026-04-19 | 8b | esrd-sh | d175c42 | unit_tests | sha256:a911e3d9de713eec |
| 22 | 2026-04-19 | 8d | mock-feishu-http | 3700cdf | unit_tests | sha256:ad91848f3219c3e2 |
| 23 | 2026-04-19 | 8d | mock-feishu-ws | 592fde3 | unit_tests | sha256:93a9390f9b3a0fa5 |
| 24 | 2026-04-19 | 8d | mock-cc | 47fcab9 | unit_tests | sha256:1d29175d850a19f0 |
| 25 | 2026-04-19 | 8e | scenario-runner-exec | 14a0b55 | unit_tests | sha256:b74b29b8b13e7e9d |
| 26 | 2026-04-19 | 8e | cmd-run-actor-id-lines | 7fc5e90 | unit_tests | sha256:243df18185d67c3d |
| 27 | 2026-04-19 | 8e | scenario-8-steps | 776c3e3 | unit_tests | sha256:37743e30db403b14 |
| 28 | 2026-04-19 | 8e | scenario-setup-teardown | 0188081 | unit_tests | sha256:ec428bb6d5df30d1 |
| 29 | 2026-04-19 | 8d | mock-feishu-conformance | bb20c5b | unit_tests | sha256:071842a0a2ef220e |
| 30 | 2026-04-19 | 8e | scenario-setup-orchestration | 3355db1 | unit_tests | sha256:92d4e112c07db8de |
| 31 | 2026-04-19 | 8e | esrd-daemonize-port | 5b380ce | unit_tests | sha256:673b55d7ca2f34a0 |
| 32 | 2026-04-19 | 8e | scenario-compile-pattern | 98882c6 | unit_tests | sha256:d56fc8bd25f75d87 |
| 33 | 2026-04-19 | 8d | adapter-runner-main | f9293dc | unit_tests | sha256:201064c2302a9986 |
| 34 | 2026-04-19 | 8d | F07-main | c71abbb | unit_tests | sha256:41f299a5afd5a751 |
| 35 | 2026-04-19 | 8e | scenario-live-green | 6dd1aa3 | scenario_mock | sha256:8986a3a39d6d087e |
| 36 | 2026-04-19 | 8f | gate8-live-creds | d3fa5d2 | final_gate_mock | sha256:fcdf74008563fd5e |
| 37 | 2026-04-19 | 8e | C1-C2-fixes | 0380c52 | unit_tests | sha256:26e42a378e7c4815 |
| 38 | 2026-04-19 | 8e | S1-rollback-unbind | 2399f33 | unit_tests | sha256:d533c6986db3ff52 |
| 39 | 2026-04-19 | 8f | worker-supervisor | dddd1d0 | unit_tests | sha256:8450ea7831f25e51 |
