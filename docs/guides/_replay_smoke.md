# _replay_smoke (CI synthetic)

Synthetic guide that exercises `scripts/replay-guide.sh` on every CI
run. One input/output fence pair. Not user-facing — leading underscore
keeps it out of full-user-journey.md.

The probe sends an intentionally non-existent slash command. The
SlashHandler's "unknown command" branch fires BEFORE any capability
gate, before workspace-binding checks, before user-binding checks —
the simplest cap-free single-line reply the runtime can produce.

### Step 1: unknown slash — bot replies with the canonical not-found line

```chat-input app_id=feishu_app_e2e-mock chat_id=oc_mock_single user=linyilun
/smoke_probe
```

```chat-output
unknown command: /smoke_probe
```
