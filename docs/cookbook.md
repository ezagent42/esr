# ESR v0.2 Cookbook

## Recipe: Reply to a Feishu message from CC

In your CC session, given an inbound `<channel source="feishu"
chat_id="oc_..." ...>` tag, call:

```
Use the `reply` tool with chat_id=<oc_...> and text="your response".
```

## Recipe: Trigger a new session from within CC

From the CC shell:

```bash
esr cmd run feishu-thread-session --param workspace=esr-dev --param tag=child
```

This spawns a sibling session; the child CC inherits the parent's
workspace config.

## Recipe: Route a message to a specific session (not the active one)

Send in Feishu: `@<tag> <body>`. The `@<tag>` prefix targets a bound
session regardless of last-active.

## Recipe: Read session state

```bash
esr actors inspect cc:<tag>
```

Shows handler state, chat_ids bound, default chat_id, and paused flag.

## Recipe: Intentional CC restart (preserving conversation)

```bash
esr cmd stop feishu-thread-session --param thread_id=<tag> --param chat_id=<chat_id>
# tmux window closes; MCP exits gracefully
esr cmd run feishu-thread-session --param workspace=<ws> --param tag=<tag>
# New CC starts with claude --resume <prior_session_id>
```

## Recipe: Add a new Feishu app to the same esrd

Two apps can coexist in one esrd environment. Register each as a distinct
adapter, then bind each chat to its app via workspace config:

```bash
esr adapter add feishu-dev  --type feishu --app-id cli_dev  --app-secret ...
esr adapter add feishu-prod --type feishu --app-id cli_prod --app-secret ...
esr workspace add dev-ws --cwd ~/dev --start-cmd scripts/esr-cc.sh \
    --role dev --chat oc_dev:cli_dev:dm --chat oc_prod:cli_prod:group
```

A message to `oc_dev` is handled by `feishu-dev`; a message to `oc_prod`
by `feishu-prod`. The Instantiator validates this mapping when the
workspace is used (`esr cmd run feishu-thread-session --param workspace=dev-ws`).

## Recipe: Kill a stuck CC session without losing the workspace

```bash
esr actors list | grep cc:
esr cmd stop feishu-thread-session --param thread_id=<stuck-tag> --param chat_id=<chat>
# The workspace stays registered — you can spawn a fresh session any time.
```

## Recipe: Tail live telemetry during development

```bash
esr trace --follow
# Or, filter to a single actor:
esr trace --follow --actor cc:dev-root
```

## Recipe: Attach to a CC session's tmux pane

Each `TmuxProcess` peer hosts its CC session in a tmux session named
`esr_cc_<N>`. With per-instance socket isolation (PR-H), prod and dev
keep their tmux sessions in separate sockets — `~/.esrd/default/tmux.sock`
and `~/.esrd-dev/default/tmux.sock` respectively.

```bash
# Discover the per-session tmux name + socket via the actors registry
ESRD_HOME=~/.esrd-dev uv run --project py esr actors list | grep '^thread:'
ESRD_HOME=~/.esrd-dev uv run --project py esr actors inspect thread:<sid>

# Or list every tmux session on the dev socket directly
tmux -S ~/.esrd-dev/default/tmux.sock list-sessions

# Attach (Ctrl-b d to detach without killing the session)
tmux -S ~/.esrd-dev/default/tmux.sock attach -t esr_cc_<N>
```

Operators on a fresh checkout where the plists predate PR-H can read
the active socket via `launchctl print gui/$UID/com.ezagent.esrd-dev | grep ESR_TMUX_SOCKET`
and fall back to `/tmp/tmux-$UID/default` if unset.

> Note: there is no `esr attach` CLI subcommand today — wrap the two
> commands above in a shell alias if you attach often. A first-class
> `esr attach <session_id>` is tracked at
> [`docs/futures/esr-attach-cli.md`](futures/esr-attach-cli.md).
