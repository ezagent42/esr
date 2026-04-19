"""Pattern: feishu-app-session (PRD 06 F01).

Singleton command binding one feishu_app_proxy actor to a single
Feishu app instance. Instantiated once per (app_id, instance_name)
pair — handles ``/new-thread`` dispatch and inbound message routing
into per-thread actors via the ``feishu-thread-session`` pattern.
"""

from esr import command, node


@command("feishu-app-session")
def feishu_app_session() -> None:
    node(
        id="feishu-app:{{app_id}}",
        actor_type="feishu_app_proxy",
        adapter="feishu-{{instance_name}}",
        handler="feishu_app.on_msg",
        params={"app_id": "{{app_id}}"},
    )
