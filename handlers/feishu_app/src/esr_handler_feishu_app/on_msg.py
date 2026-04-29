"""Feishu app-proxy handler (PRD 05 F07 / v0.2 §3.3)."""
# NOTE v0.2 §3.3 workspace app_id validation — the handler CANNOT
# access AdapterHub.Registry (pure-python sandbox). Validation lives
# in Elixir Instantiator (Task P6-3); unregistered app → InvokeCommand
# returns `{:error, :app_not_registered}` and the topology isn't spawned,
# surfaced back to the Feishu chat via the feishu_app Route-to-error
# path (TODO v0.3: wire this back to the user).
from __future__ import annotations

from esr import Action, Event, InvokeCommand, Route, handler

from esr_handler_feishu_app.state import FeishuAppState

_NEW_SESSION_PREFIX = "/new-session "
_NEW_THREAD_PREFIX = "/new-thread "   # v0.2 backward-compat alias (P9 removes)
_AT_PREFIX = "@"


@handler(
    actor_type="feishu_app_proxy",
    name="on_msg",
    permissions=[
        "msg.send",
        "session.create",
        "session.switch",
        "workspace.read",
        "workspace.list",
    ],
)
def on_msg(
    state: FeishuAppState, event: Event
) -> tuple[FeishuAppState, list[Action]]:
    if event.event_type != "msg_received":
        return state, []

    content = str(event.args.get("content", ""))
    chat_id = str(event.args.get("chat_id", ""))

    # Capture last_chat_id on the first inbound for a chat.
    new_state = state
    if chat_id and chat_id != state.last_chat_id:
        new_state = state.with_last_chat_id(chat_id)

    if content.startswith(_NEW_SESSION_PREFIX):
        return _handle_new_session(new_state, event, content,
                                   prefix=_NEW_SESSION_PREFIX)

    if content.startswith(_NEW_THREAD_PREFIX):
        # v0.1 compat alias: `/new-thread <tag>` ≈
        # `/new-session <default_ws> tag=<tag>` where the default
        # workspace is "legacy". Keeps the v0.1 scenario green while
        # the new flow rolls out. P9 removes this branch together
        # with the scenario YAML rewrite.
        return _handle_new_session(new_state, event, content,
                                   prefix=_NEW_THREAD_PREFIX,
                                   default_workspace="legacy")

    if content.startswith(_AT_PREFIX):
        return _handle_at_routed(new_state, event, content)

    # Fall back to active_thread_by_chat
    thread_id = new_state.active_thread_by_chat.get(chat_id)
    if thread_id and thread_id in new_state.bound_threads:
        return new_state, [Route(target=f"thread:{thread_id}",
                                 msg={"event_type": "msg_received",
                                      "args": dict(event.args)})]
    return new_state, []


def _handle_new_session(
    state: FeishuAppState, event: Event, content: str,
    *, prefix: str, default_workspace: str = ""
) -> tuple[FeishuAppState, list[Action]]:
    body = content[len(prefix):].strip()
    if not body:
        return state, []

    parts = body.split()

    # PR-21d unified grammar (D14): always positional workspace + named
    # name= cwd= worktree= args. Examples:
    #   /new-session esr-dev name=feature-foo cwd=/Users/.../esr-feature-foo worktree=feature-foo
    #   /new-thread feature-foo                       (v0.1 compat — first token is the name; uses default_workspace)
    #
    # Backward-compat for v0.1 /new-thread is preserved (it just maps to
    # name=<first-token>; cwd/worktree default to empty and PR-21e's
    # spawn path will reject the missing-worktree case there).
    if default_workspace:  # legacy /new-thread <name>
        if not parts:
            return state, []
        name = parts[0]
        workspace = default_workspace
        cwd = ""
        worktree = ""
    else:                  # PR-21d /new-session <workspace> name=… cwd=… worktree=…
        workspace = parts[0] if parts else ""
        name, cwd, worktree = "", "", ""
        for p in parts[1:]:
            if p.startswith("name="):
                name = p[5:]
            elif p.startswith("cwd="):
                cwd = p[4:]
            elif p.startswith("worktree="):
                worktree = p[len("worktree="):]
            elif p.startswith("tag="):
                # PR-21d: legacy `tag=` accepted as alias for `name=` to
                # ease the rollout; prints a deprecation hint via the
                # session response (PR-21e adds the warning DM).
                if not name:
                    name = p[4:]

    if not workspace:
        return state, []

    # Default name = short slug of message_id if absent
    if not name:
        mid = str(event.args.get("message_id", ""))
        name = mid.split("_", 1)[-1][:12] or "sess"

    chat_id = str(event.args.get("chat_id", ""))

    new_state = state.with_added_thread(name)
    if chat_id:
        new_state = new_state.with_active_thread(chat_id, name)

    # `tag` field on the InvokeCommand kept for downstream compat (Elixir
    # SessionRouter's params parser hasn't been bumped yet — that's
    # PR-21e). PR-21d emits both `tag` and `name`; consumers can switch
    # to `name` once available.
    return new_state, [
        InvokeCommand(
            name="feishu-thread-session",
            params={"thread_id": name, "chat_id": chat_id,
                    "workspace": workspace, "tag": name, "name": name,
                    "cwd": cwd, "worktree": worktree},
        )
    ]


def _handle_at_routed(
    state: FeishuAppState, event: Event, content: str
) -> tuple[FeishuAppState, list[Action]]:
    # Parse "@<tag> <body>"; split at first space
    rest = content[1:]
    if " " not in rest:
        return state, []
    tag, body = rest.split(" ", 1)
    if tag not in state.bound_threads:
        return state, []

    # Rewrite event args with body as content, preserving the rest
    new_args = {**event.args, "content": body}
    return state, [Route(target=f"thread:{tag}",
                         msg={"event_type": "msg_received", "args": new_args})]
