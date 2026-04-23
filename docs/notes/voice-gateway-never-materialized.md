# voice-gateway: never materialized

**Date**: 2026-04-23 (PR-4a)
**Status**: documented absence; no code deletion performed.

The plan's §PR-4a outline (`2026-04-22-peer-session-refactor-implementation.md`
line 2303, P4a-12) calls for "delete `py/voice_gateway/`". Inspection at
PR-4a expansion time confirmed the directory never existed in the worktree —
the three-sidecar layout (`voice_asr/`, `voice_tts/`, `voice_e2e/`)
landed directly without going through a monolithic intermediate.

Spec §8.1/§8.4 describe the monolith's decomposition as if it had existed;
those sections remain accurate as **design intent**, and the sidecars
implemented in PR-4a match the final shape. The "delete the monolith"
line in the plan is therefore a no-op and is tombstoned here for
traceability.

No action required at merge time. Future readers of the plan should
consult this note before assuming a monolith was deleted.
