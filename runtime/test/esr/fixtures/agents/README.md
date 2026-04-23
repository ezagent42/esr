# agents.yaml test fixtures

- `simple.yaml` — single-agent `cc` fixture with the **full CC chain**
  (`feishu_chat_proxy → cc_proxy → cc_process → tmux_process`) as of P3-6.
- `multi_app.yaml` — two agents (`cc`, `cc-echo`) both referencing `${app_id}` for N=2 tests (P2-12).
  The `cc-echo` agent is intentionally a minimal feishu-only echo pipeline
  (no CC peers) to keep N=2 routing tests focused on per-session isolation.

## Dev stub note (P2-8, P3-6)

Production esrd reads `${ESRD_HOME}/default/agents.yaml` at boot (spec §3.5). That path
lives in the user's home directory and is out-of-scope for code-only commits. Operators
should hand-place a minimal `cc` stub (mirror `simple.yaml`) into
`~/.esrd/default/agents.yaml` when setting up a fresh dev environment.

After P3-6, the production stub must include the full CC-chain pipeline.
Copy-paste block for operators:

```yaml
# ~/.esrd/default/agents.yaml (production stub)
agents:
  cc:
    description: "Claude Code"
    capabilities_required:
      - session:default/create
      - tmux:default/spawn
      - handler:cc_adapter_runner/invoke
    pipeline:
      inbound:
        - { name: feishu_chat_proxy, impl: Esr.Peers.FeishuChatProxy }
        - { name: cc_proxy,          impl: Esr.Peers.CCProxy }
        - { name: cc_process,        impl: Esr.Peers.CCProcess }
        - { name: tmux_process,      impl: Esr.Peers.TmuxProcess }
      outbound:
        - tmux_process
        - cc_process
        - cc_proxy
        - feishu_chat_proxy
    proxies:
      - { name: feishu_app_proxy, impl: Esr.Peers.FeishuAppProxy, target: "admin::feishu_app_adapter_${app_id}" }
    params:
      - { name: dir,    required: true,  type: path }
      - { name: app_id, required: false, default: "default", type: string }
```
