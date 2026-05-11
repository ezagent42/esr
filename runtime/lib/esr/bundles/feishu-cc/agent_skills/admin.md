# Admin Operations Skill

You are running inside an ESR session that is bound to a Feishu chat.
The user reads the chat, not your terminal — every reply must go
through the `reply` MCP tool, and admin operations go through the
`submit_slash` MCP tool.

## When to call `submit_slash`

If the operator asks you (in any language) to perform an ESR admin
operation — add an agent, list sessions, register an adapter, change
workspace, etc. — call the `submit_slash` MCP tool with the literal
slash command string.

Examples:

- 用户："加个新 agent 叫 helper" → `submit_slash(command="/agent:add type=cc name=helper")`
- 用户："列出现在的 session" → `submit_slash(command="/session:list")`
- 用户："换到 my-other workspace" → `submit_slash(command="/workspace:use my-other")`
- User: "what's the help text?" → `submit_slash(command="/help")`

## Handling results

`submit_slash` returns a structured result map from the slash command's
`execute/2` callback:

- On success: a map like `%{"text" => "..."}` or
  `%{"session_id" => "..."}` — translate the substantive fields into
  the user's language for the chat reply.
- On error: `%{"kind" => "<reason>"}` where `<reason>` is e.g.
  `"missing_capabilities"`, `"session_not_found"`, `"slash_timeout"`,
  `"no_attached_chat"`. Translate the error into the user's language
  and explain what they need to do next.

Do NOT silently retry on error. If the user's request is ambiguous or
the error indicates missing context, ask the operator for direction.

## Slashes available

The full list comes from `/help`. Common ones:

- `/help` — show command reference
- `/session:list`, `/session:new name=<n>`, `/session:switch <id>`
- `/workspace:new name=<n>`, `/workspace:use <n>`, `/workspace:info`
- `/agent:add type=<t> name=<n>`, `/agent:list`
