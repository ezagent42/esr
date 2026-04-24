# Claude Code Channels — reference notes

**Source**: https://code.claude.com/docs/en/channels-reference (fetched 2026-04-24)

Captured because ESR's T11b CC-in-tmux pipeline turns `adapters/cc_mcp` into
exactly this kind of "channel" — pushing Feishu inbound events into the CC
session as `<channel>` tags, and exposing a `reply` tool for the round-trip
back. Our earlier draft treated `cc_mcp` as a plain MCP stdio server; it's
not. The channel contract has specific requirements.

## What a channel is

A channel is an MCP server with one extra declaration — the
`claude/channel` experimental capability — that lets it **push events into
Claude Code's session** as `<channel source="..." ...>` context tags, not
just receive tool calls. Two-way channels also expose tools so Claude can
reply back.

Plain MCP server: Claude calls tools. That's it.
Channel: Claude calls tools **and** the server can call `mcp.notification()`
at any time to inject a `<channel>` tag into Claude's context.

## Minimum declaration (what ESR cc_mcp must do)

Current ESR `adapters/cc_mcp/src/esr_cc_mcp/channel.py:211` passes
`experimental_capabilities={}`. That's a plain MCP server. To become a
channel, declare:

```python
experimental_capabilities={"claude/channel": {}}
```

And emit inbound events as:

```python
await server.send_notification(
    method="notifications/claude/channel",
    params={
        "content": text,                      # body of the <channel> tag
        "meta": {"chat_id": ..., "user": ..., ...},  # tag attributes
    },
)
```

Tag attribute keys must be `[A-Za-z0-9_]+` — hyphens or other chars get
silently dropped. The `source` attribute is set automatically from the
server name (`esr-channel` in our case).

## The `--dangerously-load-development-channels` flag

**Required during the research preview for any channel not on Anthropic's
approved allowlist.** Format:

- `--dangerously-load-development-channels server:<name>` — bypass allowlist
  for a channel declared in `.mcp.json` under `mcpServers.<name>`
- `--dangerously-load-development-channels plugin:<name>@<marketplace>` —
  bypass for a plugin-wrapped channel

**Not** cc-openclaw-specific — ESR's `cc_mcp` needs this flag too. Supports
Claude Code v2.1.80+. Requires claude.ai login (console/API key auth not
supported). Team/Enterprise orgs have a `channelsEnabled` org policy that
still applies even when the dev flag is set.

The "dangerously" framing is because the flag skips Anthropic's security
review of the channel; don't use it on channels you don't trust.

## Instructions string

The `Server` constructor's `instructions` param is appended to Claude's
system prompt. Use it to tell Claude what events to expect, what the
`<channel>` attributes mean, whether to reply, and **which tool attribute
to pass through** (e.g. "reply with the `reply` tool, passing `chat_id`
from the tag").

For ESR, the instructions should name the actual tool surface (reply /
react / send_file) and the attributes FeishuChatProxy will set.

## Two-way: the `reply` tool pattern

Standard MCP tool, no channel-specific bits. Three pieces:

1. `capabilities.tools = {}` in the `Server` constructor
2. `ListToolsRequestSchema` + `CallToolRequestSchema` handlers
3. `instructions` naming the tool

ESR's `cc_mcp/tools.py` already has this for `reply` + `send_file`. Just
needs the channel capability bolted on.

## Permission relay — optional but production-valuable

Opt-in via `claude/channel/permission: {}` capability. When declared,
Claude Code forwards tool-approval prompts (Bash/Write/Edit) to the
channel so they can be approved from the remote device in parallel with
the local terminal dialog. Whichever answer arrives first wins.

Protocol:

- Claude Code → channel: `notifications/claude/channel/permission_request`
  with `{request_id (5 lowercase letters, no `l`), tool_name, description, input_preview}`
- Channel → Claude Code: `notifications/claude/channel/permission` with
  `{request_id, behavior: "allow"|"deny"}`

**Security constraint**: only declare the permission capability if the
inbound path has proper sender gating — anyone who can reply can approve
tool use in the session.

For ESR: declare this in T11b.5 only AFTER the Feishu adapter's Lane A
sender-allowlist check is verified covering tool-approval replies. Until
then, leave the capability un-declared so local terminal is the sole
approver. Tracking this as a T11c or post-T11b follow-up.

## Gating inbound against prompt injection

An ungated channel = prompt injection vector. Every message your channel
emits becomes part of Claude's context. The docs' example:

```ts
if (!allowed.has(message.from.id)) return  // drop silently
await mcp.notification({...})
```

Gate on **sender identity**, not chat/room identity. Group chats are
shared — allowlisting the room admits anyone in it.

ESR mirror: this is exactly what FeishuAdapter's Lane A (`_is_authorized`)
already does — check `(sender_open_id, chat_id) → workspace → msg.send`
against capabilities.yaml. The adapter-side gating is already correct; the
channel's role is just to faithfully forward events that passed the gate.

## Relevance to ESR T11b

1. **Add `claude/channel` capability to cc_mcp** — otherwise notifications
   won't register. Current code (`channel.py:211`) passes empty
   experimental_capabilities; one-line fix.
2. **Keep `--dangerously-load-development-channels server:esr-channel` in
   the claude CLI invocation** — needed until ESR's channel is approved
   (if ever — private deployments will always need the flag).
3. **Audit `instructions` string** so CC knows our meta fields
   (`chat_id`, `message_id`, `user`, `thread_id`) and the reply tool's
   expected arg shape (`chat_id`, `text`).
4. **Defer permission relay** to a follow-up task — we want the sender
   gating audit done first.

## Pointers

- Live reference: https://code.claude.com/docs/en/channels-reference
- fakechat example code: https://github.com/anthropics/claude-plugins-official/tree/main/external_plugins/fakechat
- Permission relay sequence diagram in the docs above (§Relay permission prompts)
- Current ESR cc_mcp file that needs the capability added:
  `adapters/cc_mcp/src/esr_cc_mcp/channel.py:209-212`
