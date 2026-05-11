# Operator bootstrap checklist

**Audience:** an operator (or reviewer) verifying that a fresh-install
`esrd` actually delivers the 12-step bootstrap journey. Sister doc:
[`flow-bootstrap.md`](flow-bootstrap.md) is the
**how-to**; this file is the **checklist**.

Each row scores three dimensions:

- **Interface (I)** — an entry point exists that *could* serve this step
- **Function (F)** — the entry point actually delivers the expected behavior end-to-end
- **Grammar (G)** — the wording matches what an operator sees

Run through this checklist after every fresh install or every major
grammar change. The history of audits that produced this checklist
lives in [`docs/manual-checks/`](../manual-checks/).

> **Status as of 2026-05-09:** all 12 steps are ✅✅✅ post the
> [unified-command-grammar migration](../superpowers/specs/2026-05-09-unified-command-grammar-and-errors.md)
> + the resource-typed grammar PR + the auto-admin / multimedia / pty_attach hardening series.
> See [`docs/manual-checks/2026-05-08-post-multi-instance-audit.md`](../manual-checks/2026-05-08-post-multi-instance-audit.md) §rev-5.1
> for the full audit trail.

---

## The 12-step checklist

Run the commands in your fresh-install environment. Each row should
end with a ✅ before you call the install good.

### 1. Daemon starts

```bash
bash scripts/esrd.sh start --instance=default
launchctl print gui/$(id -u)/com.ezagent.esrd-default 2>&1 | grep state
```

- [ ] `state = running` for the launchd plist
- [ ] `tail -1 ~/.esrd/default/logs/launchd-stdout.log` shows Phoenix booted

### 2. First `user_add` auto-promotes to admin

```bash
alias esr-dev='ESRD_HOME=$HOME/.esrd-dev ESR_INSTANCE=default ./runtime/esr'
esr-dev exec user_add --name=<your_name>
```

- [ ] Output shows `action: created`
- [ ] `cat ~/.esrd/default/capabilities.yaml | grep -A2 <your_name>` shows `["*"]` grant
- [ ] `cat ~/.esrd/default/operator.json` carries `"username": "<your_name>"`

### 3. Adapter registration (Feishu)

```bash
esr-dev exec register_adapter --type=feishu --name=esr_helper \
    --app_id=cli_xxx --app_secret=xxx
```

- [ ] Output shows `ok: true`
- [ ] `cat ~/.esrd/default/adapters/esr_helper/config.yaml` has `app_secret` populated (yaml-layout-v2 spec § 4.3)
- [ ] `tail -20 ~/.esrd/default/logs/launchd-stderr.log | grep feishu` shows sidecar booted

### 4. Bind your Feishu identity

```bash
esr-dev exec feishu_bind --name=<your_name> --feishu_user_id=ou_xxxx
```

- [ ] Output shows `ok: true`
- [ ] `cat ~/.esrd/default/users/<uuid>/user.json | jq '.feishu_ids'` includes your `ou_xxxx`

### 5. claude_code plugin available

claude_code ships built-in (no separate install). Check:

```bash
esr-dev exec /plugin:list
```

- [ ] Output includes a `claude_code` row marked enabled

### 6. Per-plugin operator config (proxy etc.)

```bash
esr-dev exec /plugin:set plugin=claude_code key=http_proxy value=http://127.0.0.1:7897
esr-dev exec /plugin:show-config plugin=claude_code
esr-dev exec /plugin:reload plugin=claude_code
```

- [ ] `/plugin:show-config` confirms the override is set
- [ ] `/plugin:reload` returns `ok: true`

### 7. `/help` and `/doctor` work in Feishu

In the Feishu chat that has the bot:

```
/help
/doctor
```

- [ ] `/help` returns the rendered command reference (uses `Esr.Resource.SlashRoute.Registry`)
- [ ] `/doctor` returns user-binding + chat-binding + bootstrap guidance

### 8. `/session:new` creates a session

In Feishu:

```
/workspace:new name=test-ws
/session:new name=test-cc
```

- [ ] Both return `ok: true`
- [ ] `/session:list` shows the new session

### 9. `/workspace:add-folder` extends the workspace

In Feishu:

```
/workspace:add-folder path=/abs/path/to/repo
```

- [ ] Folder appears in `/workspace:info`
- [ ] Path is a real git repo (the command rejects non-git dirs)

### 10. `/agent:add` adds a CC agent

In Feishu:

```
/agent:add type=cc name=alice
```

- [ ] Returns `ok: true` with `actor_ids.cc` + `actor_ids.pty` populated
- [ ] `/agent:list` shows alice
- [ ] Multi-instance works: a second `name=bob` coexists with alice

### 11. Plain text routes to the primary agent's Claude Code

In Feishu (with the agent registered as primary):

```
hello, what's the cwd?
```

- [ ] Claude Code replies in the chat with the actual working directory
- [ ] The PTY shows the prompt + response in `/pty:list`

### 12. `/claude_code:tui` returns a clickable URL

In Feishu:

```
/claude_code:tui name=alice
```

- [ ] Returns a URL like `http://<host>:<port>/ptys/attach?token=<phoenix_signed_token>`
- [ ] URL does NOT contain the actor_id directly (only the signed token)
- [ ] Clicking the URL in a browser opens xterm.js attached to alice's PTY
- [ ] Token expires after 10 minutes; reload after expiration → 403

---

## Cross-cutting verification

These aren't part of the 12 steps but are good to spot-check:

### A. Drift gate

```bash
cd runtime && mix esr.check_command_docs
```

- [ ] Returns `✅ slash-routes.yaml + docs/grammar/* in sync with command_meta/0`
- [ ] Tampering with `slash-routes.default.yaml` by hand makes the gate fail next run

### B. Bare-prefix help

In Feishu:

```
/workspace
/workspace:help
/zzznotreal
```

- [ ] `/workspace` returns method listing (workspace:new, workspace:list, …)
- [ ] `/workspace:help` returns the same content
- [ ] `/zzznotreal` returns "未知 resource" hint

### C. Auto-generated grammar doc

```bash
ls docs/grammar/
cat docs/grammar/commands.md | head -40
cat docs/grammar/errors.md | head -40
```

- [ ] Both files exist and start with `<!-- AUTOGENERATED — DO NOT EDIT BY HAND. -->` banner
- [ ] Spot-check: the kind for `/workspace:new` matches its `command_meta()`

### D. PTY attach security

```bash
curl -s "http://<host>:<port>/ptys/attach?token=<expired_token>" -o /dev/null -w "%{http_code}\n"
```

- [ ] Returns `403` (or the friendly invalid-token page)
- [ ] No token at all → also 403

---

## What this checklist does NOT verify

- **Production load**: stress / concurrency / multi-tenant scenarios. Use the e2e suite (`tests/e2e/scenarios/`).
- **Token security against secret_key_base rotation**: outside operator scope.
- **Plugin install-by-name**: not yet implemented (tracked as `esr daemon init/clear` in [`docs/futures/todo.md`](../futures/todo.md)).

---

## When to update this checklist

- After any PR that adds, renames, or removes a slash command.
- After any PR that changes the bootstrap journey (e.g. zero-config bootstrap, register_adapter behavior).
- After any rev of `docs/manual-checks/<date>-*.md` adds or closes a step.

The checklist is the standing operator-facing distillation of the audit
files; the audits are the historical record of HOW we got here.
