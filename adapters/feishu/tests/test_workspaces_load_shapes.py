"""PR-9 T9 regression: FeishuAdapter._load_workspace_map shape guards.

E2E RCA: scenario 01 step 2 was blocked because common.sh seeded
workspaces.yaml with `chats: [<raw string>, ...]` — the adapter's
`_load_workspace_map` called `.get("chat_id")` on each entry, raising
`AttributeError: 'str' object has no attribute 'get'` at adapter-factory
time. The subprocess crashed before connecting to Phoenix, so the T9
sidecar-ready probe timed out.

These two tests pin the contract in both directions:
- Canonical schema (`{chat_id, app_id, kind}` dicts) — adapter factory
  returns an instance and the map contains the expected binding.
- Malformed entries (raw strings) — adapter factory raises instead of
  silently dropping, so config regressions surface at startup rather
  than becoming a "messages are silently lost" mystery downstream.
"""
from __future__ import annotations

from pathlib import Path

import pytest
import yaml
from esr_feishu.adapter import FeishuAdapter

from esr.adapter import AdapterConfig


def _config(tmp_path: Path, workspaces_yaml: str) -> AdapterConfig:
    ws_path = tmp_path / "workspaces.yaml"
    ws_path.write_text(workspaces_yaml)
    cap_path = tmp_path / "capabilities.yaml"
    cap_path.write_text(yaml.safe_dump({"principals": []}))
    return AdapterConfig({
        "app_id": "e2e-mock",
        "app_secret": "mock",
        "base_url": "http://127.0.0.1:1",
        "workspaces_path": str(ws_path),
        "capabilities_path": str(cap_path),
    })


def test_canonical_chats_shape_loads_and_maps(tmp_path: Path) -> None:
    yaml_text = """\
workspaces:
  e2e:
    cwd: "/tmp/esr-e2e-workspace"
    start_cmd: ""
    role: "dev"
    chats:
      - {chat_id: oc_mock_single, app_id: e2e-mock, kind: dm}
    env: {}
"""
    adapter = FeishuAdapter(
        actor_id="feishu_app_e2e-mock",
        config=_config(tmp_path, yaml_text),
    )
    # The binding is resolvable under (chat_id, app_id) — this is what
    # Lane A authorization uses to answer "which workspace owns this
    # inbound?" before checking msg.send grants.
    assert adapter._workspace_of.get(  # noqa: SLF001 — regression pin
        ("oc_mock_single", "e2e-mock")
    ) == "e2e"


def test_raw_string_chats_fail_fast(tmp_path: Path) -> None:
    """Raw-string entries MUST crash the adapter factory, not be silently
    skipped. Silent skipping hides schema regressions — the e2e RCA
    showed one lost hour of debugging because push_inbound dropped with
    no signal."""
    yaml_text = """\
workspaces:
  bad:
    cwd: "/tmp"
    start_cmd: ""
    role: "dev"
    chats:
      - oc_raw_string_not_a_dict
    env: {}
"""
    with pytest.raises(AttributeError):
        FeishuAdapter(
            actor_id="feishu_app_e2e-mock",
            config=_config(tmp_path, yaml_text),
        )
