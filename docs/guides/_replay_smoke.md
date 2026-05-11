# _replay_smoke (CI synthetic)

Synthetic guide that exercises `scripts/replay-guide.sh` on every CI
run. One input/output fence pair. Not user-facing — leading underscore
keeps it out of full-user-journey.md.

The probe sends an intentionally non-existent slash command. The
SlashHandler's "unknown command" branch fires BEFORE any capability
gate, before workspace-binding checks, before user-binding checks —
the simplest cap-free single-line reply the runtime can produce.

### Step 1: unknown resource — bot replies with the canonical not-found line

```chat-input app_id=e2e-mock chat_id=oc_mock_single user=linyilun
/smoke_probe
```

```chat-output
未知 resource: smoke_probe。用 / 看 top-level resources，/help 看完整清单。
```
