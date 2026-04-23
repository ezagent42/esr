# PR-4a Progress Snapshot

**Date**: 2026-04-23 (merged)
**Branch**: `feature/peer-session-refactor` (synced to `origin/main`)
**Squash-merge commit**: `2e3106c` (on `main`)
**Status**: merged ✅

---

## New public API surfaces

### Python sidecars (all under `py/src/`)

- **`voice_asr`**: `python -m voice_asr` — stdin JSON-line `{"id", "kind":"request", "payload":{"audio_b64"}}` → stdout `{"kind":"reply", "payload":{"text"}}`
- **`voice_tts`**: `python -m voice_tts` — stdin `{"payload":{"text"}}` → stdout `{"payload":{"audio_b64"}}`
- **`voice_e2e`**: `python -m voice_e2e` — streaming: stdin audio chunks → stdout `{"kind":"stream_chunk"}` + `{"kind":"stream_end"}`
- **`_voice_common`**: shared helpers (`jsonline.py`, `engine.py`). Leading underscore = internal.

### Elixir peers (all in `runtime/lib/esr/peers/`)

- **`Esr.Peers.VoiceASR`** — `Peer.Stateful + PyProcess` worker; pool member
- **`Esr.Peers.VoiceTTS`** — same shape as ASR
- **`Esr.Peers.VoiceE2E`** — per-session `Peer.Stateful + PyProcess`, streaming
- **`Esr.Peers.VoiceASRProxy`** — `Peer.Proxy`; `@required_cap "peer_pool:voice_asr/acquire"`; pool-acquire target
- **`Esr.Peers.VoiceTTSProxy`** — same shape as ASRProxy

### Pool infrastructure

- **`Esr.Pools`** (new module) — `max_workers/1`, `child_spec/2` helpers; reads `pools.yaml` overrides
- **`Esr.AdminSession.bootstrap_voice_pools/1`** — called from `Esr.Application.start/2`, spawns `:voice_asr_pool` + `:voice_tts_pool` under `AdminSession.ChildrenSupervisor`
- **`Esr.Paths.pools_yaml/0`** — returns the pools.yaml path under `ESRD_HOME`

### OSProcess底座 extension

- New optional callback `os_cwd(state) :: Path.t() | nil` — sets child working directory. `PyProcess` overrides to point at `<repo>/py` so `uv run python -m <sidecar>` can find its pyproject.toml.

### Agent definitions (agents.yaml)

- **`cc-voice`**: feishu_chat_proxy → voice_asr_proxy → cc_proxy → cc_process → tmux_process (inbound); reverse + voice_tts_proxy for outbound
- **`voice-e2e`**: feishu_chat_proxy → voice_e2e (direct, no CC)
- Both use canonical `prefix:name/perm` capability names

### SessionRouter updates

- `@stateful_impls` grew with `VoiceE2E`
- `build_ctx/2` dispatches `proxy_ctx` for `:voice_asr_proxy` and `:voice_tts_proxy`

---

## Decisions locked in during PR-4a

**D4a-PR4a-a: Voice sidecars live at `py/src/voice_{asr,tts,e2e}/` (top-level), NOT `py/src/esr/voice_*/`.** They're independent packages launched via `python -m <module>`. Shared helpers in `py/src/_voice_common/` (leading underscore = internal-only).

**D4a-PR4a-b: ASR/TTS pooled, E2E per-session.** Reason: ASR/TTS are stateless enough that N sessions can queue on a shared pool of K workers; E2E holds conversational state per session.

**D4a-PR4a-c: `PyProcess.os_cwd/1` returns `<repo>/py` by default** so `uv run python -m <sidecar>` discovers `py/pyproject.toml` + `src/` layout. Overridable via `config :esr, :py_project_dir, path`.

**D4a-PR4a-d: voice_gateway deletion is a NO-OP.** The monolith never existed on this branch — PR-4a was greenfield. Documented in `docs/notes/voice-gateway-never-materialized.md`.

**D4a-PR4a-e: Synthetic-injection test pattern from P3-10 reused.** `cc_voice_test.exs` and `voice_e2e_test.exs` use `:sys.replace_state/2` + handler_module_override to inject data without real audio dependencies.

---

## Tests added / known gaps

**Added**:
- Python: `tests/voice/test_jsonline.py` (4), `test_voice_asr.py` (1), `test_voice_tts.py` (1), `test_voice_e2e.py` (1) = **7 new**
- Elixir: `voice_asr_test.exs` (4 integration), `voice_tts_test.exs` (4 integration), `voice_asr_proxy_test.exs` (6), `voice_tts_proxy_test.exs` (4), `voice_e2e_test.exs` (2 integration), `pools_test.exs` (4), admin_session additions, `integration/voice_e2e_test.exs` + `integration/cc_voice_test.exs`

**Test counts after PR-4a merge**:
- `mix test` (default): **381 tests, 0 failures (18 excluded)**
- `mix test --include integration`: **398 tests, 0 failures (1 excluded)**
- `pytest tests/voice/`: **7 passed**

**Known regression**:
- Integration tests leak `esr_cc_<pid>` tmux sessions when they run against the DEFAULT tmux socket (shared with user's dev tmux). PR-4b/PR-5 should fix by:
  1. `TmuxProcess` supporting `-S <socket>` option
  2. Integration tests using per-test unique sockets
  3. `on_exit` with `tmux -S <socket> kill-server`
- 57 sessions leaked during this run; manually cleaned post-merge.

---

## Tech debt carried to PR-4b / PR-5

| Item | Resolution target |
|---|---|
| `TmuxProcess` uses default socket — leaks into user's dev env | PR-5 (socket isolation config) |
| `mix compile --warnings-as-errors` fails on VoiceASR/TTS/E2E/FeishuAppAdapter `init/1` conflicting-callbacks | PR-5 doc cleanup (add `@impl` discipline) |
| No `boot_command` in agents.yaml — tmux session opens but `claude` isn't auto-launched | PR-4b or PR-5 (spec update + Session.init hook) |
| `integration/cc_voice_test` bypasses cc_proxy via refute+skip | PR-5 when SessionRouter proxy refs are wired |

---

## Next PR (PR-4b) expansion inputs

Load:
- This snapshot (PyProcess + os_cwd, AdminSession voice pools, cc-voice agent)
- PR-3 snapshot (CC chain + SessionRegistry)
- erlexec skill (`.claude/skills/erlexec-elixir/`)
- Current `py/src/esr/ipc/adapter_runner.py` — monolith to split
- Spec §8.2 (adapter_runner decomposition)

PR-4b scope: split `adapter_runner.py` into `feishu_adapter_runner` / `cc_adapter_runner` / `generic_adapter_runner` (per-adapter-type sidecars); each wrapped by an `Esr.PyProcess`-based Elixir peer.

---

## Links

- PR #15 (squash-merged): https://github.com/ezagent42/esr/pull/15
- Expanded PR-4a: `docs/superpowers/progress/2026-04-23-pr4a-expanded.md`
- Spec: `docs/superpowers/specs/2026-04-22-peer-session-refactor-design.md`
- Plan: `docs/superpowers/plans/2026-04-22-peer-session-refactor-implementation.md`
- New note: `docs/notes/voice-gateway-never-materialized.md`
