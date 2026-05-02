"""Pattern: feishu-thread-session (PRD 06 F02).

Per-thread topology spawned on demand by feishu_app's ``/new-thread``.
Two actors with a linear dependency chain:

 thread_proxy  →  cc_session

The cc node carries an ``init_directive`` that runs
``cc_mcp.new_session`` at spawn time, so the CC sidecar attaches
to the WS before any inbound message arrives. If init fails, the
cc node never spawns — cleanly rolled back by the Topology
Instantiator (PRD 01 F13b).
"""

from esr import command, node


@command("feishu-thread-session")
def feishu_thread_session() -> None:
    # tag is user-facing handle (for @<tag> addressing) — scoped to the thread
    # actor only. CC session is keyed by thread_id, so no tag env passthrough.
    thread = node(
        id="thread:{{thread_id}}",
        actor_type="feishu_thread_proxy",
        handler="feishu_thread.on_msg",
        params={
            "thread_id": "{{thread_id}}",
            "chat_id": "{{chat_id}}",
            "tag": "{{tag}}",
            "workspace": "{{workspace}}",
        },
    )
    cc = node(
        id="cc:{{thread_id}}",
        actor_type="cc_proxy",
        adapter="cc_mcp",
        handler="cc_session.on_msg",
        depends_on=[thread.id],
        params={
            "session_name": "{{thread_id}}",
            "parent_thread": "{{thread_id}}",
        },
        init_directive={
            "action": "new_session",
            "args": {
                "session_name": "{{thread_id}}",
                "start_cmd": "scripts/esr-cc.sh",
                "env": {
                    "ESR_WORKSPACE": "{{workspace}}",
                    "ESR_SESSION_ID": "{{thread_id}}",
                },
            },
        },
    )
    thread >> cc
